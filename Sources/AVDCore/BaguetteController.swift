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

// MARK: - describe-ui / heal（一次性子进程，同步，在调用方后台队列执行）

/// baguette 输出解析失败；describe-ui 失败由调用方降级（无屏幕尺寸 → 不做触摸映射）。
public enum BaguetteParseError: LocalizedError, Equatable {
    case screenMissing

    public var errorDescription: String? {
        switch self {
        case .screenMissing:
            return AppLanguage.text("ios.baguette.screenMissing")
        }
    }
}

extension BaguetteController {
    public enum HealOutcome: Equatable, Sendable {
        /// backboardd/SpringBoard 已重启，输入面收回（heal 输出 "Input surface reclaimed"）。
        case reclaimed
        /// 设备没有影子，无需处理（heal 输出 "nothing to heal"）。
        case unshadowed
    }

    /// `baguette describe-ui --udid <udid>`：解析顶层元素的 `screen` 字段，
    /// 返回屏幕宽高（device points，设计 §8 实测事实 4——触摸坐标只认 points）。
    public static func describeScreen(udid: String, baguette: URL) throws -> CGSize {
        let result = try CommandRunner.run(baguette, ["describe-ui", "--udid", udid], timeout: 15)
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }
        return try parseScreenSize(result.stdout)
    }

    /// describe-ui 顶层 JSON 的 `screen` 字段：`{"width":402,"height":874,…}`（device points）。
    static func parseScreenSize(_ json: String) throws -> CGSize {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let screen = root["screen"] as? [String: Any],
              let width = (screen["width"] as? NSNumber)?.doubleValue,
              let height = (screen["height"] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
            throw BaguetteParseError.screenMissing
        }
        return CGSize(width: width, height: height)
    }

    /// `baguette heal --udid <udid>`：重启 backboardd/SpringBoard 收回输入面（约 4 秒，
    /// **会杀掉运行中的 App**——调用方必须先取得用户确认，或处于设备刚由本 app 启动的场景）。
    /// Outcome 的 summary 走 stderr 日志；同时检查 stdout 以防版本差异。
    @discardableResult
    public static func heal(udid: String, baguette: URL) throws -> HealOutcome {
        let result = try CommandRunner.run(baguette, ["heal", "--udid", udid], timeout: 60)
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }
        let output = result.stdout + "\n" + result.stderr
        return output.contains("Input surface reclaimed") ? .reclaimed : .unshadowed
    }
}

// MARK: - input 常驻会话

/// baguette `input` 常驻会话：每设备一个子进程（启动约 1s，另有首个手势的 HID warm-up）。
/// stdin 写 IOSGesture JSON 行，stdout 逐行回 ack（`{"ok":true}` / `{"ok":false,"error":…}`）。
/// baguette 启动时若检测到 Device Hub 影子接管，会在 stderr 打印一次建议 heal 的警告
/// （设计 §8 实测事实 3），这里解析后经 onShadowAdvice 上报，notifyutil 由调用方二次确认。
/// 公开状态与回调仅在主线程访问；send 亦在主线程调用。
public final class BaguetteInputSession: @unchecked Sendable {
    public struct Ack: Equatable, Sendable {
        public let ok: Bool
        public let error: String?
    }

    /// 主线程回调：每条 ack。ok=false 时 error 为 baguette 的原始错误串（如 "missing field: width"）。
    public var onAck: ((Ack) -> Void)?
    /// 主线程回调：stderr 出现 Device Hub 影子警告（每次会话至多一次）。
    public var onShadowAdvice: (() -> Void)?
    /// 主线程回调：会话进程退出；reason 为 nil 表示干净退出（stdin 关闭 / 退出码 0）。
    public var onEnded: ((String?) -> Void)?

    /// 当前服务的设备；stop 后为 nil。主线程访问。
    public private(set) var udid: String?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// stdout 半行缓冲，仅在 stdout readabilityHandler 上访问。
    private var stdoutBuffer = Data()
    /// 影子警告只上报一次，仅在 stderr readabilityHandler 上访问。
    private var shadowAdviceReported = false
    /// stderr 半行缓冲，仅在 stderr readabilityHandler 上访问。
    private var stderrLineBuffer = Data()
    /// 最近 stderr 行，仅主线程访问（异常退出时作为 ended 原因）。
    private var stderrLines: [String] = []

    public init() {}

    public var isRunning: Bool { process?.isRunning == true }

    public static func makeInputArguments(udid: String) -> [String] {
        ["input", "--udid", udid]
    }

    public func start(udid: String, baguette: URL) {
        stop()

        let process = Process()
        process.executableURL = baguette
        process.arguments = Self.makeInputArguments(udid: udid)

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.udid = udid
        stdoutBuffer = Data()
        shadowAdviceReported = false
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
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.consumeAckData(data)
        }
        process.terminationHandler = { [weak self] endedProcess in
            DispatchQueue.main.async {
                guard let self, self.process === endedProcess else { return }
                self.handleProcessEnd(endedProcess)
            }
        }

        do {
            try process.run()
        } catch {
            self.process = nil
            self.stdinHandle = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            self.udid = nil
            DispatchQueue.main.async { self.onEnded?(error.localizedDescription) }
        }
    }

    /// 写入一条手势（JSON 行）。主线程调用；会话未运行时丢弃——
    /// 会话的生死与重启由 AppModel 按预览目标流转管理，这里不重复上报。
    public func send(_ gesture: IOSGesture) throws {
        guard let stdinHandle, process?.isRunning == true else { return }
        let data = try JSONEncoder().encode(gesture)
        stdinHandle.write(data)
        stdinHandle.write(Data([UInt8(ascii: "\n")]))
    }

    /// 关闭 stdin 让 baguette 干净退出（"stdin closed, input session ending"），
    /// 2 秒后仍在则 SIGINT 兜底。对已意外退出的会话同样清空状态（udid 等），
    /// 调用方（AppModel.updateInputSession）依赖 stop 后会话彻底复位。
    public func stop() {
        let liveProcess = process
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdinHandle?.close()
        self.stdinHandle = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil
        self.process = nil
        self.udid = nil
        guard let liveProcess else { return }
        if liveProcess.isRunning {
            liveProcess.interrupt()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if liveProcess.isRunning {
                    kill(liveProcess.processIdentifier, SIGKILL)
                }
            }
        }
    }

    // MARK: - 解析辅助

    /// ack 行 → Ack；非 JSON 或缺 `ok` 字段返回 nil。
    static func parseAck(_ line: String) -> Ack? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? Bool else { return nil }
        return Ack(ok: ok, error: object["error"] as? String)
    }

    /// Device Hub 影子警告判定。baguette v0.2.13 的 advisory 一行内同时出现接管描述
    /// （"Device Hub has attached…"）与修复命令（`baguette heal …`），锚定这两条特征短语
    /// 并忽略大小写，避免把普通日志行误报成影子。
    static func isShadowAdviceLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.contains("device hub has attached") || lowered.contains("baguette heal")
    }

    // MARK: - 内部

    private func consumeAckData(_ data: Data) {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(stdoutBuffer[stdoutBuffer.startIndex..<newline])
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            guard !line.isEmpty,
                  let ack = Self.parseAck(String(decoding: line, as: UTF8.self)) else { continue }
            DispatchQueue.main.async { [weak self] in
                self?.onAck?(ack)
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
                if !self.shadowAdviceReported, Self.isShadowAdviceLine(text) {
                    self.shadowAdviceReported = true
                    self.onShadowAdvice?()
                }
            }
        }
    }

    private func handleProcessEnd(_ process: Process) {
        self.process = nil
        self.stdinHandle = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil
        let reason: String? = process.terminationStatus == 0
            ? nil
            : (stderrLines.last ?? AppLanguage.text("command.exitCode", String(process.terminationStatus)))
        onEnded?(reason)
    }
}
