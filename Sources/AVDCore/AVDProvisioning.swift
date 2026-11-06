import Foundation

public struct SystemImage: Identifiable, Hashable, Sendable {
    public let id: String
    public let apiLevel: Int
    public let tag: String
    public let abi: String

    public init(id: String, apiLevel: Int, tag: String, abi: String) {
        self.id = id
        self.apiLevel = apiLevel
        self.tag = tag
        self.abi = abi
    }

    public var display: String {
        "API \(apiLevel) · \(shortTag) · \(abi)"
    }

    private var shortTag: String {
        switch tag {
        case "google_apis_playstore_ps16k":
            return "Google Play 16KB"
        case "google_apis_playstore":
            return "Google Play"
        case "google_apis":
            return "Google APIs"
        case "default":
            return "AOSP"
        default:
            return tag
        }
    }
}

public enum ProvisioningError: LocalizedError, Equatable {
    case sdkMissing
    case noSystemImages
    case invalidName(String)
    case nameExists(String)
    case createFailed(String)
    case renameFailed(String)
    case moveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sdkMissing:
            return AppLanguage.text("provision.sdkMissing")
        case .noSystemImages:
            return AppLanguage.text("provision.imagesMissing")
        case .invalidName(let name):
            return AppLanguage.text("provision.invalidName", name)
        case .nameExists(let name):
            return AppLanguage.text("provision.alreadyExists", name)
        case .createFailed(let detail):
            return AppLanguage.text("provision.createFailed", detail)
        case .renameFailed(let detail):
            return AppLanguage.text("provision.renameFailed", detail)
        case .moveFailed(let detail):
            return AppLanguage.text("provision.moveFailed", detail)
        }
    }
}

public final class AVDProvisioningService: @unchecked Sendable {
    public let tools: ToolPaths

    public init(tools: ToolPaths) {
        self.tools = tools
    }

    public func systemImages() -> [SystemImage] {
        guard let sdkRoot = tools.sdkRoot else { return [] }
        let root = sdkRoot.appendingPathComponent("system-images")
        guard let apiDirectories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let knownABIs: Set<String> = ["arm64-v8a", "x86_64", "armeabi-v7a", "x86"]
        var images: [SystemImage] = []

        for apiDirectory in apiDirectories {
            let apiName = apiDirectory.lastPathComponent
            guard let apiLevel = apiLevel(fromDirectory: apiName) else { continue }
            let apiPath = apiDirectory.path
            guard let tags = try? FileManager.default.contentsOfDirectory(atPath: apiPath) else {
                continue
            }
            for tag in tags.sorted() {
                let tagPath = "\(apiPath)/\(tag)"
                guard let abis = try? FileManager.default.contentsOfDirectory(atPath: tagPath) else {
                    continue
                }
                for abi in abis.sorted() where knownABIs.contains(abi) {
                    let imagePath = "\(tagPath)/\(abi)"
                    let hasContent = ["system.img", "ramdisk.img", "package.xml"].contains {
                        FileManager.default.fileExists(atPath: "\(imagePath)/\($0)")
                    }
                    guard hasContent else { continue }
                    images.append(SystemImage(
                        id: "system-images;\(apiName);\(tag);\(abi)",
                        apiLevel: apiLevel,
                        tag: tag,
                        abi: abi
                    ))
                }
            }
        }

        return images.sorted {
            if $0.apiLevel != $1.apiLevel { return $0.apiLevel > $1.apiLevel }
            if $0.tag != $1.tag { return $0.tag < $1.tag }
            return $0.abi < $1.abi
        }
    }

    public func deviceProfiles() throws -> [String] {
        let result = try CommandRunner.run(
            tools.avdmanager,
            ["list", "device", "-c"],
            environment: ToolEnvironment.make(tools: tools),
            timeout: 60
        )
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }
        return result.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    public func create(name: String, imageID: String, device: String) throws {
        try validate(name: name)
        guard !avdExists(name) else {
            throw ProvisioningError.nameExists(name)
        }
        let result = try CommandRunner.run(
            tools.avdmanager,
            ["create", "avd", "-n", name, "-k", imageID, "-d", device],
            environment: ToolEnvironment.make(tools: tools),
            input: "no\n",
            timeout: 180
        )
        guard result.status == 0 else {
            throw ProvisioningError.createFailed(result.failureDetail)
        }
    }

    public func rename(oldName: String, newName: String) throws {
        try validate(name: newName)
        guard !avdExists(newName) else {
            throw ProvisioningError.nameExists(newName)
        }
        let result = try CommandRunner.run(
            tools.avdmanager,
            ["move", "avd", "-n", oldName, "-r", newName],
            environment: ToolEnvironment.make(tools: tools),
            timeout: 60
        )
        guard result.status == 0 else {
            throw ProvisioningError.renameFailed(result.failureDetail)
        }
    }

    public func move(name: String, toPath: String) throws {
        guard !toPath.isEmpty else {
            throw ProvisioningError.moveFailed(AppLanguage.text("provision.emptyDestination"))
        }
        let result = try CommandRunner.run(
            tools.avdmanager,
            ["move", "avd", "-n", name, "-p", toPath],
            environment: ToolEnvironment.make(tools: tools),
            timeout: 120
        )
        guard result.status == 0 else {
            throw ProvisioningError.moveFailed(result.failureDetail)
        }
    }

    private func validate(name: String) throws {
        guard !name.isEmpty,
              name.count <= 64,
              name != ".", name != "..",
              name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw ProvisioningError.invalidName(name)
        }
    }

    private func avdExists(_ name: String) -> Bool {
        let files = FileManager.default
        return files.fileExists(atPath: avdHome.appendingPathComponent("\(name).ini").path)
            || files.fileExists(atPath: avdHome.appendingPathComponent("\(name).avd").path)
    }

    private var avdHome: URL {
        if let custom = ProcessInfo.processInfo.environment["ANDROID_AVD_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".android/avd")
    }

    private func apiLevel(fromDirectory name: String) -> Int? {
        guard let range = name.range(of: #"^android-([0-9]+)"#, options: .regularExpression) else {
            return nil
        }
        let digits = String(name[range]).filter(\.isNumber)
        return Int(digits)
    }
}
