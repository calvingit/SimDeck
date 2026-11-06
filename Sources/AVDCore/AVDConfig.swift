import Foundation

/// 从 AVD 的 config.ini / <name>.ini 中补充 avdmanager 文本里没有的 API level。
public enum AVDConfig {
    /// 读取 `target=android-34` 或 `image.sysdir.1=system-images;android-34;...`。
    public static func apiLevel(fromINI text: String) -> Int? {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("target=android-") || line.hasPrefix("image.sysdir.1=") else {
                continue
            }
            if let range = line.range(of: "android-") {
                let digits = line[range.upperBound...].prefix(while: { $0.isNumber })
                if let level = Int(digits) { return level }
            }
        }
        return nil
    }

    public static func apiLevel(configINIPath: String) -> Int? {
        guard let text = try? String(contentsOfFile: configINIPath, encoding: .utf8) else {
            return nil
        }
        return apiLevel(fromINI: text)
    }
}
