import Foundation

public enum SnapshotError: LocalizedError, Equatable {
    case invalidName(String)
    case notFound(String)
    case deleteFailed(String)
    case consoleFailed(String)
    case serialMismatch(serial: String, avdName: String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            return AppLanguage.text("snapshot.invalidName", name)
        case .notFound(let name):
            return AppLanguage.text("snapshot.missing", name)
        case .deleteFailed(let detail):
            return AppLanguage.text("snapshot.deleteFailed", detail)
        case .consoleFailed(let detail):
            return AppLanguage.text("snapshot.consoleFailed", detail)
        case .serialMismatch(let serial, let avdName):
            return AppLanguage.text("snapshot.staleSerial", serial, avdName)
        }
    }
}

/// 快照的保存/加载/删除。运行中的实例走 adb console，停止的实例直接操作 snapshots 目录。
public final class SnapshotService: @unchecked Sendable {
    public let tools: ToolPaths

    public init(tools: ToolPaths) {
        self.tools = tools
    }

    public func list(avdPath: String) -> [String] {
        let directory = URL(fileURLWithPath: avdPath).appendingPathComponent("snapshots")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter { Self.isValidName($0) && $0 != "default_boot" }
            .sorted()
    }

    public func save(serial: String, avdName: String, name: String) throws {
        try console("save", serial: serial, avdName: avdName, name: name)
    }

    public func load(serial: String, avdName: String, name: String) throws {
        try console("load", serial: serial, avdName: avdName, name: name)
    }

    public func delete(serial: String?, avdName: String, avdPath: String, name: String) throws {
        try validate(name: name)
        if let serial {
            try console("delete", serial: serial, avdName: avdName, name: name)
            return
        }

        let directory = URL(fileURLWithPath: avdPath)
            .appendingPathComponent("snapshots")
            .appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw SnapshotError.notFound(name)
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw SnapshotError.deleteFailed(error.localizedDescription)
        }
    }

    private func console(_ subcommand: String, serial: String, avdName: String, name: String) throws {
        try validate(name: name)
        guard let adb = tools.adb else {
            throw ToolPathError.missingTool("adb")
        }
        guard serialMatches(serial: serial, avdName: avdName, adb: adb) else {
            throw SnapshotError.serialMismatch(serial: serial, avdName: avdName)
        }

        let result = try CommandRunner.run(
            adb,
            ["-s", serial, "emu", "avd", "snapshot", subcommand, name],
            environment: ToolEnvironment.make(tools: tools),
            timeout: 60
        )
        guard result.status == 0 else {
            throw CommandRunnerError.nonZero(status: result.status, stderr: result.failureDetail)
        }

        // adb emu 即使控制台返回 KO 也可能以 0 退出，需要检查控制台文本。
        let output = (result.stdout + "\n" + result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if output.contains("KO:") || output.localizedCaseInsensitiveContains("error") {
            throw SnapshotError.consoleFailed(output)
        }
    }

    private func serialMatches(serial: String, avdName: String, adb: URL) -> Bool {
        guard let result = try? CommandRunner.run(
            adb,
            ["-s", serial, "emu", "avd", "name"],
            environment: ToolEnvironment.make(tools: tools),
            timeout: 20
        ), result.status == 0 else {
            return false
        }
        let actual = result.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0 != "OK" }
        return actual == avdName
    }

    private func validate(name: String) throws {
        guard Self.isValidName(name), name != "default_boot" else {
            throw SnapshotError.invalidName(name)
        }
    }

    private static func isValidName(_ name: String) -> Bool {
        !name.isEmpty
            && name.count <= 64
            && !name.hasPrefix(".")
            && name != "."
            && name != ".."
            && name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }
}
