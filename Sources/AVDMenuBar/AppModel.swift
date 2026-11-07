import AppKit
import Combine
import Foundation
import AVDCore

enum PreviewPipeline: Equatable {
    case adbStream
    case polling
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

    static let avdmanagerKey = "avdmanagerPathOverride"
    static let emulatorKey = "emulatorPathOverride"
    static let adbKey = "adbPathOverride"

    static func load() -> SettingsDraft {
        let defaults = UserDefaults.standard
        return SettingsDraft(
            avdmanagerPath: defaults.string(forKey: avdmanagerKey) ?? "",
            emulatorPath: defaults.string(forKey: emulatorKey) ?? "",
            adbPath: defaults.string(forKey: adbKey) ?? ""
        )
    }

    func persist() {
        let defaults = UserDefaults.standard
        defaults.set(avdmanagerPath, forKey: Self.avdmanagerKey)
        defaults.set(emulatorPath, forKey: Self.emulatorKey)
        defaults.set(adbPath, forKey: Self.adbKey)
    }
}

/// 应用状态与所有命令调度。重活都在串行后台队列执行，状态只在主线程更新。
final class AppModel: ObservableObject {
    private let queue = DispatchQueue(label: "local.avdmenubar.commands")

    private(set) var tools: ToolPaths?
    private var repository: AVDRepository?
    private var emulator: EmulatorController?
    private var monitor: DeviceMonitor?
    private var snapshots: SnapshotService?
    private var provisioning: AVDProvisioningService?
    private var simctl: SimctlService?
    private var simulatorMonitor: SimulatorMonitor?
    let adbStreamer = ADBH264Streamer()

    @Published private(set) var avds: [AVD] = []
    @Published private(set) var running: [RunningEmulator] = []
    @Published private(set) var listError: String?
    @Published private(set) var runtimeError: String?
    @Published private(set) var busyAVDs: Set<String> = []
    @Published private(set) var pinnedAVDs: Set<String> = []
    @Published private(set) var simulators: [SimulatorDevice] = []
    @Published private(set) var busySimulators: Set<String> = []
    @Published private(set) var iosError: String?

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
        simulatorMonitor = SimulatorMonitor(simctl: service)
    }

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
            .appendingPathComponent("Library/Logs/AVDMenuBar", isDirectory: true)
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
    private var previewBooted = false
    private var previewIsRealDevice = false
    private static let previewInterval: TimeInterval = 1.5
    private var previewSerial: String?
    private var previewAVDName: String?
    private var previewTimer: Timer?
    private var previewInFlight = false
    private var previewGeneration = 0
    private var firstFrameTimeout: DispatchWorkItem?
    private var previewVisible = false

    /// 主界面左侧选中项变化时更新预览目标；serial 为 nil 表示没有运行中的实例。
    /// 真机（isRealDevice）没有 SCK 窗口捕获，降级直接走截屏轮播。
    func setPreviewTarget(serial: String?, avdName: String?, booted: Bool, isRealDevice: Bool) {
        if serial != previewSerial || booted != previewBooted {
            previewGeneration += 1
            firstFrameTimeout?.cancel()
            adbStreamer.stop()
            previewSerial = serial
            previewAVDName = avdName
            previewBooted = booted
            previewIsRealDevice = isRealDevice
            previewImage = nil
            previewFrame = nil
            previewStatus = serial == nil
                ? AppLanguage.text("preview.noRunningDevice")
                : (booted ? AppLanguage.text("preview.connectingADB") : AppLanguage.text("preview.waitingForFrame"))
            deviceResolution = nil
            adbFailureCount = 0
            // 真机无 SCK 窗口捕获；模拟器未开机时 ADB 流也不可用，
            // 两者失败后统一降级为截屏轮播，因此初始管线一律走 ADB 流。
            setPreviewPipeline(.adbStream)
            if let serial {
                refreshDeviceResolution(serial: serial)
            }
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
            adbStreamer.stop()
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

    /// 按当前管线启动对应预览源；ADB 实时流失败次数过多时降级链：
    /// adbStream → sck → polling。
    private func applyPreviewPipeline() {
        guard previewVisible, previewBooted, let serial = previewSerial, let tools, let adb = tools.adb else {
            adbStreamer.stop()
            previewStatus = tools?.adb == nil ? AppLanguage.text("tools.adbMissing") : previewStatus
            schedulePreview()
            return
        }
        switch previewPipeline {
        case .adbStream:
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
        case .polling:
            firstFrameTimeout?.cancel()
            adbStreamer.stop()
        }
        schedulePreview()
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

    private func schedulePreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        guard previewVisible,
              previewSerial != nil, previewBooted,
              previewPipeline == .polling,
              !adbStreamer.isRunning else { return }
        let timer = Timer(timeInterval: Self.previewInterval, repeats: false) { [weak self] _ in
            self?.capturePreviewFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    private func capturePreviewFrame() {
        guard previewVisible, !previewInFlight,
              let serial = previewSerial,
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
