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
    /// 该 runtime 声明支持的机型；老版本 simctl 不输出此字段时为空数组。
    public let supportedDeviceTypes: [SimulatorDeviceType]

    public var id: String { identifier }
    public var isIOS: Bool { identifier.hasPrefix(Self.iosPrefix) }

    public init(
        identifier: String,
        version: String,
        buildVersion: String?,
        isAvailable: Bool,
        supportedDeviceTypes: [SimulatorDeviceType] = []
    ) {
        self.identifier = identifier
        self.version = version
        self.buildVersion = buildVersion
        self.isAvailable = isAvailable
        self.supportedDeviceTypes = supportedDeviceTypes
    }

    /// 创建向导的机型过滤：优先取该 runtime 声明的 supportedDeviceTypes 与候选求交；
    /// runtime 未声明（空数组，老版本 simctl）时回退全部候选。
    public func filterDeviceTypes(_ candidates: [SimulatorDeviceType]) -> [SimulatorDeviceType] {
        guard !supportedDeviceTypes.isEmpty else { return candidates }
        let supported = Set(supportedDeviceTypes.map(\.identifier))
        return candidates.filter { supported.contains($0.identifier) }
    }
}

/// `simctl listapps <udid>` 输出中的一条已安装应用。
public struct SimulatorApp: Identifiable, Equatable, Sendable {
    public let bundleID: String
    public let name: String
    public let version: String?

    public var id: String { bundleID }

    public init(bundleID: String, name: String, version: String?) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
    }
}

/// baguette `button` press 的目标键；rawValue 即 wire 协议的 `button` 字段值（baguette v0.2.13）。
public enum IOSKey: String, Encodable, Sendable {
    case home
    case lock
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"
}

/// baguette input JSON-lines 协议的手势（`baguette input --udid <udid>`，逐行 JSON、逐行 ack）。
/// 坐标一律 device points（来自 describe-ui 的 `screen` 字段，不是像素）；位置类手势必带
/// width/height；duration 单位为秒。`key` 映射为 baguette 的 `button` press。
public enum IOSGesture: Encodable, Sendable {
    case tap(x: Int, y: Int, width: Int, height: Int, duration: Double)
    case swipe(startX: Int, startY: Int, endX: Int, endY: Int,
               width: Int, height: Int, duration: Double)
    /// startSpread/endSpread 为双指间距（points）；不编码 duration，服务端按默认值插值。
    case pinch(cx: Int, cy: Int, startSpread: Int, endSpread: Int,
               width: Int, height: Int)
    case key(IOSKey)
    case text(String)

    private enum GestureCodingKeys: String, CodingKey {
        case type, x, y, startX, startY, endX, endY
        case cx, cy, startSpread, endSpread
        case width, height, duration, button, text
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: GestureCodingKeys.self)
        switch self {
        case .tap(let x, let y, let width, let height, let duration):
            try container.encode("tap", forKey: .type)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
            try container.encode(duration, forKey: .duration)
        case .swipe(let startX, let startY, let endX, let endY,
                    let width, let height, let duration):
            try container.encode("swipe", forKey: .type)
            try container.encode(startX, forKey: .startX)
            try container.encode(startY, forKey: .startY)
            try container.encode(endX, forKey: .endX)
            try container.encode(endY, forKey: .endY)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
            try container.encode(duration, forKey: .duration)
        case .pinch(let cx, let cy, let startSpread, let endSpread,
                    let width, let height):
            try container.encode("pinch", forKey: .type)
            try container.encode(cx, forKey: .cx)
            try container.encode(cy, forKey: .cy)
            try container.encode(startSpread, forKey: .startSpread)
            try container.encode(endSpread, forKey: .endSpread)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
        case .key(let key):
            try container.encode("button", forKey: .type)
            try container.encode(key, forKey: .button)
            try container.encode(0.0, forKey: .duration)
        case .text(let text):
            try container.encode("type", forKey: .type)
            try container.encode(text, forKey: .text)
        }
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
