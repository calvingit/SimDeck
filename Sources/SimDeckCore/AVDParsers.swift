import Foundation

/// 解析 `avdmanager list avd` 的文本输出。
///
/// 输出形如：
/// ```
/// Available Android Virtual Devices:
///     Name: Pixel_7a
///   Device: pixel_7a (Google)
///     Path: /Users/me/.android/avd/Pixel_7a.avd
///   Target: Google Play (Google Inc.)
///           Based on: Android 14.0 ("UpsideDownCake") Tag/ABI: google_apis_playstore/arm64-v8a
///     Skin: pixel_7a
///   Sdcard: 4G
/// ---------
/// ```
public enum AVDListParser {
    public static func parse(_ output: String) -> [AVD] {
        var result: [AVD] = []

        var name: String?
        var path: String?
        var deviceName: String?
        var manufacturer: String?
        var target: String?
        var version: String?
        var codename: String?
        var abi: String?
        var tag: String?
        var skin: String?
        var sdcard: String?

        func reset() {
            name = nil
            path = nil
            deviceName = nil
            manufacturer = nil
            target = nil
            version = nil
            codename = nil
            abi = nil
            tag = nil
            skin = nil
            sdcard = nil
        }

        func finish() {
            guard let name, let path else { return }
            result.append(
                AVD(
                    name: name,
                    path: path,
                    deviceName: deviceName,
                    deviceManufacturer: manufacturer,
                    target: target,
                    androidVersion: version,
                    codename: codename,
                    abi: abi,
                    tag: tag,
                    skin: skin,
                    sdcard: sdcard
                )
            )
        }

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("Name:") {
                finish()
                reset()
                name = value(after: "Name:", in: line)
                continue
            }

            guard name != nil else { continue }

            if line.hasPrefix("Device:") {
                let raw = value(after: "Device:", in: line)
                if let paren = raw.range(of: " (") {
                    deviceName = String(raw[..<paren.lowerBound])
                    var rest = String(raw[paren.upperBound...])
                    if rest.hasSuffix(")") { rest.removeLast() }
                    manufacturer = rest
                } else {
                    deviceName = raw
                }
            } else if line.hasPrefix("Path:") {
                path = value(after: "Path:", in: line)
            } else if line.hasPrefix("Target:") {
                target = value(after: "Target:", in: line)
            } else if line.hasPrefix("Based on:") {
                let parsed = parseBasedOn(value(after: "Based on:", in: line))
                version = parsed.version
                codename = parsed.codename
                abi = parsed.abi
                if tag == nil { tag = parsed.tag }
            } else if line.hasPrefix("Tag/ABI:") {
                let parsed = parseBasedOn(line)
                if version == nil { version = parsed.version }
                if codename == nil { codename = parsed.codename }
                if abi == nil { abi = parsed.abi }
                if tag == nil { tag = parsed.tag }
            } else if line.hasPrefix("Tag:") {
                tag = value(after: "Tag:", in: line)
            } else if line.hasPrefix("Skin:") {
                skin = value(after: "Skin:", in: line)
            } else if line.hasPrefix("Sdcard:") {
                sdcard = value(after: "Sdcard:", in: line)
            }
        }

        finish()
        return result
    }

    private static func value(after prefix: String, in line: String) -> String {
        String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// 解析 `Android 14.0 ("UpsideDownCake") Tag/ABI: google_apis_playstore/arm64-v8a`
    /// 也接受单独的 `Tag/ABI: ...`。
    private static func parseBasedOn(_ raw: String) -> (version: String?, codename: String?, tag: String?, abi: String?) {
        var rest = raw.trimmingCharacters(in: .whitespaces)
        var version: String?
        var codename: String?
        var tag: String?
        var abi: String?

        if rest.hasPrefix("Android ") {
            rest = String(rest.dropFirst("Android ".count))
            if let space = rest.firstIndex(of: " ") {
                version = String(rest[..<space])
                rest = String(rest[space...]).trimmingCharacters(in: .whitespaces)
            } else {
                version = rest
                rest = ""
            }
        }

        if rest.hasPrefix("(\""), let closing = rest.range(of: "\")") {
            let start = rest.index(rest.startIndex, offsetBy: 2)
            codename = String(rest[start..<closing.lowerBound])
            rest = String(rest[closing.upperBound...]).trimmingCharacters(in: .whitespaces)
        }

        if rest.hasPrefix("Tag/ABI:") {
            let value = String(rest.dropFirst("Tag/ABI:".count)).trimmingCharacters(in: .whitespaces)
            if let slash = value.firstIndex(of: "/") {
                tag = String(value[..<slash])
                abi = String(value[value.index(after: slash)...])
            } else {
                abi = value
            }
        }

        return (version, codename, tag, abi)
    }
}

/// 解析 `adb devices -l` 的文本输出。
public enum ADBDevicesParser {
    private static let knownStates: Set<String> = [
        "device", "offline", "unauthorized", "recovery", "sideload", "bootloader"
    ]

    public static func parse(_ output: String) -> [ADBDevice] {
        var devices: [ADBDevice] = []
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("List of devices") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2, knownStates.contains(parts[1]) else { continue }
            devices.append(ADBDevice(serial: parts[0], state: parts[1]))
        }
        return devices
    }
}
