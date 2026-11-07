import Foundation

/// 一个 AVD 的元数据，数据来自 `avdmanager list avd`，API level 由 config.ini 补充。
public struct AVD: Identifiable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let deviceName: String?
    public let deviceManufacturer: String?
    public let target: String?
    public let androidVersion: String?
    public let codename: String?
    public let abi: String?
    public let tag: String?
    public let skin: String?
    public let sdcard: String?
    public var apiLevel: Int?

    public var id: String { name }

    public init(
        name: String,
        path: String,
        deviceName: String? = nil,
        deviceManufacturer: String? = nil,
        target: String? = nil,
        androidVersion: String? = nil,
        codename: String? = nil,
        abi: String? = nil,
        tag: String? = nil,
        skin: String? = nil,
        sdcard: String? = nil,
        apiLevel: Int? = nil
    ) {
        self.name = name
        self.path = path
        self.deviceName = deviceName
        self.deviceManufacturer = deviceManufacturer
        self.target = target
        self.androidVersion = androidVersion
        self.codename = codename
        self.abi = abi
        self.tag = tag
        self.skin = skin
        self.sdcard = sdcard
        self.apiLevel = apiLevel
    }

    /// 菜单标题用的摘要：Android 14 (API 34) · arm64-v8a · pixel_7a
    public var summary: String {
        var parts: [String] = []
        if let androidVersion {
            if let apiLevel {
                parts.append("Android \(androidVersion) (API \(apiLevel))")
            } else {
                parts.append("Android \(androidVersion)")
            }
        } else if let apiLevel {
            parts.append("API \(apiLevel)")
        }
        if let abi { parts.append(abi) }
        if let deviceName { parts.append(deviceName) }
        return parts.joined(separator: " · ")
    }
}

/// 正在运行的模拟器或真机。
public struct RunningEmulator: Identifiable, Equatable, Sendable {
    public let serial: String
    public let avdName: String?
    public let isBooted: Bool
    /// true = USB/网络连接的真机（无 AVD 记录）
    public let isRealDevice: Bool

    public var id: String { serial }
    public var displayName: String { avdName ?? serial }

    public init(
        serial: String,
        avdName: String?,
        isBooted: Bool,
        isRealDevice: Bool = false
    ) {
        self.serial = serial
        self.avdName = avdName
        self.isBooted = isBooted
        self.isRealDevice = isRealDevice
    }
}

/// 真机基础信息（getprop）。
public struct DeviceProps: Equatable, Sendable {
    public let model: String
    public let androidVersion: String
    public let apiLevel: Int

    public init(model: String, androidVersion: String, apiLevel: Int) {
        self.model = model
        self.androidVersion = androidVersion
        self.apiLevel = apiLevel
    }
}

/// `adb devices` 的一行输出。
public struct ADBDevice: Equatable, Sendable {
    public let serial: String
    public let state: String

    public init(serial: String, state: String) {
        self.serial = serial
        self.state = state
    }

    public var isEmulator: Bool { serial.hasPrefix("emulator-") }
}
