import Foundation

/// 轮询 iOS 模拟器状态；角色对应 Android 侧的 DeviceMonitor，刷新节奏由 AppModel 控制。
/// 状态查询都委托给 SimctlService，生命周期动作不经这里。
public final class SimulatorMonitor: @unchecked Sendable {
    private let simctl: SimctlService

    public init(simctl: SimctlService) {
        self.simctl = simctl
    }

    /// 当前全部 iOS 模拟器（含不可用设备）及其状态。
    public func devices() throws -> [SimulatorDevice] {
        try simctl.listDevices()
    }

    /// 创建模拟器时的候选 runtime，仅 iOS，按版本降序。
    public func iosRuntimes() throws -> [SimulatorRuntime] {
        try simctl.listRuntimes().filter(\.isIOS)
    }

    /// 创建模拟器时的候选机型，按名称升序。
    public func deviceTypes() throws -> [SimulatorDeviceType] {
        try simctl.listDeviceTypes()
    }
}
