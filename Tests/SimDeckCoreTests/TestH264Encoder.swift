import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
@testable import SimDeckCore

/// 测试辅助：用 VideoToolbox 压缩会话编码两帧 64x48 纯色图，产出真实可解码的
/// H.264 数据（avcC 配置记录 + AVCC sample），供解码核心测试与 baguette mock 回放使用。
enum TestH264Encoder {
    struct EncodedStream {
        let avcC: Data
        let idr: Data   // 首帧关键帧（AVCC sample 字节，4 字节长度前缀 NAL）
        let delta: Data // 第二帧
    }

    /// baguette 分帧：`[4 字节大端长度][1 字节 tag][payload]`，长度字段含 tag 字节。
    static func makeFrame(tag: UInt8, payload: Data) -> Data {
        var data = Data()
        let length = UInt32(payload.count + 1).bigEndian
        withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
        data.append(tag)
        data.append(payload)
        return data
    }

    static func encode(width: Int32 = 64, height: Int32 = 48) throws -> EncodedStream {
        final class Collector {
            var samples: [(data: Data, format: CMFormatDescription?)] = []
            var failure: String?
        }

        let collector = Collector()
        let callback: VTCompressionOutputCallback = { userData, _, status, _, sampleBuffer in
            let collector = Unmanaged<Collector>.fromOpaque(userData!).takeUnretainedValue()
            guard status == noErr else {
                collector.failure = "encode status \(status)"
                return
            }
            guard let sampleBuffer, let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                collector.failure = "empty sample buffer"
                return
            }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)
            let copyStatus = data.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: length,
                    destination: raw.baseAddress!
                )
            }
            if copyStatus != kCMBlockBufferNoErr {
                collector.failure = "copy status \(copyStatus)"
                return
            }
            collector.samples.append((data, CMSampleBufferGetFormatDescription(sampleBuffer)))
        }

        var session: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [
                kVTCompressionPropertyKey_RealTime: true,
                kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Baseline_AutoLevel,
                kVTCompressionPropertyKey_AverageBitRate: 200_000,
                kVTCompressionPropertyKey_AllowFrameReordering: false,
                kVTCompressionPropertyKey_ExpectedFrameRate: 30
            ] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(collector).toOpaque(),
            compressionSessionOut: &session
        )
        guard createStatus == noErr, let session else {
            throw NSError(domain: "TestH264Encoder", code: Int(createStatus), userInfo: nil)
        }
        defer {
            VTCompressionSessionInvalidate(session)
        }

        func encodeFrame(index: Int32, fill: UInt8) throws {
            var pixelBuffer: CVPixelBuffer?
            let createResult = CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(width),
                Int(height),
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            )
            guard createResult == kCVReturnSuccess, let pixelBuffer else {
                throw NSError(domain: "TestH264Encoder", code: Int(createResult), userInfo: nil)
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, Int32(fill), CVPixelBufferGetBytesPerRow(pixelBuffer) * Int(height))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                duration: CMTime(value: 1, timescale: 30),
                frameProperties: nil,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil
            )
            guard status == noErr else {
                throw NSError(domain: "TestH264Encoder", code: Int(status), userInfo: nil)
            }
        }

        try encodeFrame(index: 0, fill: 0x80)
        try encodeFrame(index: 1, fill: 0x40)
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if collector.samples.count >= 2 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if let failure = collector.failure {
            throw NSError(
                domain: "TestH264Encoder",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: failure]
            )
        }
        guard collector.samples.count >= 2 else {
            throw NSError(
                domain: "TestH264Encoder",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "encoder produced \(collector.samples.count) samples"]
            )
        }

        let atoms = CMFormatDescriptionGetExtension(
            collector.samples[0].format!,
            extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any]
        guard let avcC = atoms?["avcC"] as? Data else {
            throw NSError(
                domain: "TestH264Encoder",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "missing avcC extension atom"]
            )
        }
        return EncodedStream(
            avcC: avcC,
            idr: collector.samples[0].data,
            delta: collector.samples[1].data
        )
    }
}
