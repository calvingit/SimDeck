import AppKit
import Combine
import Foundation
import SimDeckCore

enum PreviewPipeline: Equatable {
    case adbStream
    case polling
    case iosStream
    case iosPolling
}

/// 创建 iOS 模拟器所需的候选缺失时抛出。
enum SimulatorOptionError: LocalizedError {
    case unavailable
    case noRuntimes
    case noDeviceTypes

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return AppLanguage.text("ios.create.unavailable")
        case .noRuntimes:
            return AppLanguage.text("ios.create.noRuntimes")
        case .noDeviceTypes:
            return AppLanguage.text("ios.create.noDeviceTypes")
        }
    }
}

struct SettingsDraft: Equatable {
    var avdmanagerPath: String
    var emulatorPath: String
    var adbPath: String
    var baguettePath: String

    static let avdmanagerKey = "avdmanagerPathOverride"
    static let emulatorKey = "emulatorPathOverride"
    static let adbKey = "adbPathOverride"
    static let baguetteKey = "baguettePathOverride"

    static func load() -> SettingsDraft {
        let defaults = UserDefaults.standard
        return SettingsDraft(
            avdmanagerPath: defaults.string(forKey: avdmanagerKey) ?? "",
            emulatorPath: defaults.string(forKey: emulatorKey) ?? "",
            adbPath: defaults.string(forKey: adbKey) ?? "",
            baguettePath: defaults.string(forKey: baguetteKey) ?? ""
        )
    }

    func persist() {
        let defaults = UserDefaults.standard
        defaults.set(avdmanagerPath, forKey: Self.avdmanagerKey)
        defaults.set(emulatorPath, forKey: Self.emulatorKey)
        defaults.set(adbPath, forKey: Self.adbKey)
        defaults.set(baguettePath, forKey: Self.baguetteKey)
    }
}

/// 应用状态与所有命令调度。重活都在串行后台队列执行，状态只在主线程更新。
final class AppModel: ObservableObject {
    private let queue = DispatchQueue(label: "local.simdeck.commands")

    private(set) var tools: ToolPaths?
    private var repository: AVDRepository?
    private var emulator: EmulatorController?
    private var monitor: DeviceMonitor?
    private var snapshots: SnapshotService?
    private var provisioning: AVDProvisioningService?
    private var simctl: SimctlService?
    private var simulatorMonitor: SimulatorMonitor?
    /// 系统定位到的 simctl；iOS 日志菜单要借用同目录的 xcrun。
    private(set) var simctlURL: URL?
    let adbStreamer = ADBH264Streamer()
    let baguetteStreamer = BaguetteController()
    let baguetteInput = BaguetteInputSession()
    private(set) var baguetteURL: URL?
    /// 增强档可用性（baguette 已找到且 macOS 15+/arm64），installSimctlTools 时确定。
    private(set) var isEnhancedTierAvailable = false
    /// 设置页展示：开发目录与生效的 baguette（含版本）。
    @Published private(set) var developerDirectory: String?
    @Published private(set) var baguetteVersion: String?

    @Published private(set) var avds: [AVD] = []
    @Published private(set) var running: [RunningEmulator] = []
    @Published private(set) var listError: String?
    @Published private(set) var runtimeError: String?
    @Published private(set) var busyAVDs: Set<String> = []
    /// 由本 App 以无窗口模式启动的 AVD（会话内状态；app 退出时一并终止）。
    @Published private(set) var windowlessAVDs: Set<String> = []
    @Published private(set) var pinnedAVDs: Set<String> = []
    @Published private(set) var simulators: [SimulatorDevice] = []
    @Published private(set) var busySimulators: Set<String> = []
    @Published private(set) var iosError: String?
    /// iOS 模拟器屏幕尺寸（device points，来自 baguette describe-ui 的 `screen` 字段），触摸映射用。
    @Published private(set) var iosScreenPoints: [String: CGSize] = [:]
    /// 被 Device Hub 影子接管的设备：baguette input stderr 警告触发，notifyutil 二次确认后入库。
    @Published private(set) var shadowedUDIDs: Set<String> = []

    @Published var selectedDeviceID: DeviceEntry.ID?
    @Published private(set) var isRefreshing = false

    private var refreshGeneration = 0
    private static let pinnedKey = "pinnedAVDs"

    /// 冷启动/清数据期间保持 busy，直到新进程已启动，避免旧实例被轮询检测到时提前清除。
    private var busyHold: Set<String> = []

    var onError: ((String, String) -> Void)?

    private var refreshTimer: Timer?
    private var simulatorRefreshTimer: Timer?
    var cancellables = Set<AnyCancellable>()

    init() {
        loadPinnedAVDs()
        loadConfiguration()
        adbStreamer.$frame
            .receive(on: RunLoop.main)
            .sink { [weak self] image in self?.previewFrame = image }
            .store(in: &cancellables)
        adbStreamer.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.handleStreamState(state) }
            .store(in: &cancellables)
        baguetteStreamer.$frame
            .receive(on: RunLoop.main)
            .sink { [weak self] image in self?.previewFrame = image }
            .store(in: &cancellables)
        baguetteStreamer.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.handleBaguetteStreamState(state) }
            .store(in: &cancellables)
        baguetteInput.onShadowAdvice = { [weak self] in self?.confirmInputShadow() }
        baguetteInput.onAck = { [weak self] ack in self?.handleInputAck(ack) }
        baguetteInput.onEnded = { [weak self] reason in self?.handleInputSessionEnded(reason: reason) }
    }

    /// 置顶的 AVD（持久化到 UserDefaults）。
    func isPinned(_ avd: AVD) -> Bool {
        pinnedAVDs.contains(avd.name)
    }

    func togglePinned(_ avd: AVD) {
        if pinnedAVDs.contains(avd.name) {
            setPinned(pinnedAVDs.subtracting([avd.name]))
        } else {
            setPinned(pinnedAVDs.union([avd.name]))
        }
    }

    private func setPinned(_ names: Set<String>) {
        pinnedAVDs = names
        UserDefaults.standard.set(Array(names), forKey: Self.pinnedKey)
    }

    private func loadPinnedAVDs() {
        let names = UserDefaults.standard.stringArray(forKey: Self.pinnedKey) ?? []
        pinnedAVDs = Set(names)
    }

    func start() {
        refreshAll()
    }

    // MARK: - 配置

    func currentDraft() -> SettingsDraft {
        SettingsDraft.load()
    }

    /// 加载 UserDefaults 中的路径配置；失败时保留错误，供面板显示。
    /// iOS 模拟器工具不依赖 Android SDK，无论 Android 路径是否可用都安装。
    func loadConfiguration() {
        installSimctlTools()
        let draft = currentDraft()
        resolveBaguette(overridePath: draft.baguettePath)
        do {
            let resolved = try ToolLocator.resolve(
                avdmanagerOverride: draft.avdmanagerPath,
                emulatorOverride: draft.emulatorPath,
                adbOverride: draft.adbPath
            )
            installTools(resolved)
            listError = nil
        } catch {
            listError = error.localizedDescription
        }
    }

    /// 设置窗口保存时调用。失败不替换现有配置，返回错误说明；成功返回 nil。
    func applySettings(_ draft: SettingsDraft) -> String? {
        do {
            let resolved = try ToolLocator.resolve(
                avdmanagerOverride: draft.avdmanagerPath,
                emulatorOverride: draft.emulatorPath,
                adbOverride: draft.adbPath
            )
            installTools(resolved)
            resolveBaguette(overridePath: draft.baguettePath)
            draft.persist()
            listError = nil
            runtimeError = nil
            refreshAll()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// iOS 模拟器服务与 Android SDK 无关，装一次即可；重复调用保持原实例。
    /// 未安装 Xcode/CLT（定位不到 simctl）时 iOS 功能整体缺席：不轮询、不报错、不显示 iOS 行。
    private func installSimctlTools() {
        guard simctl == nil else { return }
        guard let simctlURL = SimctlService.locateSystemSimctl() else { return }
        let service = SimctlService(simctl: simctlURL)
        simctl = service
        self.simctlURL = simctlURL
        simulatorMonitor = SimulatorMonitor(simctl: service)
        developerDirectory = SimctlService.queryDeveloperDirectory()
    }

    /// 按覆盖路径重新定位 baguette 并刷新增强档可用性与版本。
    /// 路径变化时停掉在跑的 stream/input，让它们下次按新二进制重启；
    /// 版本读取是子进程调用，放后台队列，结果仅作展示。
    private func resolveBaguette(overridePath: String) {
        let previous = baguetteURL
        let located = BaguetteController.locateBinary(overridePath: overridePath)
        baguetteURL = located
        isEnhancedTierAvailable = located != nil && BaguetteController.isEnhancedTierSupported()
        if previous != located {
            baguetteStreamer.stop()
            baguetteInput.stop()
        }
        baguetteVersion = nil
        guard let located else { return }
        queue.async { [weak self] in
            let version = BaguetteController.version(of: located)
            DispatchQueue.main.async {
                guard let self, self.baguetteURL == located else { return }
                self.baguetteVersion = version
            }
        }
    }

    /// 设置页展示的生效 baguette 路径（覆盖 > 内嵌 > PATH）。
    var resolvedBaguettePath: String? { baguetteURL?.path }

    private func installTools(_ resolved: ToolPaths) {
        tools = resolved
        repository = AVDRepository(tools: resolved)
        monitor = DeviceMonitor(tools: resolved)
        snapshots = SnapshotService(tools: resolved)
        provisioning = AVDProvisioningService(tools: resolved)

        let logDirectory = Self.logDirectory
        let controller = EmulatorController(tools: resolved, logDirectory: logDirectory)
        controller.onExit = { [weak self] avdName, status, logTail, intentional in
            DispatchQueue.main.async {
                guard let self else { return }
                // 主动停止可能属于冷启动/清数据的中间步骤，此时保留 busy 直到新进程接管。
                if !intentional, !self.busyHold.contains(avdName) {
                    self.busyAVDs.remove(avdName)
                }
                self.windowlessAVDs.remove(avdName)
                if !intentional, status != 0 {
                    self.onError?(
                        AppLanguage.text("emulator.unexpectedExit", avdName),
                        AppLanguage.text("emulator.exitCode", String(status), logTail.isEmpty ? AppLanguage.text("emulator.noLog") : logTail)
                    )
                }
                self.refreshRunning()
            }
        }
        emulator = controller
    }

    /// 运行中 + 正在启动（尚未被 adb 发现）的实例数量，用于菜单栏徽标。
    var activeCount: Int {
        let knownNames = Set(avds.map(\.name))
        let detectedNames = Set(running.compactMap(\.avdName))
        let starting = busyAVDs.intersection(knownNames).subtracting(detectedNames)
        return running.count + starting.count
    }

    func isStarting(_ avdName: String) -> Bool {
        busyAVDs.contains(avdName)
    }

    // MARK: - 列表分组（面板与主界面共用）

    var runningByAVD: [String: RunningEmulator] {
        var map: [String: RunningEmulator] = [:]
        for device in running where device.avdName != nil {
            map[device.avdName!] = device
        }
        return map
    }

    var sortedRunning: [RunningEmulator] {
        running.sorted { l, r in
            let lp = l.avdName.map { pinnedAVDs.contains($0) } ?? false
            let rp = r.avdName.map { pinnedAVDs.contains($0) } ?? false
            if lp != rp { return lp }
            return l.serial.localizedStandardCompare(r.serial) == .orderedAscending
        }
    }

    func pinnedFirst(_ avds: [AVD]) -> [AVD] {
        avds.sorted { l, r in
            let lp = pinnedAVDs.contains(l.name)
            let rp = pinnedAVDs.contains(r.name)
            if lp != rp { return lp }
            return l.name.localizedStandardCompare(r.name) == .orderedAscending
        }
    }

    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SimDeck", isDirectory: true)
    }

    func logFileURL(for avd: AVD) -> URL {
        Self.logDirectory.appendingPathComponent(avd.name.replacingOccurrences(of: "/", with: "_") + ".log")
    }

    // MARK: - 刷新

    func refreshAll() {
        if tools == nil {
            loadConfiguration()
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        refreshAVDs()
        refreshRunning {
            if self.refreshGeneration == generation { self.isRefreshing = false }
        }
        refreshSimulators()
    }

    func refreshAVDs(completion: (() -> Void)? = nil) {
        guard let repository else {
            if listError == nil {
                listError = AppLanguage.text("tools.avdmanagerUnconfigured")
            }
            completion?()
            return
        }
        queue.async { [weak self] in
            let result = Result { try repository.listAVDs() }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let avds):
                    if self.avds != avds {
                        self.avds = avds
                    }
                    if self.listError != nil {
                        self.listError = nil
                    }
                case .failure(let error):
                    self.listError = error.localizedDescription
                }
                completion?()
            }
        }
    }

    func refreshRunning(completion: (() -> Void)? = nil) {
        guard let monitor else {
            scheduleNextRunningRefresh()
            completion?()
            return
        }
        queue.async { [weak self] in
            let result = Result { try monitor.runningDevices() }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let running):
                    if self.running != running {
                        self.running = running
                    }
                    if self.runtimeError != nil {
                        self.runtimeError = nil
                    }
                    let names = Set(running.compactMap(\.avdName))
                    let nextBusy = self.busyAVDs.subtracting(names.subtracting(self.busyHold))
                    if nextBusy != self.busyAVDs {
                        self.busyAVDs = nextBusy
                    }
                    for device in running where device.isRealDevice {
                        self.fetchDeviceProps(for: device.serial)
                    }
                case .failure(let error):
                    // 保留上一次已知的运行状态，避免探测失败时把运行中的实例误判为未运行。
                    self.runtimeError = error.localizedDescription
                }
                self.scheduleNextRunningRefresh()
                completion?()
            }
        }
    }

    private func scheduleNextRunningRefresh() {
        refreshTimer?.invalidate()
        let needsFastPolling = !busyAVDs.isEmpty || running.contains(where: { !$0.isBooted })
        let interval: TimeInterval = needsFastPolling ? 1.0 : 3.0
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.refreshRunning()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - 生命周期操作

    func start(_ avd: AVD) {
        guard let emulator, !isStarting(avd.name), runningByAVD[avd.name] == nil else { return }
        busyAVDs.insert(avd.name)
        queue.async { [weak self] in
            do {
                try emulator.start(avdName: avd.name, mode: .normal)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.refreshRunning()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busyAVDs.remove(avd.name)
                    self.onError?(AppLanguage.text("operation.startFailed"), error.localizedDescription)
                }
            }
        }
    }

    /// 无窗口启动：不弹模拟器 GUI 窗口，预览与输入都走 adb，适合纯预览场景。
    func startWindowless(_ avd: AVD) {
        guard let emulator, !isStarting(avd.name), runningByAVD[avd.name] == nil else { return }
        busyAVDs.insert(avd.name)
        queue.async { [weak self] in
            do {
                try emulator.start(avdName: avd.name, mode: .normal, windowless: true)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.windowlessAVDs.insert(avd.name)
                    self.refreshRunning()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busyAVDs.remove(avd.name)
                    self.onError?(AppLanguage.text("operation.startFailed"), error.localizedDescription)
                }
            }
        }
    }

    /// 无窗口实例切换为窗口模式：关闭当前实例后以窗口参数重启（quick boot 快）。
    /// 模拟器无法给运行中的无头进程附加窗口，重启是唯一途径。
    func openInWindow(_ avd: AVD) {
        guard let emulator, !isStarting(avd.name), windowlessAVDs.contains(avd.name) else { return }
        busyAVDs.insert(avd.name)
        busyHold.insert(avd.name)
        queue.async { [weak self] in
            do {
                try emulator.stop(serial: nil, avdName: avd.name)
                try emulator.start(avdName: avd.name, mode: .normal)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busyHold.remove(avd.name)
                    if !emulator.isTracking(avdName: avd.name) {
                        self.busyAVDs.remove(avd.name)
                    }
                    self.refreshRunning()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busyHold.remove(avd.name)
                    self.busyAVDs.remove(avd.name)
                    self.onError?(AppLanguage.text("operation.openInWindowFailed"), error.localizedDescription)
                    self.refreshRunning()
                }
            }
        }
    }

    /// app 退出时终止由本 App 启动的无窗口实例：无窗口实例不可见，遗留在后台无法被用户感知。
    func stopWindowlessInstances() {
        guard let emulator else { return }
        for avdName in windowlessAVDs {
            emulator.interruptTracked(avdName: avdName)
        }
    }

    func coldBoot(displayName: String, serial: String?, avd: AVD?) {
        guard let emulator, let avdName = avd?.name ?? runningAVDName(forSerial: serial) else {
            onError?(AppLanguage.text("operation.coldBootFailed"), AppLanguage.text("operation.avdNameMissing"))
            return
        }
        guard !isStarting(avdName), runningByAVD[avdName]?.isBooted != false else { return }
        busyAVDs.insert(avdName)
        busyHold.insert(avdName)
        queue.async { [weak self] in
            do {
                try emulator.stop(serial: serial, avdName: avdName)
                try emulator.start(avdName: avdName, mode: .coldBoot)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busyHold.remove(avdName)
                    if !emulator.isTracking(avdName: avdName) {
                        self.busyAVDs.remove(avdName)
                    }
                    self.refreshRunning()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busyHold.remove(avdName)
                    self.busyAVDs.remove(avdName)
                    self.onError?(AppLanguage.text("operation.coldBootFailedNamed", displayName), error.localizedDescription)
                    self.refreshRunning()
                }
            }
        }
    }

    func shutdown(displayName: String, serial: String?, avdName: String?) {
        guard let emulator, let avdName else {
            onError?(AppLanguage.text("operation.shutdownFailed"), AppLanguage.text("operation.avdNameMissing"))
            return
        }
        queue.async { [weak self] in
            do {
                try emulator.stop(serial: serial, avdName: avdName)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busyHold.remove(avdName)
                    self.busyAVDs.remove(avdName)
                    self.refreshRunning()
                }
            } catch {
                self?.reportOperationError(AppLanguage.text("operation.shutdownFailedNamed", displayName), error)
            }
        }
    }

    func softReboot(displayName: String, serial: String, avdName: String?) {
        guard let emulator else { return }
        queue.async { [weak self] in
            do {
                try emulator.reboot(serial: serial, avdName: avdName)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.refreshRunning()
                }
            } catch {
                self?.reportOperationError(AppLanguage.text("operation.rebootFailed", displayName), error)
            }
        }
    }

    func wipeData(displayName: String, serial: String?, avd: AVD) {
        guard let emulator else { return }
        busyAVDs.insert(avd.name)
        busyHold.insert(avd.name)
        queue.async { [weak self] in
            do {
                try emulator.wipeData(
                    avdName: avd.name,
                    avdPath: avd.path,
                    serial: serial
                )
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busyHold.remove(avd.name)
                    if !emulator.isTracking(avdName: avd.name) {
                        self.busyAVDs.remove(avd.name)
                    }
                    self.refreshRunning()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busyHold.remove(avd.name)
                    self.busyAVDs.remove(avd.name)
                    self.onError?(AppLanguage.text("emulator.wipeFailed", displayName), error.localizedDescription)
                    self.refreshRunning()
                }
            }
        }
    }

    func delete(_ avd: AVD, serial: String?) {
        guard let repository else { return }
        let emulator = self.emulator
        queue.async { [weak self] in
            do {
                // 无条件先走一次停止流程：即使 UI 状态过期，也保证不会删除运行中的 AVD 目录。
                if let emulator {
                    try emulator.stop(serial: serial, avdName: avd.name)
                }
                try repository.deleteAVD(named: avd.name)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.setPinned(self.pinnedAVDs.subtracting([avd.name]))
                    self.refreshAVDs()
                    self.refreshRunning()
                }
            } catch {
                self?.reportOperationError(AppLanguage.text("operation.deleteFailed", avd.name), error)
            }
        }
    }

    // MARK: - iOS 模拟器

    func refreshSimulators(completion: (() -> Void)? = nil) {
        guard let simulatorMonitor else {
            completion?()
            return
        }
        queue.async { [weak self] in
            let result = Result { try simulatorMonitor.devices() }
            DispatchQueue.main.async {
                guard let self else {
                    completion?()
                    return
                }
                switch result {
                case .success(let devices):
                    if self.simulators != devices {
                        self.simulators = devices
                    }
                    if self.iosError != nil {
                        self.iosError = nil
                    }
                case .failure(let error):
                    // 保留上一次已知的设备列表，避免探测失败时清空面板。
                    self.iosError = error.localizedDescription
                }
                self.scheduleNextSimulatorRefresh()
                completion?()
            }
        }
    }

    private func scheduleNextSimulatorRefresh() {
        simulatorRefreshTimer?.invalidate()
        let needsFastPolling = !busySimulators.isEmpty
            || simulators.contains { !$0.isBooted && $0.state != "Shutdown" }
        let interval: TimeInterval = needsFastPolling ? 1.0 : 3.0
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.refreshSimulators()
        }
        RunLoop.main.add(timer, forMode: .common)
        simulatorRefreshTimer = timer
    }

    func bootSimulator(_ device: SimulatorDevice) {
        guard let simctl, !busySimulators.contains(device.udid), !device.isBooted else { return }
        busySimulators.insert(device.udid)
        queue.async { [weak self] in
            do {
                try simctl.boot(udid: device.udid)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.busySimulators.remove(device.udid)
                    // 本 app 启动的设备自动 heal（设计 §4）：刚开机时没有运行中的 App，
                    // heal 的 SpringBoard 重启零代价；若 Device Hub 恰好开着，其 dtuhidd
                    // 会在开机后数秒内挂到设备上，延迟执行让影子先出现再收回。
                    if self.isEnhancedTierAvailable, let baguette = self.baguetteURL {
                        self.scheduleAutoHeal(udid: device.udid, baguette: baguette)
                    }
                    self.refreshSimulators()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.busySimulators.remove(device.udid)
                    self.onError?(AppLanguage.text("ios.startFailed", device.name), error.localizedDescription)
                    self.refreshSimulators()
                }
            }
        }
    }

    func shutdownSimulator(_ device: SimulatorDevice) {
        guard let simctl, !busySimulators.contains(device.udid), device.isBooted else { return }
        busySimulators.insert(device.udid)
        queue.async { [weak self] in
            do {
                try simctl.shutdown(udid: device.udid)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.busySimulators.remove(device.udid)
                    self.refreshSimulators()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.busySimulators.remove(device.udid)
                    self.onError?(AppLanguage.text("ios.shutdownFailed", device.name), error.localizedDescription)
                    self.refreshSimulators()
                }
            }
        }
    }

    func rebootSimulator(_ device: SimulatorDevice) {
        guard let simctl, !busySimulators.contains(device.udid), device.isBooted else { return }
        busySimulators.insert(device.udid)
        queue.async { [weak self] in
            do {
                try simctl.reboot(udid: device.udid)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.busySimulators.remove(device.udid)
                    self.refreshSimulators()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.busySimulators.remove(device.udid)
                    self.onError?(AppLanguage.text("ios.restartFailed", device.name), error.localizedDescription)
                    self.refreshSimulators()
                }
            }
        }
    }

    func eraseSimulator(_ device: SimulatorDevice) {
        guard let simctl, !busySimulators.contains(device.udid) else { return }
        busySimulators.insert(device.udid)
        queue.async { [weak self] in
            do {
                // 以最新列表核对开关机状态，避免 UI 状态过期导致 erase 前置 shutdown 报错。
                let booted = (try? simctl.listDevices()
                    .first { $0.udid == device.udid }?.isBooted) ?? device.isBooted
                try simctl.erase(udid: device.udid, isBooted: booted)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.busySimulators.remove(device.udid)
                    self.refreshSimulators()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.busySimulators.remove(device.udid)
                    self.onError?(AppLanguage.text("ios.eraseFailed", device.name), error.localizedDescription)
                    self.refreshSimulators()
                }
            }
        }
    }

    func deleteSimulator(_ device: SimulatorDevice) {
        guard let simctl, !busySimulators.contains(device.udid) else { return }
        busySimulators.insert(device.udid)
        queue.async { [weak self] in
            do {
                try simctl.delete(udid: device.udid)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.busySimulators.remove(device.udid)
                    self.refreshSimulators()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.busySimulators.remove(device.udid)
                    self.onError?(AppLanguage.text("ios.deleteFailed", device.name), error.localizedDescription)
                    self.refreshSimulators()
                }
            }
        }
    }

    func renameSimulator(_ device: SimulatorDevice, newName: String) {
        guard let simctl, !busySimulators.contains(device.udid), newName != device.name else { return }
        busySimulators.insert(device.udid)
        queue.async { [weak self] in
            do {
                try simctl.rename(udid: device.udid, to: newName)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.busySimulators.remove(device.udid)
                    self.refreshSimulators()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.busySimulators.remove(device.udid)
                    self.onError?(AppLanguage.text("ios.renameFailed", device.name), error.localizedDescription)
                    self.refreshSimulators()
                }
            }
        }
    }

    func createSimulator(name: String, deviceType: String, runtime: String) {
        guard let simctl else { return }
        queue.async { [weak self] in
            do {
                try simctl.create(name: name, deviceType: deviceType, runtime: runtime)
                DispatchQueue.main.async { [weak self] in
                    self?.refreshSimulators()
                }
            } catch {
                self?.reportOperationError(AppLanguage.text("ios.createFailed"), error)
            }
        }
    }

    /// 创建对话框的候选：iOS runtime 与机型定义。
    func simulatorProvisioningOptions(
        completion: @escaping (Result<(deviceTypes: [SimulatorDeviceType], runtimes: [SimulatorRuntime]), Error>) -> Void
    ) {
        guard let simulatorMonitor else {
            completion(.failure(SimulatorOptionError.unavailable))
            return
        }
        queue.async {
            do {
                let runtimes = try simulatorMonitor.iosRuntimes()
                let deviceTypes = try simulatorMonitor.deviceTypes()
                DispatchQueue.main.async {
                    if runtimes.isEmpty {
                        completion(.failure(SimulatorOptionError.noRuntimes))
                    } else if deviceTypes.isEmpty {
                        completion(.failure(SimulatorOptionError.noDeviceTypes))
                    } else {
                        completion(.success((deviceTypes, runtimes)))
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - iOS App 管理

    /// 安装 .app（耗时操作，占用 busy 状态）；完成后刷新列表。
    func installApp(on device: SimulatorDevice, at path: String) {
        guard let simctl, !busySimulators.contains(device.udid) else { return }
        busySimulators.insert(device.udid)
        queue.async { [weak self] in
            do {
                try simctl.installApp(udid: device.udid, appBundlePath: path)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busySimulators.remove(device.udid)
                    self.refreshSimulators()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.busySimulators.remove(device.udid)
                    self.onError?(AppLanguage.text("ios.app.installFailed", device.name), error.localizedDescription)
                }
            }
        }
    }

    func launchApp(on device: SimulatorDevice, bundleID: String) {
        guard let simctl else { return }
        queue.async { [weak self] in
            do {
                try simctl.launchApp(udid: device.udid, bundleID: bundleID)
            } catch {
                self?.reportOperationError(AppLanguage.text("ios.app.launchFailed", bundleID), error)
            }
        }
    }

    func terminateApp(on device: SimulatorDevice, bundleID: String) {
        guard let simctl else { return }
        queue.async { [weak self] in
            do {
                try simctl.terminateApp(udid: device.udid, bundleID: bundleID)
            } catch {
                self?.reportOperationError(AppLanguage.text("ios.app.terminateFailed", bundleID), error)
            }
        }
    }

    func uninstallApp(on device: SimulatorDevice, bundleID: String) {
        guard let simctl else { return }
        queue.async { [weak self] in
            do {
                try simctl.uninstallApp(udid: device.udid, bundleID: bundleID)
            } catch {
                self?.reportOperationError(AppLanguage.text("ios.app.uninstallFailed", bundleID), error)
            }
        }
    }

    func openURL(on device: SimulatorDevice, url: String) {
        guard let simctl else { return }
        queue.async { [weak self] in
            do {
                try simctl.openURL(udid: device.udid, url: url)
            } catch {
                self?.reportOperationError(AppLanguage.text("ios.app.openURLFailed", url), error)
            }
        }
    }

    // MARK: - iOS 触摸输入与 heal（增强档）

    /// input 会话的启动时刻；结束/停止时清空。运行 ≥5s 后才意外退出才允许重启，
    /// 避免坏二进制导致的快速死亡被反复拉起（与 ADB 流的失败计数同一思路）。
    private var inputStartedAt: Date?
    private var inputRestartWorkItem: DispatchWorkItem?

    /// input 常驻会话与预览管线无关：目标是已启动的 iOS 模拟器且增强档可用时保持运行，
    /// stream 降级到截图轮询后触摸与按键仍然可用。
    private func updateInputSession(udid: String?, booted: Bool, isSimulator: Bool) {
        if isSimulator, booted, isEnhancedTierAvailable, let udid, let baguette = baguetteURL {
            if baguetteInput.udid != udid {
                baguetteInput.stop()
                startBaguetteInput(udid: udid, baguette: baguette)
            } else if !baguetteInput.isRunning {
                startBaguetteInput(udid: udid, baguette: baguette)
            }
        } else if baguetteInput.udid != nil {
            baguetteInput.stop()
        }
    }

    private func startBaguetteInput(udid: String, baguette: URL) {
        inputRestartWorkItem?.cancel()
        inputStartedAt = Date()
        baguetteInput.start(udid: udid, baguette: baguette)
        refreshIOSScreenPoints(udid: udid)
    }

    /// describe-ui 拿屏幕 points 尺寸（触摸映射的必备条件）；失败时保持 nil，触摸映射自然禁用。
    private func refreshIOSScreenPoints(udid: String) {
        guard let baguette = baguetteURL else { return }
        queue.async { [weak self] in
            let size = try? BaguetteController.describeScreen(udid: udid, baguette: baguette)
            DispatchQueue.main.async {
                guard let self, self.previewUDID == udid else { return }
                if let size {
                    self.iosScreenPoints[udid] = size
                } else {
                    self.iosScreenPoints.removeValue(forKey: udid)
                }
            }
        }
    }

    func sendIOSGesture(udid: String, _ gesture: IOSGesture) {
        guard baguetteInput.udid == udid, baguetteInput.isRunning else { return }
        do {
            try baguetteInput.send(gesture)
        } catch {
            reportOperationError(AppLanguage.text("ios.input.gestureFailed"), error)
        }
    }

    /// 手动 heal：入口在 AppCoordinator 的确认弹窗之后（heal 会杀运行中的 App）。
    func healSimulator(_ device: SimulatorDevice) {
        guard let baguette = baguetteURL, !busySimulators.contains(device.udid) else { return }
        busySimulators.insert(device.udid)
        queue.async { [weak self] in
            do {
                let outcome = try BaguetteController.heal(udid: device.udid, baguette: baguette)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busySimulators.remove(device.udid)
                    guard outcome == .reclaimed else { return }
                    self.shadowedUDIDs.remove(device.udid)
                    // heal 重启了 backboardd/SpringBoard：重建输入会话重新绑定 HID 面。
                    if self.baguetteInput.udid == device.udid, let url = self.baguetteURL {
                        self.startBaguetteInput(udid: device.udid, baguette: url)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busySimulators.remove(device.udid)
                    self.onError?(AppLanguage.text("ios.heal.failed", device.name), error.localizedDescription)
                }
            }
        }
    }

    /// baguette input 启动时报告影子警告 → notifyutil 二次确认后入库，UI 据此提示修复。
    private func confirmInputShadow() {
        guard let udid = baguetteInput.udid, let simctl else { return }
        queue.async { [weak self] in
            let shadowed = simctl.isInputShadowed(udid: udid)
            DispatchQueue.main.async {
                guard let self, self.baguetteInput.udid == udid, shadowed else { return }
                self.shadowedUDIDs.insert(udid)
            }
        }
    }

    private func handleInputAck(_ ack: BaguetteInputSession.Ack) {
        guard !ack.ok else { return }
        onError?(
            AppLanguage.text("ios.input.gestureFailed"),
            AppLanguage.text("ios.input.rejected", ack.error ?? "unknown error")
        )
    }

    private func handleInputSessionEnded(reason: String?) {
        // 意外退出时 BaguetteInputSession.handleProcessEnd 不清 udid，这里据此区分：
        // 主动 stop（udid 已为 nil）无需处理；意外退出则按目标状态决定是否重启。
        guard let udid = baguetteInput.udid else { return }
        shadowedUDIDs.remove(udid)
        let ran = inputStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        inputStartedAt = nil
        guard reason != nil, ran >= 5,
              previewUDID == udid, previewBooted, isEnhancedTierAvailable,
              let baguette = baguetteURL else { return }
        inputRestartWorkItem?.cancel()
        let restart = DispatchWorkItem { [weak self] in
            // 会话仍服务同一设备且未在运行才重启：期间若用户切走再切回，
            // updateInputSession 已拉起新会话（isRunning），不得重复启动。
            guard let self, self.previewUDID == udid,
                  !self.baguetteInput.isRunning, self.baguetteInput.udid == udid else { return }
            self.startBaguetteInput(udid: udid, baguette: baguette)
        }
        inputRestartWorkItem = restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: restart)
    }

    /// 设备由本 app boot 后延迟执行 heal；对没有影子的设备只是 no-op
    /// （baguette 自身会输出 "nothing to heal"），对已关闭/启动中的设备同样无害。
    private func scheduleAutoHeal(udid: String, baguette: URL) {
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.isEnhancedTierAvailable else { return }
            let outcome = try? BaguetteController.heal(udid: udid, baguette: baguette)
            DispatchQueue.main.async {
                if outcome == .reclaimed {
                    self.shadowedUDIDs.remove(udid)
                }
            }
        }
    }

    // MARK: - 快照

    func snapshotNames(for avd: AVD) -> [String] {
        snapshots?.list(avdPath: avd.path) ?? []
    }

    func saveSnapshot(avd: AVD, serial: String, name: String) {
        guard let snapshots else { return }
        queue.async { [weak self] in
            do {
                try snapshots.save(serial: serial, avdName: avd.name, name: name)
            } catch {
                self?.reportOperationError(AppLanguage.text("operation.saveSnapshotFailed", avd.name), error)
            }
        }
    }

    func loadSnapshot(avd: AVD, serial: String, name: String) {
        guard let snapshots else { return }
        queue.async { [weak self] in
            do {
                try snapshots.load(serial: serial, avdName: avd.name, name: name)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.refreshRunning()
                }
            } catch {
                self?.reportOperationError(AppLanguage.text("operation.loadSnapshotFailed", avd.name), error)
            }
        }
    }

    func deleteSnapshot(avd: AVD, serial: String?, name: String) {
        guard let snapshots else { return }
        // 优先使用调用时 UI 的 serial；没有则按当前运行列表补一次。
        let knownSerial = serial ?? running.first(where: { $0.avdName == avd.name })?.serial
        let emulator = self.emulator
        queue.async { [weak self] in
            do {
                if knownSerial == nil,
                   let emulator,
                   !emulator.findEmulatorPIDs(avdName: avd.name).isEmpty {
                    throw SnapshotError.consoleFailed(AppLanguage.text("snapshot.delete.stopFirst"))
                }
                try snapshots.delete(
                    serial: knownSerial,
                    avdName: avd.name,
                    avdPath: avd.path,
                    name: name
                )
            } catch {
                self?.reportOperationError(AppLanguage.text("snapshot.deleteFailed", avd.name), error)
            }
        }
    }

    // MARK: - AVD 管理

    func provisioningOptions(
        completion: @escaping (Result<(images: [SystemImage], devices: [String]), Error>) -> Void
    ) {
        guard let provisioning else {
            completion(.failure(ProvisioningError.sdkMissing))
            return
        }
        queue.async {
            let images = provisioning.systemImages()
            guard !images.isEmpty else {
                DispatchQueue.main.async { completion(.failure(ProvisioningError.noSystemImages)) }
                return
            }
            do {
                let devices = try provisioning.deviceProfiles()
                DispatchQueue.main.async { completion(.success((images, devices))) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func createAVD(name: String, imageID: String, device: String) {
        guard let provisioning else { return }
        queue.async { [weak self] in
            do {
                try provisioning.create(name: name, imageID: imageID, device: device)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.refreshAVDs()
                }
            } catch {
                self?.reportOperationError(AppLanguage.text("operation.createFailed"), error)
            }
        }
    }

    func renameAVD(avd: AVD, serial: String?, newName: String) {
        guard let provisioning else { return }
        let emulator = self.emulator
        queue.async { [weak self] in
            do {
                if let emulator {
                    try emulator.stop(serial: serial, avdName: avd.name)
                }
                try provisioning.rename(oldName: avd.name, newName: newName)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.pinnedAVDs.contains(avd.name) {
                        self.setPinned(self.pinnedAVDs.subtracting([avd.name]).union([newName]))
                    }
                    self.refreshAVDs()
                    self.refreshRunning()
                }
            } catch {
                self?.reportOperationError(AppLanguage.text("operation.renameFailed", avd.name), error)
            }
        }
    }

    func moveAVD(avd: AVD, serial: String?, newPath: String) {
        guard let provisioning else { return }
        let emulator = self.emulator
        queue.async { [weak self] in
            do {
                if let emulator {
                    try emulator.stop(serial: serial, avdName: avd.name)
                }
                try provisioning.move(name: avd.name, toPath: newPath)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.refreshAVDs()
                    self.refreshRunning()
                }
            } catch {
                self?.reportOperationError(AppLanguage.text("operation.moveFailed", avd.name), error)
            }
        }
    }

    // MARK: - 截图

    func screenshot(
        device: RunningEmulator,
        avd: AVD?,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard let adb = tools?.adb else {
            completion(.failure(ToolPathError.missingTool("adb")))
            return
        }
        let files = FileManager.default
        let desktop = files.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let directory = files.fileExists(atPath: desktop.path)
            ? desktop
            : files.homeDirectoryForCurrentUser
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let baseName = (avd?.name ?? device.serial).replacingOccurrences(of: "/", with: "_")
        let output = directory.appendingPathComponent("\(baseName)-\(formatter.string(from: Date())).png")

        let environment = tools.map { ToolEnvironment.make(tools: $0) }
        queue.async {
            do {
                let result = try CommandRunner.runToFile(
                    adb,
                    ["-s", device.serial, "exec-out", "screencap", "-p"],
                    output: output,
                    environment: environment,
                    timeout: 60
                )
                guard result.status == 0 else {
                    throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
                }
                let attributes = try? FileManager.default.attributesOfItem(atPath: output.path)
                let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                guard size > 0 else {
                    throw CommandRunnerError.nonZero(status: 1, stderr: AppLanguage.text("screenshot.emptyFile"))
                }
                DispatchQueue.main.async { completion(.success(output)) }
            } catch {
                try? FileManager.default.removeItem(at: output)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// iOS 模拟器截图：与 Android 截图同款命名规则，保存到桌面（无桌面时用户目录）。
    func screenshot(
        simulator: SimulatorDevice,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard let simctl else { return }
        let files = FileManager.default
        let desktop = files.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let directory = files.fileExists(atPath: desktop.path)
            ? desktop
            : files.homeDirectoryForCurrentUser
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let baseName = simulator.name.replacingOccurrences(of: "/", with: "_")
        let output = directory.appendingPathComponent("\(baseName)-\(formatter.string(from: Date())).png")

        queue.async {
            do {
                let data = try simctl.screenshot(udid: simulator.udid)
                try data.write(to: output)
                DispatchQueue.main.async { completion(.success(output)) }
            } catch {
                try? FileManager.default.removeItem(at: output)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - 系统按键

    func sendKey(serial: String, keycode: Int) {
        guard let emulator, running.contains(where: { $0.serial == serial && $0.isBooted }) else { return }
        queue.async { [weak self] in
            do {
                try emulator.sendKey(serial: serial, keycode: keycode)
            } catch {
                self?.reportOperationError(AppLanguage.text("input.keyFailed"), error)
            }
        }
    }

    // MARK: - 真机信息

    @Published private(set) var deviceProps: [String: DeviceProps] = [:]
    private var propsInFlight: Set<String> = []

    func deviceProps(for serial: String) -> DeviceProps? {
        deviceProps[serial]
    }

    private func fetchDeviceProps(for serial: String) {
        guard deviceProps[serial] == nil,
              !propsInFlight.contains(serial),
              let monitor else { return }
        propsInFlight.insert(serial)
        queue.async { [weak self] in
            let finish: (DeviceProps?) -> Void = { props in
                DispatchQueue.main.async {
                    self?.propsInFlight.remove(serial)
                    if let props {
                        self?.deviceProps[serial] = props
                    }
                }
            }
            do {
                finish(try monitor.deviceProps(serial: serial))
            } catch {
                finish(nil)
            }
        }
    }

    // MARK: - 触摸输入

    func sendTap(serial: String, x: Int, y: Int) {
        guard let emulator, running.contains(where: { $0.serial == serial && $0.isBooted }) else { return }
        queue.async { [weak self] in
            do {
                try emulator.sendTap(serial: serial, x: x, y: y)
            } catch {
                self?.reportOperationError(AppLanguage.text("input.touchFailed"), error)
            }
        }
    }

    func sendSwipe(serial: String, x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int) {
        guard let emulator, running.contains(where: { $0.serial == serial && $0.isBooted }) else { return }
        queue.async { [weak self] in
            do {
                try emulator.sendSwipe(
                    serial: serial, x1: x1, y1: y1, x2: x2, y2: y2, durationMs: durationMs
                )
            } catch {
                self?.reportOperationError(AppLanguage.text("input.swipeFailed"), error)
            }
        }
    }

    /// 查询设备分辨率，用于预览触摸坐标映射。
    func refreshDeviceResolution(serial: String) {
        guard let emulator else { return }
        queue.async { [weak self] in
            do {
                let size = try emulator.deviceResolution(serial: serial)
                DispatchQueue.main.async {
                    guard let self, self.previewSerial == serial else { return }
                    self.deviceResolution = size
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.previewSerial == serial else { return }
                    self.deviceResolution = nil
                }
            }
        }
    }

    // MARK: - 预览轮播

    @Published var previewImage: NSImage?
    @Published var previewStatus: String?
    @Published var previewFrame: CGImage?
    @Published var deviceResolution: CGSize?
    @Published private(set) var previewPipeline: PreviewPipeline = .adbStream
    private var adbFailureCount = 0
    private var adbStreamStartedAt: Date?
    private var iosFailureCount = 0
    private var iosStreamStartedAt: Date?
    private var iosRestartWorkItem: DispatchWorkItem?
    private var previewBooted = false
    private var previewIsRealDevice = false
    private static let previewInterval: TimeInterval = 1.5
    private var previewSerial: String?
    private var previewUDID: String?
    private var previewAVDName: String?
    private var previewTimer: Timer?
    private var previewInFlight = false
    private var previewGeneration = 0
    private var firstFrameTimeout: DispatchWorkItem?
    private var previewVisible = false

    /// 主界面左侧选中项变化时更新预览目标；serial 与 udid 均为 nil 表示没有运行中的实例。
    /// Android 真机（isRealDevice）没有 SCK 窗口捕获，降级直接走截屏轮播；
    /// iOS 模拟器选中时增强档（baguette）优先，失败降级截图轮询。
    func setPreviewTarget(
        serial: String?,
        avdName: String?,
        booted: Bool,
        isRealDevice: Bool,
        simulator: SimulatorDevice? = nil
    ) {
        let udid = simulator?.udid
        if serial != previewSerial || udid != previewUDID || booted != previewBooted {
            previewGeneration += 1
            firstFrameTimeout?.cancel()
            iosRestartWorkItem?.cancel()
            adbStreamer.stop()
            baguetteStreamer.stop()
            previewSerial = serial
            previewAVDName = avdName
            previewUDID = udid
            previewBooted = booted
            previewIsRealDevice = isRealDevice
            previewImage = nil
            previewFrame = nil
            previewStatus = serial == nil && udid == nil
                ? AppLanguage.text("preview.noRunningDevice")
                : (booted
                    ? AppLanguage.text(simulator != nil ? "ios.preview.connecting" : "preview.connectingADB")
                    : AppLanguage.text("preview.waitingForFrame"))
            deviceResolution = nil
            adbFailureCount = 0
            iosFailureCount = 0
            if simulator != nil {
                setPreviewPipeline(isEnhancedTierAvailable ? .iosStream : .iosPolling)
            } else {
                // 真机无 SCK 窗口捕获；模拟器未开机时 ADB 流也不可用，
                // 两者失败后统一降级为截屏轮播，因此初始管线一律走 ADB 流。
                setPreviewPipeline(.adbStream)
            }
            if let serial {
                refreshDeviceResolution(serial: serial)
            }
            updateInputSession(udid: udid, booted: booted, isSimulator: simulator != nil)
        }
        applyPreviewPipeline()
    }

    /// 主界面打开/关闭时控制预览开关。
    func setPreviewVisible(_ visible: Bool) {
        previewVisible = visible
        if visible {
            applyPreviewPipeline()
        } else {
            previewGeneration += 1
            firstFrameTimeout?.cancel()
            iosRestartWorkItem?.cancel()
            adbStreamer.stop()
            baguetteStreamer.stop()
            baguetteInput.stop()
            previewFrame = nil
            previewImage = nil
            previewTimer?.invalidate()
            previewTimer = nil
        }
    }

    /// 停止一切预览活动（App 退出时调用）。
    func stopPreview() {
        setPreviewVisible(false)
    }

    private func setPreviewPipeline(_ pipeline: PreviewPipeline) {
        previewPipeline = pipeline
        applyPreviewPipeline()
    }

    /// 按当前管线启动对应预览源。降级链：
    /// Android adbStream → polling；iOS iosStream（baguette）→ iosPolling（simctl 截图）。
    private func applyPreviewPipeline() {
        switch previewPipeline {
        case .adbStream:
            guard previewVisible, previewBooted, let serial = previewSerial, let tools, let adb = tools.adb else {
                adbStreamer.stop()
                previewStatus = tools?.adb == nil ? AppLanguage.text("tools.adbMissing") : previewStatus
                schedulePreview()
                return
            }
            startADBStream(serial: serial, adb: adb)
        case .iosStream:
            guard previewVisible, previewBooted, let udid = previewUDID, let baguette = baguetteURL,
                  isEnhancedTierAvailable else {
                baguetteStreamer.stop()
                schedulePreview()
                return
            }
            startIOSStream(udid: udid, baguette: baguette)
        case .polling, .iosPolling:
            firstFrameTimeout?.cancel()
            adbStreamer.stop()
            baguetteStreamer.stop()
        }
        schedulePreview()
    }

    private func startADBStream(serial: String, adb: URL) {
        guard let tools else { return }
        if !adbStreamer.isRunning {
            adbStreamStartedAt = Date()
            adbStreamer.start(
                serial: serial,
                adb: adb,
                environment: ToolEnvironment.make(tools: tools)
            )
            firstFrameTimeout?.cancel()
            let generation = previewGeneration
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.previewGeneration == generation,
                      self.previewFrame == nil, self.previewPipeline == .adbStream else { return }
                self.previewStatus = AppLanguage.text("preview.fallbackToScreenshots")
                self.setPreviewPipeline(.polling)
            }
            firstFrameTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        }
    }

    private func startIOSStream(udid: String, baguette: URL) {
        if !baguetteStreamer.isRunning {
            iosStreamStartedAt = Date()
            baguetteStreamer.start(udid: udid, baguette: baguette)
            firstFrameTimeout?.cancel()
            let generation = previewGeneration
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.previewGeneration == generation,
                      self.previewFrame == nil, self.previewPipeline == .iosStream else { return }
                self.previewStatus = AppLanguage.text("preview.fallbackToScreenshots")
                self.setPreviewPipeline(.iosPolling)
            }
            firstFrameTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        }
    }

    private func handleStreamState(_ state: ADBH264Streamer.StreamState) {
        guard previewVisible, previewBooted, previewPipeline == .adbStream else { return }
        switch state {
        case .active:
            adbFailureCount = 0
            previewStatus = nil
        case .ended(let reason):
            let ran = adbStreamStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            if ran < 5 {
                adbFailureCount += 1
            } else {
                adbFailureCount = 0
            }
            previewStatus = reason
            // 快速失败连续两次，或目标是真机（无 SCK 窗口）→ 降级到截屏轮播
            if adbFailureCount >= 2 || previewIsRealDevice {
                setPreviewPipeline(.polling)
            }
        case .starting, .idle:
            break
        }
    }

    private func handleBaguetteStreamState(_ state: BaguetteController.StreamState) {
        guard previewVisible, previewBooted, previewPipeline == .iosStream else { return }
        switch state {
        case .active:
            iosFailureCount = 0
            previewStatus = nil
        case .ended(let reason):
            let ran = iosStreamStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            if ran < 5 {
                iosFailureCount += 1
            } else {
                iosFailureCount = 0
            }
            previewStatus = reason
            // 首帧失败 1 次延迟重启（与 ADB 流一致），连续两次快速失败降级到截图轮询
            if iosFailureCount >= 2 {
                setPreviewPipeline(.iosPolling)
            } else {
                iosRestartWorkItem?.cancel()
                let generation = previewGeneration
                let restart = DispatchWorkItem { [weak self] in
                    guard let self, self.previewGeneration == generation,
                          self.previewPipeline == .iosStream else { return }
                    self.applyPreviewPipeline()
                }
                iosRestartWorkItem = restart
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: restart)
            }
        case .starting, .idle:
            break
        }
    }

    private func schedulePreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        guard previewVisible,
              previewSerial != nil || previewUDID != nil,
              previewBooted,
              previewPipeline == .polling || previewPipeline == .iosPolling,
              !adbStreamer.isRunning,
              !baguetteStreamer.isRunning else { return }
        let timer = Timer(timeInterval: Self.previewInterval, repeats: false) { [weak self] _ in
            self?.capturePreviewFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    private func capturePreviewFrame() {
        guard previewVisible, !previewInFlight, previewBooted else { return }
        switch previewPipeline {
        case .polling:
            captureAndroidPreviewFrame()
        case .iosPolling:
            captureSimulatorPreviewFrame()
        case .adbStream, .iosStream:
            break
        }
    }

    private func captureAndroidPreviewFrame() {
        guard let serial = previewSerial,
              let adb = tools?.adb else { return }
        previewInFlight = true
        let generation = previewGeneration
        let environment = tools.map { ToolEnvironment.make(tools: $0) }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("avd-preview-\(serial).png")
        queue.async { [weak self] in
            let finish: (NSImage?, String?) -> Void = { image, status in
                DispatchQueue.main.async {
                    self?.previewInFlight = false
                    if self?.previewGeneration == generation {
                        self?.previewImage = image
                        self?.previewStatus = status
                    }
                    self?.schedulePreview()
                }
            }
            do {
                let result = try CommandRunner.runToFile(
                    adb,
                    ["-s", serial, "exec-out", "screencap", "-p"],
                    output: output,
                    environment: environment,
                    timeout: 10
                )
                guard result.status == 0 else {
                    throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
                }
                guard let image = NSImage(contentsOf: output) else {
                    throw CommandRunnerError.nonZero(status: 1, stderr: AppLanguage.text("preview.invalidFrame"))
                }
                finish(image, nil)
            } catch {
                finish(nil, error.localizedDescription)
            }
        }
    }

    /// iOS 轮询：`io screenshot -` 不能输出 stdout（实测约束），SimctlService 写临时文件后读回。
    private func captureSimulatorPreviewFrame() {
        guard let udid = previewUDID, let simctl else { return }
        previewInFlight = true
        let generation = previewGeneration
        queue.async { [weak self] in
            let finish: (NSImage?, String?) -> Void = { image, status in
                DispatchQueue.main.async {
                    self?.previewInFlight = false
                    if self?.previewGeneration == generation {
                        self?.previewImage = image
                        self?.previewStatus = status
                    }
                    self?.schedulePreview()
                }
            }
            do {
                let data = try simctl.screenshot(udid: udid)
                guard let image = NSImage(data: data) else {
                    throw CommandRunnerError.nonZero(status: 1, stderr: AppLanguage.text("preview.invalidFrame"))
                }
                finish(image, nil)
            } catch {
                finish(nil, error.localizedDescription)
            }
        }
    }

    // MARK: - 设置窗口测试

    func testConfiguration(_ draft: SettingsDraft, completion: @escaping (String) -> Void) {
        queue.async {
            do {
                let resolved = try ToolLocator.resolve(
                    avdmanagerOverride: draft.avdmanagerPath,
                    emulatorOverride: draft.emulatorPath,
                    adbOverride: draft.adbPath
                )
                let avds = try AVDRepository(tools: resolved).listAVDs()
                var lines = [AppLanguage.text("settings.tools.foundAVDs", String(avds.count))]
                lines.append("avdmanager: \(resolved.avdmanager.path)")
                lines.append("emulator: \(resolved.emulator?.path ?? AppLanguage.text("settings.tools.notFound"))")
                lines.append("adb: \(resolved.adb?.path ?? AppLanguage.text("settings.tools.notFound"))")
                lines.append("JAVA_HOME: \(resolved.javaHome?.path ?? AppLanguage.text("settings.tools.javaMissing"))")
                if !avds.isEmpty {
                    lines.append("AVD: " + avds.map(\.name).joined(separator: ", "))
                }
                let message = lines.joined(separator: "\n")
                DispatchQueue.main.async { completion(message) }
            } catch {
                let message = "✗ \(error.localizedDescription)"
                DispatchQueue.main.async { completion(message) }
            }
        }
    }

    private func runningAVDName(forSerial serial: String?) -> String? {
        guard let serial else { return nil }
        return running.first { $0.serial == serial }?.avdName
    }

    private func reportOperationError(_ title: String, _ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(title, error.localizedDescription)
        }
    }
}
