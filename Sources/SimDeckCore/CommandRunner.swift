import Darwin
import Foundation

public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    /// 失败时优先使用 stderr；某些工具（例如 avdmanager 的 JDK 版本提示）只写 stdout。
    public var failureDetail: String {
        let parts = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let detail = parts.joined(separator: "\n")
        return detail.count > 2000 ? String(detail.prefix(2000)) + "…" : detail
    }
}

public enum CommandRunnerError: LocalizedError, Equatable {
    case launchFailed(String)
    case timedOut(String)
    case nonZero(status: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let detail):
            return AppLanguage.text("command.launchFailed", detail)
        case .timedOut(let command):
            return AppLanguage.text("command.timeout", command)
        case .nonZero(let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? AppLanguage.text("command.exitCode", String(status)) : AppLanguage.text("command.exitDetail", String(status), detail)
        }
    }
}

/// 同步地执行命令行工具并收集输出。所有调用都发生在后台队列。
public enum CommandRunner {
    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        input: String? = nil,
        timeout: TimeInterval = 60
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let input {
            let pipe = Pipe()
            pipe.fileHandleForWriting.write(Data(input.utf8))
            try? pipe.fileHandleForWriting.close()
            process.standardInput = pipe.fileHandleForReading
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        if let environment {
            process.environment = environment
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw CommandRunnerError.launchFailed("\(executable.path)：\(error.localizedDescription)")
        }

        let flag = TimeoutFlag()
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            flag.markTimedOut()
            process.terminate()
            // 给进程 2 秒收尾，仍不退出则强制结束，避免调用方永久阻塞。
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        defer { killer.cancel() }

        // stdout/stderr 并行读取，避免任一管道写满后阻塞进程。
        let outData = DataBox()
        let errData = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.wait()
        process.waitUntilExit()

        if flag.didTimeOut {
            throw CommandRunnerError.timedOut("\(executable.lastPathComponent) \(arguments.joined(separator: " "))")
        }

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData.value, as: UTF8.self),
            stderr: String(decoding: errData.value, as: UTF8.self)
        )
    }

    /// 把 stdout 原样写入文件，用于 `adb exec-out screencap` 这类二进制输出。
    @discardableResult
    public static func runToFile(
        _ executable: URL,
        _ arguments: [String],
        output: URL,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60
    ) throws -> CommandResult {
        let files = FileManager.default
        if !files.fileExists(atPath: output.path) {
            files.createFile(atPath: output.path, contents: nil)
        }
        let outputHandle = try FileHandle(forWritingTo: output)
        try outputHandle.truncate(atOffset: 0)
        defer { try? outputHandle.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        if let environment {
            process.environment = environment
        }

        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw CommandRunnerError.launchFailed("\(executable.path)：\(error.localizedDescription)")
        }

        let flag = TimeoutFlag()
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            flag.markTimedOut()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        defer { killer.cancel() }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if flag.didTimeOut {
            throw CommandRunnerError.timedOut("\(executable.lastPathComponent) \(arguments.joined(separator: " "))")
        }

        return CommandResult(
            status: process.terminationStatus,
            stdout: "",
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func markTimedOut() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
