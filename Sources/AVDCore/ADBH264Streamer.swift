import Combine
import CoreGraphics
import Foundation

/// 通过 `adb exec-out screenrecord --output-format=h264 -` 获取设备实时 H.264 流，
/// 解析 Annex-B NAL 后交给共用的 VideoToolboxDecoder 硬解，输出 CGImage 帧（~30fps）。
///
/// 注意：Android screenrecord 默认有时长上限（约 3 分钟），到达后进程退出，
/// 这里会自动重新连接；3 分钟内的帧没有中断。
public final class ADBH264Streamer: NSObject {
    public enum StreamState: Equatable {
        case idle
        case starting
        case active
        case ended(reason: String)
    }

    @Published public private(set) var frame: CGImage?
    @Published public private(set) var frameSize: CGSize?
    @Published public private(set) var state: StreamState = .idle

    /// 主线程回调：每帧与状态变化。
    public var onFrame: ((CGImage, CGSize) -> Void)?
    public var onState: ((StreamState) -> Void)?

    private var serial: String?
    private var adbURL: URL?
    private var environment: [String: String]?
    private var wantsStream = false
    private var startedAt: Date?
    private var restartWorkItem: DispatchWorkItem?
    private var process: Process?
    private var pipe: Pipe?

    private let parserQueue = DispatchQueue(label: "local.avdmenubar.h264.parser")

    // 以下解码状态仅在 parserQueue 上访问。
    private var parser = H264AnnexBParser()
    private var sps: Data?
    private var pps: Data?
    private var formatDirty = false
    private let decoder = VideoToolboxDecoder()

    public static func makeArguments(serial: String) -> [String] {
        ["-s", serial, "exec-out", "screenrecord", "--output-format=h264", "-"]
    }

    public var isRunning: Bool {
        process?.isRunning == true && wantsStream
    }

    override public init() {
        super.init()
        decoder.onFrame = { [weak self] image, size in
            guard let self else { return }
            self.frame = image
            self.frameSize = size
            self.onFrame?(image, size)
            if case .starting = self.state {
                self.setState(.active)
            }
        }
    }

    public func start(serial: String, adb: URL, environment: [String: String]) {
        stop()
        wantsStream = true
        self.serial = serial
        adbURL = adb
        self.environment = environment
        startedAt = Date()
        setState(.starting)
        startProcess()
    }

    public func stop() {
        wantsStream = false
        restartWorkItem?.cancel()
        terminateProcess()
        teardownDecoderSync()
        setState(.idle)
    }

    // MARK: - 进程

    private func startProcess() {
        parserQueue.sync { teardownDecoderLocked() }

        guard let serial, let adbURL else { return }
        let process = Process()
        process.executableURL = adbURL
        process.arguments = Self.makeArguments(serial: serial)
        process.environment = environment ?? ProcessInfo.processInfo.environment
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        self.pipe = pipe
        self.process = process

        process.terminationHandler = { [weak self] endedProcess in
            DispatchQueue.main.async {
                guard let self, self.process === endedProcess else { return }
                self.handleStreamEnd()
            }
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.parserQueue.async {
                self.consume(data)
            }
        }

        do {
            try process.run()
        } catch {
            self.process = nil
            self.pipe = nil
            setState(.ended(reason: error.localizedDescription))
            scheduleRestart()
        }
    }

    private func terminateProcess() {
        guard let process else { return }
        pipe?.fileHandleForReading.readabilityHandler = nil
        self.pipe = nil
        self.process = nil
        if process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }

    private func handleStreamEnd() {
        teardownDecoderAsync()
        guard wantsStream, serial != nil else {
            setState(.idle)
            return
        }
        let ran = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let reason = ran < 60
            ? AppLanguage.text("stream.interrupted")
            : AppLanguage.text("stream.timeLimit")
        setState(.ended(reason: reason))
        scheduleRestart()
    }

    private func scheduleRestart() {
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.wantsStream else { return }
            self.startProcess()
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    // MARK: - 解析与解码（parserQueue）

    private func consume(_ data: Data) {
        for nal in parser.extract(data) {
            handleNAL(nal)
        }
    }

    private func handleNAL(_ nal: Data) {
        guard nal.count > 1 else { return }
        switch nal[0] & 0x1F {
        case 7: // SPS
            sps = nal
            formatDirty = true
        case 8: // PPS
            pps = nal
            formatDirty = true
        case 1...5: // 切片
            enqueueSlice(nal)
        default:
            break
        }
    }

    private func enqueueSlice(_ nal: Data) {
        if formatDirty || !decoder.isConfigured {
            guard let sps, let pps else { return }
            do {
                let size = try decoder.configure(parameterSets: [sps, pps])
                formatDirty = false
                let sizeCopy = size
                DispatchQueue.main.async { self.frameSize = sizeCopy }
            } catch {
                // 参数集不完整，等待下一次 SPS/PPS
                return
            }
        }
        if !decoder.decode(avcc: Self.lengthPrefixed(nal)) {
            // 解码失败：清空参数集并重建解析器，等待新的 SPS/PPS
            sps = nil
            pps = nil
            formatDirty = false
            parser = H264AnnexBParser()
        }
    }

    private func teardownDecoderSync() {
        parserQueue.sync { teardownDecoderLocked() }
    }

    private func teardownDecoderAsync() {
        parserQueue.async { self.teardownDecoderLocked() }
    }

    private func teardownDecoderLocked() {
        decoder.invalidate()
        sps = nil
        pps = nil
        formatDirty = false
        parser = H264AnnexBParser()
    }

    // MARK: - 工具

    private func setState(_ s: StreamState) {
        DispatchQueue.main.async {
            self.state = s
            self.onState?(s)
        }
    }

    private static func lengthPrefixed(_ nal: Data) -> Data {
        var data = Data()
        let length = UInt32(nal.count).bigEndian
        withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
        data.append(nal)
        return data
    }
}

/// 解析 Annex-B 裸流，提取不含起始码的 NAL 单元。
/// 每找到一个起始码就结算上一个 NAL 并原地裁剪缓冲区，避免跨 chunk 的坐标错位。
struct H264AnnexBParser {
    private var buffer: [UInt8] = []
    private var hasPendingNAL = false
    private static let maxBufferLength = 16 * 1024 * 1024

    mutating func extract(_ chunk: Data) -> [Data] {
        buffer.append(contentsOf: chunk)
        if buffer.count > Self.maxBufferLength {
            buffer = []
            hasPendingNAL = false
            return []
        }

        var units: [Data] = []
        var searchFrom = 0

        while searchFrom + 3 <= buffer.count {
            guard let match = Self.findStartCode(in: buffer, from: searchFrom) else { break }

            if hasPendingNAL {
                var end = match
                while end > 0, buffer[end - 1] == 0 {
                    end -= 1
                }
                if end > 0 {
                    units.append(Data(buffer[0..<end]))
                }
                hasPendingNAL = false
            }
            buffer = Array(buffer[(match + 3)...])
            searchFrom = 0
            hasPendingNAL = true
        }
        return units
    }

    private static func findStartCode(in buffer: [UInt8], from: Int) -> Int? {
        var index = from
        while index + 3 <= buffer.count {
            if buffer[index] == 0, buffer[index + 1] == 0, buffer[index + 2] == 1 {
                return index
            }
            index += 1
        }
        return nil
    }
}
