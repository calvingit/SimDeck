import Foundation

public enum ToolPathError: LocalizedError, Equatable {
    case avdmanagerNotFound
    case invalidOverride(tool: String, path: String)
    case missingTool(String)

    public var errorDescription: String? {
        switch self {
        case .avdmanagerNotFound:
            return AppLanguage.text("tools.avdmanagerMissing")
        case .invalidOverride(let tool, let path):
            return AppLanguage.text("tools.invalidPath", tool, path)
        case .missingTool(let tool):
            return AppLanguage.text("tools.toolMissing", tool)
        }
    }
}

public struct ToolPaths: Equatable, Sendable {
    public let avdmanager: URL
    public let emulator: URL?
    public let adb: URL?
    public let sdkRoot: URL?
    public let javaHome: URL?

    public init(
        avdmanager: URL,
        emulator: URL?,
        adb: URL?,
        sdkRoot: URL?,
        javaHome: URL?
    ) {
        self.avdmanager = avdmanager
        self.emulator = emulator
        self.adb = adb
        self.sdkRoot = sdkRoot
        self.javaHome = javaHome
    }
}

public enum ToolLocator {
    /// 解析 avdmanager / emulator / adb / Java 路径。
    /// 显式覆盖无效时直接报错，不做静默回退。
    public static func resolve(
        avdmanagerOverride: String? = nil,
        emulatorOverride: String? = nil,
        adbOverride: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ToolPaths {
        let files = FileManager.default

        let avdmanagerURL: URL
        if let override = normalized(avdmanagerOverride) {
            guard isExecutable(override, files: files) else {
                throw ToolPathError.invalidOverride(tool: "avdmanager", path: override)
            }
            avdmanagerURL = URL(fileURLWithPath: override)
        } else {
            guard let found = autoAVDManagerCandidates(environment: environment, files: files)
                .first(where: { isExecutable($0, files: files) }) else {
                throw ToolPathError.avdmanagerNotFound
            }
            avdmanagerURL = URL(fileURLWithPath: found)
        }

        var sdkRoot = deriveSDKRoot(from: avdmanagerURL, files: files)
        if sdkRoot == nil {
            sdkRoot = environmentSDKRoot(environment: environment, files: files)
        }

        let emulatorURL: URL?
        if let override = normalized(emulatorOverride) {
            guard isExecutable(override, files: files) else {
                throw ToolPathError.invalidOverride(tool: "emulator", path: override)
            }
            emulatorURL = URL(fileURLWithPath: override)
        } else {
            emulatorURL = sdkRoot.flatMap { sdk in
                let candidate = sdk.appendingPathComponent("emulator/emulator").path
                return isExecutable(candidate, files: files) ? URL(fileURLWithPath: candidate) : nil
            }
        }

        let adbURL: URL?
        if let override = normalized(adbOverride) {
            guard isExecutable(override, files: files) else {
                throw ToolPathError.invalidOverride(tool: "adb", path: override)
            }
            adbURL = URL(fileURLWithPath: override)
        } else {
            adbURL = sdkRoot.flatMap { sdk in
                let candidate = sdk.appendingPathComponent("platform-tools/adb").path
                return isExecutable(candidate, files: files) ? URL(fileURLWithPath: candidate) : nil
            }
        }

        return ToolPaths(
            avdmanager: avdmanagerURL,
            emulator: emulatorURL,
            adb: adbURL,
            sdkRoot: sdkRoot,
            javaHome: resolveJavaHome(environment: environment, files: files)
        )
    }

    // MARK: - 内部步骤

    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    static func isExecutable(_ path: String, files: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return files.isExecutableFile(atPath: path)
    }

    static func autoAVDManagerCandidates(
        environment: [String: String],
        files: FileManager
    ) -> [String] {
        var candidates: [String] = []

        func addSDKRoot(_ rawRoot: String) {
            let root = (rawRoot as NSString).expandingTildeInPath
            let cmdlineTools = URL(fileURLWithPath: root).appendingPathComponent("cmdline-tools")
            candidates.append(cmdlineTools.appendingPathComponent("latest/bin/avdmanager").path)

            // latest 不存在时，退而扫描具体版本目录。
            if let versions = try? files.contentsOfDirectory(atPath: cmdlineTools.path) {
                for version in versions.sorted(by: >) where version != "latest" {
                    candidates.append(
                        cmdlineTools.appendingPathComponent("\(version)/bin/avdmanager").path
                    )
                }
            }
        }

        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let value = environment[key], !value.isEmpty {
                addSDKRoot(value)
            }
        }
        addSDKRoot("~/Library/Android/sdk")

        // PATH 中的条目可能直接指向 cmdline-tools/latest/bin。
        let pathDirs = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        for directory in pathDirs {
            candidates.append(
                URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
                    .appendingPathComponent("avdmanager").path
            )
        }

        addSDKRoot("/opt/homebrew/share/android-commandlinetools")
        addSDKRoot("/usr/local/share/android-commandlinetools")
        return candidates
    }

    static func environmentSDKRoot(
        environment: [String: String],
        files: FileManager
    ) -> URL? {
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            guard let value = environment[key], !value.isEmpty else { continue }
            let path = (value as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if files.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// 从 `<sdk>/cmdline-tools/<ver>/bin/avdmanager` 向上找到包含 emulator 或 platform-tools 的目录。
    static func deriveSDKRoot(from avdmanager: URL, files: FileManager) -> URL? {
        // 支持 PATH 中的 avdmanager 是符号链接的情况。
        var directory = avdmanager.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            let emulator = directory.appendingPathComponent("emulator/emulator").path
            let adb = directory.appendingPathComponent("platform-tools/adb").path
            if files.fileExists(atPath: emulator) || files.fileExists(atPath: adb) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    static func resolveJavaHome(
        environment: [String: String],
        files: FileManager
    ) -> URL? {
        var candidates: [String] = []

        if let javaHome = environment["JAVA_HOME"], !javaHome.isEmpty {
            candidates.append((javaHome as NSString).expandingTildeInPath)
        }

        if let result = try? CommandRunner.run(
            URL(fileURLWithPath: "/usr/libexec/java_home"),
            [],
            timeout: 10
        ), result.status == 0 {
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { candidates.append(path) }
        }

        candidates.append("/Applications/Android Studio.app/Contents/jbr/Contents/Home")
        candidates.append(contentsOf: javaVirtualMachineHomes(files: files))

        var firstUsable: URL?
        for path in candidates where isExecutable(path + "/bin/java", files: files) {
            let url = URL(fileURLWithPath: path)
            if firstUsable == nil { firstUsable = url }
            // avdmanager 需要 JDK 17+；跳过旧 JDK，避免默认 java_home 指向 Java 8 时直接失败。
            if let major = javaMajorVersion(home: path), major >= 17 {
                return url
            }
        }
        return firstUsable
    }

    private static func javaMajorVersion(home: String) -> Int? {
        let java = home + "/bin/java"
        guard let result = try? CommandRunner.run(
            URL(fileURLWithPath: java),
            ["-version"],
            timeout: 10
        ) else {
            return nil
        }
        let text = result.stderr + "\n" + result.stdout
        guard let range = text.range(
            of: #"version "([0-9]+)"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let digits = String(text[range]).filter(\.isNumber)
        guard let major = Int(digits) else { return nil }
        // `1.8.0_xxx` 的版本号第一位是 1。
        return major == 1 ? 8 : major
    }

    private static func javaVirtualMachineHomes(files: FileManager) -> [String] {
        let root = "/Library/Java/JavaVirtualMachines"
        guard let entries = try? files.contentsOfDirectory(atPath: root) else { return [] }
        return entries.sorted(by: >).map { "\(root)/\($0)/Contents/Home" }
    }
}

/// 统一构造命令行工具的环境变量，保证 GUI 启动时也能找到 SDK/Java。
public enum ToolEnvironment {
    public static func make(
        tools: ToolPaths,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        var pathParts: [String] = []

        if let sdkRoot = tools.sdkRoot {
            environment["ANDROID_HOME"] = sdkRoot.path
            environment["ANDROID_SDK_ROOT"] = sdkRoot.path
            pathParts.append(sdkRoot.appendingPathComponent("platform-tools").path)
            pathParts.append(sdkRoot.appendingPathComponent("emulator").path)
            pathParts.append(sdkRoot.appendingPathComponent("cmdline-tools/latest/bin").path)
            pathParts.append(sdkRoot.appendingPathComponent("tools/bin").path)
        }
        if let javaHome = tools.javaHome {
            environment["JAVA_HOME"] = javaHome.path
            pathParts.append(javaHome.appendingPathComponent("bin").path)
        }

        let baseDirs = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        let fallbackDirs = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = (pathParts + (baseDirs.isEmpty ? fallbackDirs : baseDirs))
            .joined(separator: ":")
        return environment
    }
}
