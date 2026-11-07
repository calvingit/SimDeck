import Foundation

public enum StartMode {
    case normal
    case coldBoot
    case wipeData
}

public enum EmulatorError: LocalizedError, Equatable {
    case emulatorMissing
    case adbMissing
    case startFailed(String)
    case stopFailed(String)
    case wipeFailed(String)
    case serialMismatch(serial: String, avdName: String)

    public var errorDescription: String? {
        switch self {
        case .emulatorMissing:
            return AppLanguage.text("tools.emulatorMissing")
        case .adbMissing:
            return AppLanguage.text("tools.adbMissing")
        case .startFailed(let detail):
            return AppLanguage.text("emulator.launchFailed", detail)
        case .stopFailed(let name):
            return AppLanguage.text("emulator.terminateFailed", name)
        case .wipeFailed(let detail):
            return AppLanguage.text("emulator.wipeFailed", detail)
        case .serialMismatch(let serial, let avdName):
            return AppLanguage.text("emulator.staleSerial", serial, avdName)
        }
    }
}

/// 负责启动/关闭/重启模拟器进程。所有方法都在后台队列串行调用。
public final class EmulatorController: @unchecked Sendable {
    public let tools: ToolPaths
    public let logDirectory: URL

    /// 由本 App 启动的模拟器进程退出时回调（AVD 名、退出码、日志尾部、是否主动停止）。
    public var onExit: ((_ avdName: String, _ status: Int32, _ logTail: String, _ intentional: Bool) -> Void)?

    private var processes: [String: Process] = [:]
    private var logHandles: [String: FileHandle] = [:]
    private var intentionalStops: Set<String> = []
    private var windowlessAVDs: Set<String> = []
    private let lock = NSLock()

    public init(tools: ToolPaths, logDirectory: URL) {
        self.tools = tools
        self.logDirectory = logDirectory
    }

    // MARK: - 启动

    /// 无窗口(headless)模式参数。固定 SwiftShader 软渲染，且不落快照：
    /// SwiftShader 会话保存的 quick boot 快照与窗口模式(host GPU)不兼容，
    /// GPU 不一致时模拟器会拒绝加载甚至删除快照。
    public static let windowlessArguments = [
        "-no-window",
        "-no-audio",
        "-no-boot-anim",
        "-gpu", "swiftshader_indirect",
        "-no-snapshot-save"
    ]

    public static func launchArguments(avdName: String, mode: StartMode, windowless: Bool = false) -> [String] {
        var arguments = ["-avd", avdName]
        switch mode {
        case .normal:
            break
        case .coldBoot, .wipeData:
            arguments.append("-no-snapshot-load")
        }
        if windowless {
            arguments.append(contentsOf: windowlessArguments)
        }
        return arguments
    }

    public func start(avdName: String, mode: StartMode, windowless: Bool = false) throws {
        guard let emulator = tools.emulator else {
            throw EmulatorError.emulatorMissing
        }
        lock.lock()
        let alreadyTracked = processes[avdName]?.isRunning == true
        lock.unlock()
        if alreadyTracked {
            throw EmulatorError.startFailed(AppLanguage.text("emulator.alreadyActive", avdName))
        }

        try FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )
        let logURL = logDirectory.appendingPathComponent("\(safeFileName(avdName)).log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.truncate(atOffset: 0)

        let process = Process()
        process.executableURL = emulator
        process.arguments = EmulatorController.launchArguments(avdName: avdName, mode: mode, windowless: windowless)
        process.environment = ToolEnvironment.make(tools: tools)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle

        process.terminationHandler = { [weak self] finished in
            self?.handleTermination(avdName: avdName, process: finished, logURL: logURL)
        }

        // 先登记再 run：进程若瞬间退出，terminationHandler 也能识别为当前进程。
        lock.lock()
        processes[avdName] = process
        logHandles[avdName] = handle
        intentionalStops.remove(avdName)
        if windowless {
            windowlessAVDs.insert(avdName)
        } else {
            windowlessAVDs.remove(avdName)
        }
        lock.unlock()

        do {
            try process.run()
        } catch {
            lock.lock()
            if processes[avdName] === process {
                processes.removeValue(forKey: avdName)
                logHandles.removeValue(forKey: avdName)
                windowlessAVDs.remove(avdName)
            }
            lock.unlock()
            try? handle.close()
            throw EmulatorError.startFailed(error.localizedDescription)
        }
    }

    private func handleTermination(avdName: String, process: Process, logURL: URL) {
        lock.lock()
        let isCurrentProcess = processes[avdName] === process
        var wasIntentional = false
        if isCurrentProcess {
            wasIntentional = intentionalStops.remove(avdName) != nil
            processes.removeValue(forKey: avdName)
            windowlessAVDs.remove(avdName)
            if let handle = logHandles.removeValue(forKey: avdName) {
                try? handle.close()
            }
        }
        lock.unlock()

        guard isCurrentProcess else { return }
        let tail = EmulatorController.logTail(at: logURL, lines: 15)
        onExit?(avdName, process.terminationStatus, tail, wasIntentional)
    }

    private static func logTail(at url: URL, lines: Int) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.components(separatedBy: .newlines).suffix(lines).joined(separator: "\n")
    }

    private func safeFileName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_")
    }

    /// 清数据时删除的镜像。保留 userdata.img（初始模板）、encryptionkey 与 snapshots。
    public static let wipeFileNames = [
        "userdata-qemu.img",
        "userdata-qemu.img.qcow2",
        "userdata.img.qcow2",
        "cache.img",
        "cache.img.qcow2"
    ]

    /// 结束实例 → 归档旧快照 → 删除 userdata/cache 镜像 → 带 `-no-snapshot-load` 冷启动。
    /// 不使用 emulator 的 `-wipe-data`：该选项会直接删除 snapshots。
    /// 旧快照改名为 `snapshots.pre-wipe-<时间>`，既保留文件，又避免后续 quickboot 把旧数据带回来。
    public func wipeData(avdName: String, avdPath: String, serial: String?) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: avdPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw EmulatorError.wipeFailed(AppLanguage.text("emulator.directoryMissing", avdPath))
        }

        try stop(serial: serial, avdName: avdName)
        try archiveSnapshots(avdPath: avdPath)

        let directory = URL(fileURLWithPath: avdPath)
        let files = FileManager.default
        for name in EmulatorController.wipeFileNames {
            let url = directory.appendingPathComponent(name)
            guard files.fileExists(atPath: url.path) else { continue }
            do {
                try files.removeItem(at: url)
            } catch {
                throw EmulatorError.wipeFailed(
                    AppLanguage.text("emulator.removeFileFailed", url.path, error.localizedDescription)
                )
            }
        }
        try start(avdName: avdName, mode: .wipeData)
    }

    private func archiveSnapshots(avdPath: String) throws {
        let files = FileManager.default
        let directory = URL(fileURLWithPath: avdPath)
        let snapshots = directory.appendingPathComponent("snapshots")
        guard files.fileExists(atPath: snapshots.path) else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        var destination = directory.appendingPathComponent("snapshots.pre-wipe-\(stamp)")
        var suffix = 2
        while files.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("snapshots.pre-wipe-\(stamp)-\(suffix)")
            suffix += 1
        }

        do {
            try files.moveItem(at: snapshots, to: destination)
        } catch {
            throw EmulatorError.wipeFailed(
                AppLanguage.text("emulator.archiveFailed", snapshots.path, error.localizedDescription)
            )
        }
    }

    // MARK: - 停止

    public func stop(serial: String?, avdName: String) throws {
        lock.lock()
        intentionalStops.insert(avdName)
        lock.unlock()

        var consoleKillAccepted = false
        var matchingSerial: String?
        if let serial, let adb = tools.adb, serialMatches(serial: serial, avdName: avdName) {
            matchingSerial = serial
            let result = try? CommandRunner.run(
                adb,
                ["-s", serial, "emu", "kill"],
                environment: ToolEnvironment.make(tools: tools),
                timeout: 20
            )
            consoleKillAccepted = result?.status == 0
        }

        if consoleKillAccepted, waitUntilStopped(serial: matchingSerial, avdName: avdName, timeout: 12) {
            return
        }

        // 启动阶段 adb 控制台可能还不可用，退回按命令行匹配进程。
        // 本 App 启动的 Process 也作为兜底，覆盖 emulator 路径是包装脚本的情况。
        var pids = Set<Int32>()
        if let tracked = trackedRunningPID(avdName: avdName) {
            pids.insert(tracked)
        }
        for pid in findEmulatorPIDs(avdName: avdName) {
            pids.insert(pid)
        }
        if !pids.isEmpty {
            for pid in pids { kill(pid, SIGTERM) }
            if waitUntilStopped(serial: matchingSerial, avdName: avdName, timeout: 6) {
                return
            }
            for pid in pids { kill(pid, SIGKILL) }
            if waitUntilStopped(serial: matchingSerial, avdName: avdName, timeout: 4) {
                return
            }
        } else if waitUntilStopped(serial: matchingSerial, avdName: avdName, timeout: 2) {
            return
        }

        throw EmulatorError.stopFailed(avdName)
    }

    /// 等待 adb 中 serial 消失，并且没有匹配 `-avd <name>` 的进程。
    public func waitUntilStopped(serial: String?, avdName: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let serialGone: Bool
            if let serial {
                serialGone = !serialPresent(serial)
            } else {
                serialGone = true
            }
            let trackedGone = trackedRunningPID(avdName: avdName) == nil
            if serialGone && trackedGone && findEmulatorPIDs(avdName: avdName).isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        return false
    }

    private func trackedRunningPID(avdName: String) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let process = processes[avdName], process.isRunning else { return nil }
        return process.processIdentifier
    }

    /// 本 App 启动的进程是否仍在运行。
    public func isTracking(avdName: String) -> Bool {
        trackedRunningPID(avdName: avdName) != nil
    }

    /// 本 App 是否以无窗口模式启动了该 AVD。
    public func isWindowless(avdName: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return windowlessAVDs.contains(avdName)
    }

    /// 对本 App 启动的实例发送 SIGTERM，不依赖 adb 控制台。
    /// 供 app 退出时快速终止无窗口实例（无窗口模式不落快照，无需优雅停机）。
    public func interruptTracked(avdName: String) {
        lock.lock()
        intentionalStops.insert(avdName)
        let process = processes[avdName]
        lock.unlock()
        process?.interrupt()
    }

    private func serialPresent(_ serial: String) -> Bool {
        guard let adb = tools.adb else { return false }
        guard let result = try? CommandRunner.run(
            adb,
            ["devices"],
            environment: ToolEnvironment.make(tools: tools),
            timeout: 20
        ), result.status == 0 else {
            return false
        }
        return ADBDevicesParser.parse(result.stdout).contains { $0.serial == serial }
    }

    /// 返回所有匹配 `-avd <name>` 的 emulator/qemu 进程。
    /// 不依赖可执行路径的 token 位置，因此路径含空格时仍能命中。
    public func findEmulatorPIDs(avdName: String) -> [Int32] {
        let ps = URL(fileURLWithPath: "/bin/ps")
        guard FileManager.default.isExecutableFile(atPath: ps.path) else { return [] }
        guard let result = try? CommandRunner.run(
            ps,
            ["-axo", "pid=,command="],
            environment: ToolEnvironment.make(tools: tools),
            timeout: 10
        ), result.status == 0 else {
            return []
        }

        var pids: [Int32] = []
        for rawLine in result.stdout.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lowercased = line.lowercased()
            guard lowercased.contains("emulator") || lowercased.contains("qemu-system") else {
                continue
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, let pid = Int32(parts[0]) else { continue }
            let tokens = parts.dropFirst()
            // 精确匹配 `-avd <name>`，避免 Pixel_5 误匹配 Pixel_5_2。
            for index in tokens.indices where tokens[index] == "-avd" {
                let next = tokens.index(after: index)
                if next < tokens.endIndex, tokens[next] == Substring(avdName) {
                    pids.append(pid)
                    break
                }
            }
        }
        return pids
    }

    public func findEmulatorPID(avdName: String) -> Int32? {
        findEmulatorPIDs(avdName: avdName).first
    }

    /// 确认 serial 当前确实对应指定 AVD，避免 serial 被复用后杀错实例。
    public func serialMatches(serial: String, avdName: String) -> Bool {
        guard let adb = tools.adb else { return false }
        guard let result = try? CommandRunner.run(
            adb,
            ["-s", serial, "emu", "avd", "name"],
            environment: ToolEnvironment.make(tools: tools),
            timeout: 20
        ), result.status == 0 else {
            return false
        }
        let actual = result.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0 != "OK" }
        return actual == avdName
    }

    // MARK: - 系统按键

    /// 发送 Android 按键事件（返回 4、桌面 3、任务列表 187、电源 26、音量 24/25）。
    public func sendKey(serial: String, keycode: Int) throws {
        guard let adb = tools.adb else {
            throw EmulatorError.adbMissing
        }
        let result = try CommandRunner.run(
            adb,
            ["-s", serial, "shell", "input", "keyevent", String(keycode)],
            environment: ToolEnvironment.make(tools: tools),
            timeout: 15
        )
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }
    }

    /// 模拟触摸点击，坐标为设备分辨率下的像素。
    public func sendTap(serial: String, x: Int, y: Int) throws {
        try inputCommand(serial: serial, arguments: ["tap", String(x), String(y)])
    }

    /// 模拟触摸滑动/长按，坐标为设备分辨率下的像素。
    public func sendSwipe(
        serial: String,
        x1: Int, y1: Int,
        x2: Int, y2: Int,
        durationMs: Int
    ) throws {
        try inputCommand(
            serial: serial,
            arguments: [
                "swipe", String(x1), String(y1), String(x2), String(y2),
                String(max(100, durationMs))
            ]
        )
    }

    /// 查询设备屏幕分辨率（`wm size`，优先 Override）。
    public func deviceResolution(serial: String) throws -> CGSize {
        guard let adb = tools.adb else {
            throw EmulatorError.adbMissing
        }
        let result = try CommandRunner.run(
            adb,
            ["-s", serial, "shell", "wm", "size"],
            environment: ToolEnvironment.make(tools: tools),
            timeout: 15
        )
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }

        var physical: CGSize?
        var override: CGSize?
        for rawLine in result.stdout.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Override size:") {
                override = Self.parseSize(line)
            } else if line.hasPrefix("Physical size:") {
                physical = physical ?? Self.parseSize(line)
            }
        }
        guard let size = override ?? physical, size.width > 0, size.height > 0 else {
            throw CommandRunnerError.nonZero(status: 1, stderr: AppLanguage.text("device.invalidResolution", result.stdout))
        }
        return size
    }

    private static func parseSize(_ line: String) -> CGSize? {
        guard let value = line.split(separator: ":").last?
            .trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        let parts = value.split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]) else {
            return nil
        }
        return CGSize(width: Double(width), height: Double(height))
    }

    private func inputCommand(serial: String, arguments: [String]) throws {
        guard let adb = tools.adb else {
            throw EmulatorError.adbMissing
        }
        let result = try CommandRunner.run(
            adb,
            ["-s", serial, "shell", "input"] + arguments,
            environment: ToolEnvironment.make(tools: tools),
            timeout: 15
        )
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }
    }

    // MARK: - 重启

    public func reboot(serial: String, avdName: String?) throws {
        guard let adb = tools.adb else {
            throw EmulatorError.adbMissing
        }
        if let avdName, !serialMatches(serial: serial, avdName: avdName) {
            throw EmulatorError.serialMismatch(serial: serial, avdName: avdName)
        }
        let result = try CommandRunner.run(
            adb,
            ["-s", serial, "reboot"],
            environment: ToolEnvironment.make(tools: tools),
            timeout: 30
        )
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }
    }
}
