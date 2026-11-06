import Foundation

/// 调用 avdmanager 读取/删除 AVD。
public final class AVDRepository: @unchecked Sendable {
    public let tools: ToolPaths

    public init(tools: ToolPaths) {
        self.tools = tools
    }

    public func listAVDs() throws -> [AVD] {
        let result = try CommandRunner.run(
            tools.avdmanager,
            ["list", "avd"],
            environment: ToolEnvironment.make(tools: tools),
            timeout: 90
        )
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }

        var avds = AVDListParser.parse(result.stdout)
        for index in avds.indices {
            avds[index].apiLevel = apiLevel(for: avds[index])
        }
        return avds.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func deleteAVD(named name: String) throws {
        let result = try CommandRunner.run(
            tools.avdmanager,
            ["-s", "delete", "avd", "-n", name],
            environment: ToolEnvironment.make(tools: tools),
            timeout: 90
        )
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }
    }

    private func apiLevel(for avd: AVD) -> Int? {
        let configINI = URL(fileURLWithPath: avd.path).appendingPathComponent("config.ini")
        if let level = AVDConfig.apiLevel(configINIPath: configINI.path) {
            return level
        }
        let siblingINI = URL(fileURLWithPath: avd.path)
            .deletingLastPathComponent()
            .appendingPathComponent("\(avd.name).ini")
        return AVDConfig.apiLevel(configINIPath: siblingINI.path)
    }
}

/// 通过 adb 检测正在运行的模拟器/真机，并把 serial 映射回 AVD 名称。
public final class DeviceMonitor: @unchecked Sendable {
    private let tools: ToolPaths

    public init(tools: ToolPaths) {
        self.tools = tools
    }

    /// 当前在线（state == device）的模拟器与真机。
    public func runningDevices() throws -> [RunningEmulator] {
        guard let adb = tools.adb else {
            throw ToolPathError.missingTool("adb")
        }
        let environment = ToolEnvironment.make(tools: tools)
        let devicesResult = try CommandRunner.run(
            adb,
            ["devices", "-l"],
            environment: environment,
            timeout: 20
        )
        guard devicesResult.status == 0 else {
            throw CommandRunnerError.nonZero(
                status: devicesResult.status,
                stderr: devicesResult.failureDetail
            )
        }

        let online = ADBDevicesParser.parse(devicesResult.stdout).filter { $0.state == "device" }
        var running: [RunningEmulator] = []
        for device in online {
            if device.isEmulator {
                let name = resolveAVDName(
                    serial: device.serial,
                    adb: adb,
                    environment: environment
                )
                let booted = isBooted(
                    serial: device.serial,
                    adb: adb,
                    environment: environment
                )
                running.append(RunningEmulator(
                    serial: device.serial,
                    avdName: name,
                    isBooted: booted,
                    isRealDevice: false
                ))
            } else {
                // 真机：无 AVD 记录，booted 用 getprop 判断
                let booted = isBooted(
                    serial: device.serial,
                    adb: adb,
                    environment: environment
                )
                running.append(RunningEmulator(
                    serial: device.serial,
                    avdName: nil,
                    isBooted: booted,
                    isRealDevice: true
                ))
            }
        }
        return running.sorted { $0.serial.localizedStandardCompare($1.serial) == .orderedAscending }
    }

    /// 真机基础信息（型号 / Android 版本 / API level）。
    public func deviceProps(serial: String) throws -> DeviceProps {
        guard let adb = tools.adb else {
            throw ToolPathError.missingTool("adb")
        }
        let environment = ToolEnvironment.make(tools: tools)
        func getprop(_ property: String) throws -> String {
            let result = try CommandRunner.run(
                adb,
                ["-s", serial, "shell", "getprop", property],
                environment: environment,
                timeout: 20
            )
            guard result.status == 0 else {
                throw CommandRunnerError.nonZero(
                    status: result.status,
                    stderr: result.failureDetail
                )
            }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let model = try getprop("ro.product.model")
        let version = try getprop("ro.build.version.release")
        let sdk = try getprop("ro.build.version.sdk")
        guard !model.isEmpty, !version.isEmpty, let apiLevel = Int(sdk) else {
            throw CommandRunnerError.nonZero(
                status: 1,
                stderr: AppLanguage.text("device.invalidProperties", model, version, sdk)
            )
        }
        return DeviceProps(model: model, androidVersion: version, apiLevel: apiLevel)
    }

    /// 返回 serial 与 AVD 名的映射；停止实例前用于定位进程。
    private func resolveAVDName(
        serial: String,
        adb: URL,
        environment: [String: String]
    ) -> String? {
        guard let result = try? CommandRunner.run(
            adb,
            ["-s", serial, "emu", "avd", "name"],
            environment: environment,
            timeout: 20
        ), result.status == 0 else {
            return nil
        }
        return result.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0 != "OK" }
    }

    private func isBooted(
        serial: String,
        adb: URL,
        environment: [String: String]
    ) -> Bool {
        guard let result = try? CommandRunner.run(
            adb,
            ["-s", serial, "shell", "getprop", "sys.boot_completed"],
            environment: environment,
            timeout: 20
        ), result.status == 0 else {
            return false
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }
}
