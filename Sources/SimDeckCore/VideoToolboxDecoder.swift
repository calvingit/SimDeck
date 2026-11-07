import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// VideoToolbox H.264 解码核心：由参数集建立 format description 与解码会话，
/// 接收 AVCC 长度前缀切片（`[4 字节大端 NAL 长度][NAL]`，可含多个 NAL），硬解后输出 CGImage。
/// ADBH264Streamer（Android）与 baguette 流（iOS）共用；调用方需在单一串行队列上访问实例方法。
public final class VideoToolboxDecoder {
    /// 主线程回调：每帧与解码尺寸。
    public var onFrame: ((CGImage, CGSize) -> Void)?

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    // 以下状态仅在调用方的串行队列上访问。
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var frameIndex: Int64 = 0

    public init() {}

    /// 解码会话是否已建立。
    public var isConfigured: Bool { decompressionSession != nil }

    /// 用参数集（裸 NAL，不带长度前缀）建立 format description 与解码会话，返回视频尺寸。
    /// 抛错时保持原状态；参数集不完整或会话建立失败由调用方等待新参数集重试。
    @discardableResult
    public func configure(parameterSets: [Data]) throws -> CGSize {
        let (format, size) = try Self.makeFormatDescription(parameterSets: parameterSets)
        rebuildSession(format: format)
        guard decompressionSession != nil else {
            throw NSError(
                domain: "SimDeck.h264",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: AppLanguage.text("stream.parameterSetFailed", "session")]
            )
        }
        formatDescription = format
        return size
    }

    /// 解码一个 AVCC 切片。返回 false 表示解码失败，会话已被重置；
    /// 调用方应丢弃手上的参数集，等待新的参数集重新 configure。
    @discardableResult
    public func decode(avcc: Data) -> Bool {
        guard let format = formatDescription, let session = decompressionSession else { return false }
        guard let sample = Self.makeSample(avcc: avcc, format: format, index: frameIndex) else {
            return false
        }
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [],
            infoFlagsOut: nil,
            completionHandler: { [weak self] status, infoFlags, imageBuffer, _, _, _ in
                self?.handleDecodedFrame(
                    status: status,
                    infoFlags: infoFlags,
                    imageBuffer: imageBuffer
                )
            }
        )
        if status == noErr {
            frameIndex += 1
            return true
        }
        invalidate()
        return false
    }

    /// 释放解码会话；再次使用前需重新 configure。
    public func invalidate() {
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        formatDescription = nil
    }

    // MARK: - 内部（调用方串行队列）

    private func rebuildSession(format: CMVideoFormatDescription) {
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else { return }
        decompressionSession = session
    }

    func handleDecodedFrame(
        status: OSStatus,
        infoFlags: VTDecodeInfoFlags,
        imageBuffer: CVImageBuffer?
    ) {

        guard status == noErr,
              !infoFlags.contains(.frameDropped),
              let imageBuffer else {
            return
        }
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let size = CGSize(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        )
        DispatchQueue.main.async { [weak self] in
            self?.onFrame?(cgImage, size)
        }
    }

    // MARK: - 工具

    private static func makeFormatDescription(parameterSets: [Data]) throws -> (CMVideoFormatDescription, CGSize) {
        // 新 SDK 要求传裸 NAL（不带 AVCC 长度前缀），nalUnitHeaderLength 仅约束后续 sample。
        // 各参数集拼接进一段连续内存后统一取指针，避免对临时数组取悬垂指针。
        var flat: [UInt8] = []
        var offsets: [Int] = []
        var sizes: [Int] = []
        for set in parameterSets {
            offsets.append(flat.count)
            sizes.append(set.count)
            flat.append(contentsOf: set)
        }
        var format: CMVideoFormatDescription?
        let status = flat.withUnsafeBufferPointer { buffer in
            var pointers: [UnsafePointer<UInt8>] = offsets.map { buffer.baseAddress! + $0 }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &format
            )
        }
        guard status == noErr, let format else {
            throw NSError(
                domain: "SimDeck.h264",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: AppLanguage.text("stream.parameterSetFailed", String(status))]
            )
        }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        return (format, CGSize(width: Double(dims.width), height: Double(dims.height)))
    }

    private static func makeSample(
        avcc: Data,
        format: CMVideoFormatDescription,
        index: Int64
    ) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let replaceStatus = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: index, timescale: 30),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr else { return nil }
        return sampleBuffer
    }
}
