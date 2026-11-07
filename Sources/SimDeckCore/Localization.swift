import Foundation

public enum AppLanguage: String {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public static let defaultsKey = "appLanguage"

    private static let active: AppLanguage = {
        let preference = UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
        guard preference == .system else { return preference }
        let primaryLanguage = Locale.preferredLanguages.first ?? "zh-Hans"
        return Locale(identifier: primaryLanguage).language.languageCode?.identifier == "zh"
            ? .simplifiedChinese : .english
    }()

    private static let stringsBundle: Bundle = {
        let url = Bundle.module.bundleURL
        guard let resources = Bundle.module.resourceURL else {
            preconditionFailure("Missing localization resource directory in \(url.path)")
        }
        let languageURL = resources
            .appendingPathComponent("Localization")
            .appendingPathComponent(active.rawValue + ".lproj")
        guard let bundle = Bundle(url: languageURL) else {
            preconditionFailure("Missing localization resources: \(active.rawValue)")
        }
        return bundle
    }()

    public static func text(_ key: String, _ arguments: String...) -> String {
        let format = stringsBundle.localizedString(forKey: key, value: nil, table: nil)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: active.rawValue), arguments: arguments)
    }
}
