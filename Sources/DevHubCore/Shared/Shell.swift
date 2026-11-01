import Foundation

public struct ShellResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { status == 0 }

    /// The first non-empty line of stderr, else of stdout, for an inline error.
    public var message: String {
        let lines = (stderr + "\n" + stdout).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.first { !$0.isEmpty } ?? "exit status \(status)"
    }
}

public enum ShellError: Error, LocalizedError, Equatable {
    case notFound(String)
    case failed(command: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let name): return "Couldn't find \(name)."
        case .failed(let command, let message): return "\(command) failed: \(message)"
        }
    }
}

/// Runs a program directly, never through a shell string, without a terminal or prompts.
public enum Shell {
    /// A GUI app doesn't get the shell's PATH, so the usual install locations are searched too.
    public static var searchPath: [String] {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fixed = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.volta/bin", "\(home)/.yarn/bin", "\(home)/bin",
                     "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen: Set<String> = []
        return (path + fixed).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func find(_ name: String) -> URL? {
        searchPath.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Gives up after `timeout`, terminating the program, and terminates it too when the calling task
    /// is cancelled. Both pipes are drained while it runs, so a chatty program can't block on a full
    /// pipe. `input` is written to its stdin, which is otherwise empty.
    public static func run(_ executable: URL, _ arguments: [String] = [], timeout: TimeInterval = 15,
                           input: String? = nil, currentDirectory: URL? = nil,
                           environment extra: [String: String] = [:]) async throws -> ShellResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath.joined(separator: ":")
        environment["NO_COLOR"] = "1"
        for (key, value) in extra { environment[key] = value }
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        if let input {
            // Short input fits the pipe's buffer, so it's written before the program starts.
            let stdin = Pipe()
            try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try stdin.fileHandleForWriting.close()
            process.standardInput = stdin
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        let handle = ProcessBox(process)

        return try await withTaskCancellationHandler {
            try await wait(for: process, stdout: stdout, stderr: stderr, timeout: timeout)
        } onCancel: {
            handle.terminate()
        }
    }

    private static func wait(for process: Process, stdout: Pipe, stderr: Pipe, timeout: TimeInterval) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let group = DispatchGroup()
            let box = OutputBox()
            for (pipe, isOut) in [(stdout, true), (stderr, false)] {
                group.enter()
                DispatchQueue.global().async {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    box.set(String(decoding: data, as: UTF8.self), stdout: isOut)
                    group.leave()
                }
            }
            do {
                try process.run()
            } catch {
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                continuation.resume(throwing: error)
                return
            }
            if Task.isCancelled { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().async {
                process.waitUntilExit()
                group.wait()
                let (out, err) = box.values
                continuation.resume(returning: ShellResult(status: process.terminationStatus, stdout: out, stderr: err))
            }
        }
    }

    /// Runs `executable` and throws its error output when it exits non-zero.
    @discardableResult
    public static func check(_ executable: URL, _ arguments: [String] = [], timeout: TimeInterval = 15,
                             input: String? = nil, currentDirectory: URL? = nil,
                             environment: [String: String] = [:]) async throws -> ShellResult {
        let result = try await run(executable, arguments, timeout: timeout, input: input,
                                   currentDirectory: currentDirectory, environment: environment)
        guard result.succeeded else {
            throw ShellError.failed(command: executable.lastPathComponent, message: result.message)
        }
        return result
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) { self.process = process }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = ""
    private var err = ""

    func set(_ text: String, stdout: Bool) {
        lock.withLock { if stdout { out = text } else { err = text } }
    }

    var values: (String, String) { lock.withLock { (out, err) } }
}
