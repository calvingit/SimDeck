import Foundation

/// `simctl list -j devices` 中的一台 iOS 模拟器。
public struct SimulatorDevice: Identifiable, Equatable, Sendable {
    public let udid: String
    public let name: String
    /// CoreSimulator 的原始状态；未知值原样保留，由 UI 展示。
    public let state: String
    /// false 表示 runtime 未安装或设备不可用。
    public let isAvailable: Bool
    /// 从 runtime 分组键解析的版本，如 "18.6" / "27.0"。
    public let runtimeVersion: String
    /// 机型显示名（如 "iPhone 17 Pro"）；解析不到时回退为类型标识符。
    public let deviceTypeName: String
    public let dataPath: String?

    public var id: String { udid }
    public var isBooted: Bool { state == "Booted" }

    public init(
        udid: String,
        name: String,
        state: String,
        isAvailable: Bool,
        runtimeVersion: String,
        deviceTypeName: String,
        dataPath: String?
    ) {
        self.udid = udid
        self.name = name
        self.state = state
        self.isAvailable = isAvailable
        self.runtimeVersion = runtimeVersion
        self.deviceTypeName = deviceTypeName
        self.dataPath = dataPath
    }
}

/// `simctl list -j runtimes` 中的一条模拟器 runtime。
public struct SimulatorRuntime: Identifiable, Equatable, Sendable {
    public static let iosPrefix = "com.apple.CoreSimulator.SimRuntime.iOS-"

    public let identifier: String
    public let version: String
    public let buildVersion: String?
    public let isAvailable: Bool

    public var id: String { identifier }
    public var isIOS: Bool { identifier.hasPrefix(Self.iosPrefix) }

    public init(identifier: String, version: String, buildVersion: String?, isAvailable: Bool) {
        self.identifier = identifier
        self.version = version
        self.buildVersion = buildVersion
        self.isAvailable = isAvailable
    }
}

/// `simctl list -j devicetypes` 中的一条机型定义。
public struct SimulatorDeviceType: Identifiable, Equatable, Sendable {
    public let identifier: String
    public let name: String
    public let productFamily: String?

    public var id: String { identifier }

    public init(identifier: String, name: String, productFamily: String?) {
        self.identifier = identifier
        self.name = name
        self.productFamily = productFamily
    }
}
