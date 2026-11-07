import Combine
import CoreGraphics
import Darwin
import Foundation

/// baguette 增强档控制：二进制发现与 stream 子进程管理。
/// stream 每设备一个子进程，stdout 为 AVCC 分帧流（AVCCParser 分帧，VideoToolboxDecoder 解码）；
/// stop 发送 SIGINT——实测 baguette 收到 SIGINT 干净退出（设计 §8 G1）。
public final class BaguetteController: @unchecked Sendable {
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
    /// 主线程回调：stderr 行。baguette 把启动参数与输入影子警告写在 stderr（Phase 3 提示来源）。
    public var onStderrLine: ((String) -> Void)?

    private var process: Process?
    private var pipe: Pipe?
    private var stderrPipe: Pipe?

    private let parseQueue = DispatchQueue(label: "local.avdmenubar.baguette.parse")
    // 以下状态仅在 parseQueue 上访问。
    private var parser = AVCCParser()
    private let decoder = VideoToolboxDecoder()

    /// stderr 半行缓冲，仅在 stderr readabilityHandler 上访问。
    private var stderrLineBuffer = Data()
    /// 最近 stderr 行，仅在主线程访问（异常退出时作为 ended 原因）。
    private var stderrLines: [String] = []

    public init() {
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

    public var isRunning: Bool {
        process?.isRunning == true
    }

    // MARK: - 二进制发现与能力

    /// baguette 二进制定位：优先 app bundle 内 Resources/Helpers/Baguette（内嵌打包，见设计决策 3），
    /// 其次 PATH。都找不到返回 nil——增强档缺席，基础档（截图轮询）仍可用。
    public static func locateBinary(
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        searchPath: String? = ProcessInfo.processInfo.environment["PATH"],
        files: FileManager = .default
    ) -> URL? {
        var candidates: [String] = []
        if let bundleResourceURL {
            candidates.append(bundleResourceURL.appendingPathComponent("Helpers/Baguette").path)
        }
        if let searchPath {
            for directory in searchPath.split(separator: ":") where !directory.isEmpty {
                candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("Baguette").path)
            }
        }
        for candidate in candidates {
            if files.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// 增强档运行门槛（设计决策 2）：macOS 15+ 且 Apple Silicon（内嵌 baguette 的构建目标）。
    public static func isEnhancedTierSupported(
        systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Bool {
        guard systemVersion.majorVersion >= 15 else { return false }
        return isAppleSilicon()
    }

    private static func isAppleSilicon() -> Bool {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return false }
        var machine = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &machine, &size, nil, 0) == 0 else { return false }
        return String(cString: machine).hasPrefix("arm64")
    }

    // MARK: - stream 子进程

    public static func makeStreamArguments(udid: String) -> [String] {
        // 默认参数按设计 §8 实测：预览档 --fps 30 --scale 2（scale 2 省 72% 带宽，CPU 不受影响）。
        ["stream", "--udid", udid, "--format", "avcc", "--fps", "30", "--scale", "2"]
    }

    public func start(udid: String, baguette: URL) {
        stop()
        setState(.starting)

        let process = Process()
        process.executableURL = baguette
        process.arguments = Self.makeStreamArguments(udid: udid)
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        self.pipe = pipe
        self.process = process

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        self.stderrPipe = stderrPipe
        stderrLineBuffer = Data()
        stderrLines = []
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.consumeStderr(data)
        }

        process.terminationHandler = { [weak self] endedProcess in
            DispatchQueue.main.async {
                guard let self, self.process === endedProcess else { return }
                self.handleStreamEnd(endedProcess)
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
            self.parseQueue.async {
                self.consume(data)
            }
        }

        do {
            try process.run()
        } catch {
            self.process = nil
            self.pipe = nil
            self.stderrPipe = nil
            setState(.ended(reason: error.localizedDescription))
        }
    }

    public func stop() {
        if let process {
            pipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            self.pipe = nil
            self.stderrPipe = nil
            self.process = nil
            if process.isRunning {
                process.interrupt() // SIGINT：baguette 实测干净退出
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
        parseQueue.sync { teardownDecoderLocked() }
        setState(.idle)
    }

    // MARK: - 内部

    private func consume(_ data: Data) {
        for chunk in parser.extract(data) {
            switch chunk.tag {
            case .avcC:
                let sets = AVCCParser.parameterSets(inAVCCConfig: chunk.payload)
                guard !sets.isEmpty else { continue }
                do {
                    let size = try decoder.configure(parameterSets: sets)
                    let sizeCopy = size
                    DispatchQueue.main.async { self.frameSize = sizeCopy }
                } catch {
                    // avcC 不完整或会话建立失败：等待下一个 avcC
                }
            case .idr, .delta:
                // baguette 的 0x02/0x03 payload 即 AVCC sample（4 字节长度前缀 NAL），直接解码
                decoder.decode(avcc: chunk.payload)
            case .jpeg:
                // JPEG seed 供 MJPEG 场景提前出图；AVCC 路径不使用
                break
            }
        }
    }

    private func consumeStderr(_ data: Data) {
        stderrLineBuffer.append(data)
        while let newline = stderrLineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(stderrLineBuffer[stderrLineBuffer.startIndex..<newline])
            stderrLineBuffer.removeSubrange(stderrLineBuffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            let text = String(decoding: line, as: UTF8.self)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stderrLines.append(text)
                if self.stderrLines.count > 50 {
                    self.stderrLines.removeFirst(self.stderrLines.count - 50)
                }
                self.onStderrLine?(text)
            }
        }
    }

    private func handleStreamEnd(_ process: Process) {
        self.process = nil
        self.pipe = nil
        self.stderrPipe = nil
        parseQueue.async { self.teardownDecoderLocked() }
        let status = process.terminationStatus
        let reason = stderrLines.last ?? AppLanguage.text("command.exitCode", String(status))
        setState(.ended(reason: reason))
    }

    private func teardownDecoderLocked() {
        decoder.invalidate()
        parser = AVCCParser()
    }

    private func setState(_ s: StreamState) {
        DispatchQueue.main.async {
            self.state = s
            self.onState?(s)
        }
    }
}
