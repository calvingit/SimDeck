import Foundation

/// `simctl -j` 输出不符合预期结构时抛出；缺字段的条目按默认值处理，不走到这里。
public enum SimctlParseError: LocalizedError, Equatable {
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let detail):
            return AppLanguage.text("ios.parseFailed", detail)
        }
    }
}

/// 封装 `simctl`：列表解析、生命周期管理、截图与输入影子检测。
public final class SimctlService: @unchecked Sendable {
    private let executable: URL

    /// 生命周期命令的实测约束：erase/clone 必须 Shutdown；delete/rename/reboot 运行中可用。
    public init(simctl: URL) {
        executable = simctl
    }

    /// 定位系统 simctl。依次检查 DEVELOPER_DIR 与 `xcode-select -p` 目录下的
    /// usr/bin/simctl；`xcode-select -p` 只做查询、不会触发开发者工具安装弹窗。
    /// 未配置开发者目录或文件不存在时返回 nil，由调用方整体停用 iOS 功能，
    /// 避免轮询经 xcrun 反复拉起安装提示。
    public static func locateSystemSimctl(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        files: FileManager = .default
    ) -> URL? {
        var candidates: [String] = []
        if let developerDir = environment["DEVELOPER_DIR"], !developerDir.isEmpty {
            candidates.append((developerDir as NSString).expandingTildeInPath)
        }
        if let directory = queryDeveloperDirectory() {
            candidates.append(directory)
        }
        for candidate in candidates {
            let simctl = URL(fileURLWithPath: candidate).appendingPathComponent("usr/bin/simctl")
            if files.isExecutableFile(atPath: simctl.path) {
                return simctl
            }
        }
        return nil
    }

    /// `xcode-select -p` 输出的开发目录；未配置或查询失败返回 nil（只查询，不弹安装提示）。
    public static func queryDeveloperDirectory(
        files: FileManager = .default
    ) -> String? {
        guard let result = try? CommandRunner.run(
            URL(fileURLWithPath: "/usr/bin/xcode-select"),
            ["-p"],
            timeout: 10
        ), result.status == 0 else {
            return nil
        }
        let directory = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { return nil }
        // 核对一次目录真实存在，避免设置页展示失效路径。
        return files.fileExists(atPath: directory) ? directory : nil
    }

    // MARK: - 列表

    /// 全部 iOS 模拟器（含不可用设备），按 runtime 版本降序、名称升序排列。
    public func listDevices() throws -> [SimulatorDevice] {
        let result = try run(["list", "-j", "devices"], timeout: 30)
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }
        // 类型名映射失败不影响设备列表本身，仅回退显示标识符。
        let deviceTypeNames = ((try? listDeviceTypes()) ?? [])
            .reduce(into: [String: String]()) { $0[$1.identifier] = $1.name }
        return try SimctlJSONParser.parseDevices(result.stdout, deviceTypeNames: deviceTypeNames)
    }

    /// 已安装的 runtime（全部平台，按版本降序）；调用方用 `isIOS` 过滤。
    public func listRuntimes() throws -> [SimulatorRuntime] {
        let result = try run(["list", "-j", "runtimes"], timeout: 30)
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }
        return try SimctlJSONParser.parseRuntimes(result.stdout)
    }

    /// 机型定义，按名称升序。
    public func listDeviceTypes() throws -> [SimulatorDeviceType] {
        let result = try run(["list", "-j", "devicetypes"], timeout: 30)
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }
        return try SimctlJSONParser.parseDeviceTypes(result.stdout)
    }

    // MARK: - 生命周期

    public func boot(udid: String) throws {
        try runOK(["boot", udid])
    }

    public func shutdown(udid: String) throws {
        try runOK(["shutdown", udid])
    }

    public func reboot(udid: String) throws {
        try runOK(["reboot", udid])
    }

    /// 返回新建设备的 UDID（simctl create 的 stdout）。
    @discardableResult
    public func create(name: String, deviceType: String, runtime: String) throws -> String {
        let result = try run(["create", name, deviceType, runtime])
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }
        let udid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else {
            throw CommandRunnerError.nonZero(status: 1, stderr: AppLanguage.text("ios.create.noUDID"))
        }
        return udid
    }

    public func rename(udid: String, to newName: String) throws {
        try runOK(["rename", udid, newName])
    }

    public func delete(udid: String) throws {
        try runOK(["delete", udid])
    }

    /// 抹掉设备内容。实测 erase 要求 Shutdown，isBooted 时由本服务先关机。
    public func erase(udid: String, isBooted: Bool) throws {
        if isBooted {
            try shutdown(udid: udid)
        }
        try runOK(["erase", udid])
    }

    // MARK: - App 管理

    /// 安装 .app bundle（路径指向 app 包目录）。安装可能耗时较长，超时放宽到 5 分钟。
    public func installApp(udid: String, appBundlePath: String) throws {
        try runOK(["install", udid, appBundlePath], timeout: 300)
    }

    public func uninstallApp(udid: String, bundleID: String) throws {
        try runOK(["uninstall", udid, bundleID], timeout: 120)
    }

    /// 启动已安装的应用；stdout 为进程 pid（原样返回，失败抛错）。
    @discardableResult
    public func launchApp(udid: String, bundleID: String) throws -> String {
        let result = try run(["launch", udid, bundleID])
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func terminateApp(udid: String, bundleID: String) throws {
        try runOK(["terminate", udid, bundleID])
    }

    /// 通过 URL scheme 打开链接（simctl openurl）；stdout 原样返回。
    @discardableResult
    public func openURL(udid: String, url: String) throws -> String {
        let result = try run(["openurl", udid, url])
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 已安装的应用（含系统应用），按 bundle id 升序。listapps 输出为 XML plist。
    public func listApps(udid: String) throws -> [SimulatorApp] {
        let result = try run(["listapps", udid], timeout: 120)
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }
        return try SimctlJSONParser.parseApps(result.stdout)
    }

    // MARK: - 截图

    /// `io screenshot -` 无法输出到 stdout（实测约束），写入临时文件后读回。
    public func screenshot(udid: String) throws -> Data {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("simdeck-simctl-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try run(["io", udid, "screenshot", output.path], timeout: 30)
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }
        let data = try Data(contentsOf: output)
        guard !data.isEmpty else {
            throw CommandRunnerError.nonZero(status: 1, stderr: AppLanguage.text("screenshot.emptyFile"))
        }
        return data
    }

    // MARK: - 输入影子检测

    /// Device Hub 启动后向已启动设备挂 dtuhidd，第三方 HID 注入失效；
    /// notifyutil 返回 1 表示输入被接管。
    public func isInputShadowed(udid: String) -> Bool {
        guard let result = try? run(
            ["spawn", udid, "notifyutil", "-g", "com.apple.coredevice.dtuhidd.active"],
            timeout: 15
        ) else {
            return false
        }
        return result.status == 0
            && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    // MARK: - 内部

    private func run(_ arguments: [String], timeout: TimeInterval = 60) throws -> CommandResult {
        try CommandRunner.run(executable, arguments, timeout: timeout)
    }

    private func runOK(_ arguments: [String], timeout: TimeInterval = 60) throws {
        let result = try run(arguments, timeout: timeout)
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }
    }
}

/// `simctl list -j` 输出的容错解码：字段全部按"缺省给默认值"处理，
/// 只有整体结构损坏（非 JSON、缺顶层键）才抛错。
enum SimctlJSONParser {
    static func parseDevices(
        _ json: String,
        deviceTypeNames: [String: String]
    ) throws -> [SimulatorDevice] {
        let payload = try decode(DevicesPayload.self, json: json, what: "devices")
        guard let groups = payload.devices else {
            throw SimctlParseError.malformed("missing devices")
        }

        var devices: [SimulatorDevice] = []
        for (runtimeIdentifier, list) in groups {
            guard let version = runtimeVersion(from: runtimeIdentifier) else { continue }
            for dto in list {
                guard let udid = dto.udid, !udid.isEmpty else { continue }
                let typeName = dto.deviceTypeIdentifier.flatMap { deviceTypeNames[$0] }
                    ?? dto.deviceTypeIdentifier
                    ?? ""
                devices.append(SimulatorDevice(
                    udid: udid,
                    name: dto.name ?? "",
                    state: dto.state ?? "",
                    isAvailable: dto.isAvailable ?? false,
                    runtimeVersion: version,
                    deviceTypeName: typeName,
                    dataPath: dto.dataPath
                ))
            }
        }
        devices.sort { left, right in
            let byRuntime = compareVersions(left.runtimeVersion, right.runtimeVersion)
            if byRuntime != .orderedSame { return byRuntime == .orderedDescending }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        return devices
    }

    static func parseRuntimes(_ json: String) throws -> [SimulatorRuntime] {
        let payload = try decode(RuntimesPayload.self, json: json, what: "runtimes")
        guard let list = payload.runtimes else {
            throw SimctlParseError.malformed("missing runtimes")
        }
        var runtimes = list.compactMap { dto -> SimulatorRuntime? in
            guard let identifier = dto.identifier, !identifier.isEmpty,
                  let version = dto.version, !version.isEmpty else { return nil }
            let supported = (dto.supportedDeviceTypes ?? []).compactMap(deviceType(from:))
            return SimulatorRuntime(
                identifier: identifier,
                version: version,
                buildVersion: dto.buildversion,
                isAvailable: dto.isAvailable ?? false,
                supportedDeviceTypes: supported
            )
        }
        runtimes.sort { compareVersions($0.version, $1.version) == .orderedDescending }
        return runtimes
    }

    static func parseDeviceTypes(_ json: String) throws -> [SimulatorDeviceType] {
        let payload = try decode(DeviceTypesPayload.self, json: json, what: "devicetypes")
        guard let list = payload.deviceTypes else {
            throw SimctlParseError.malformed("missing devicetypes")
        }
        let types = list.compactMap(deviceType(from:))
        return types.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// `simctl listapps` 输出（XML plist，按 bundle id 分组的字典）→ 已安装应用。
    /// CFBundleIdentifier 缺失时回退键名；名称依次取 CFBundleDisplayName / CFBundleName / bundle id。
    static func parseApps(_ plist: String) throws -> [SimulatorApp] {
        guard let data = plist.data(using: .utf8) else {
            throw SimctlParseError.malformed("listapps: not UTF-8")
        }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let root = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: &format
        ), let apps = root as? [String: [String: Any]] else {
            throw SimctlParseError.malformed("listapps: not a plist dictionary")
        }
        return apps.compactMap { key, entry -> SimulatorApp? in
            let bundleID = (entry["CFBundleIdentifier"] as? String) ?? key
            guard !bundleID.isEmpty else { return nil }
            let name = (entry["CFBundleDisplayName"] as? String)
                ?? (entry["CFBundleName"] as? String)
                ?? bundleID
            return SimulatorApp(
                bundleID: bundleID,
                name: name,
                version: entry["CFBundleShortVersionString"] as? String
            )
        }
        .sorted { $0.bundleID.localizedStandardCompare($1.bundleID) == .orderedAscending }
    }

    /// runtime 分组键 → 版本号；只接受 iOS runtime，其余平台（watchOS 等）返回 nil。
    static func runtimeVersion(from identifier: String) -> String? {
        guard identifier.hasPrefix(SimulatorRuntime.iosPrefix) else { return nil }
        let suffix = identifier.dropFirst(SimulatorRuntime.iosPrefix.count)
        guard !suffix.isEmpty else { return nil }
        return suffix.replacingOccurrences(of: "-", with: ".")
    }

    /// 按"."分段做数值比较，用于 runtime 排序。
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func decode<T: Decodable>(_ type: T.Type, json: String, what: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw SimctlParseError.malformed("\(what): not UTF-8")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SimctlParseError.malformed(String(describing: error))
        }
    }
}

// 解码容器全部可选：缺字段不崩，未知键自动忽略。
private extension SimctlJSONParser {
    struct DevicesPayload: Decodable {
        let devices: [String: [DeviceDTO]]?
    }

    struct DeviceDTO: Decodable {
        let udid: String?
        let name: String?
        let state: String?
        let isAvailable: Bool?
        let deviceTypeIdentifier: String?
        let dataPath: String?
    }

    struct RuntimesPayload: Decodable {
        let runtimes: [RuntimeDTO]?
    }

    struct RuntimeDTO: Decodable {
        let identifier: String?
        let version: String?
        let buildversion: String?
        let isAvailable: Bool?
        let supportedDeviceTypes: [DeviceTypeDTO]?
    }

    struct DeviceTypesPayload: Decodable {
        let deviceTypes: [DeviceTypeDTO]?

        enum CodingKeys: String, CodingKey {
            case deviceTypes = "devicetypes"
        }
    }

    struct DeviceTypeDTO: Decodable {
        let identifier: String?
        let name: String?
        let productFamily: String?
    }

    /// 机型 DTO → 模型；缺 identifier 的条目跳过。runtime 与 devicetypes 两个 JSON 共用。
    static func deviceType(from dto: DeviceTypeDTO) -> SimulatorDeviceType? {
        guard let identifier = dto.identifier, !identifier.isEmpty else { return nil }
        return SimulatorDeviceType(
            identifier: identifier,
            name: dto.name ?? "",
            productFamily: dto.productFamily
        )
    }
}
