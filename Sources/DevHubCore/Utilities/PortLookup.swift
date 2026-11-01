import Darwin
import Foundation

/// A process listening on a TCP port.
public struct ListeningProcess: Sendable, Equatable, Identifiable {
    public let pid: Int32
    public let command: String
    public let user: String
    /// `*:3000`, `127.0.0.1:3000`, `[::1]:3000`
    public let addresses: [String]

    public var id: Int32 { pid }

    public init(pid: Int32, command: String, user: String, addresses: [String]) {
        self.pid = pid
        self.command = command
        self.user = user
        self.addresses = addresses
    }
}

public enum PortLookupError: Error, LocalizedError, Equatable {
    case invalidPort
    case notPermitted(pid: Int32)
    case alreadyExited(pid: Int32)
    case failed(pid: Int32, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidPort: return "Enter a port from 1 to 65535."
        case .notPermitted(let pid): return "Process \(pid) belongs to another user, so Dev Hub can't stop it without admin rights."
        case .alreadyExited(let pid): return "Process \(pid) has already exited."
        case .failed(let pid, let code): return "Couldn't stop process \(pid): \(String(cString: strerror(code)))."
        }
    }
}

/// Finds what's listening on a port with `lsof`, and stops it.
public enum PortLookup {
    static let lsof = URL(fileURLWithPath: "/usr/sbin/lsof")

    /// Ports dev servers usually take.
    public static let commonPorts = [3000, 3001, 4200, 5000, 5173, 8000, 8080, 8443, 9000, 9222]

    /// `3000` or ` 3000 `; nil unless it's 1-65535.
    public static func port(_ text: String) -> Int? {
        guard let port = Int(text.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else { return nil }
        return port
    }

    public static func listening(on port: Int) async throws -> [ListeningProcess] {
        guard (1...65535).contains(port) else { throw PortLookupError.invalidPort }
        let result = try await Shell.run(lsof, ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-FpcLn"], timeout: 10)
        // lsof exits 1 when nothing matches.
        if !result.succeeded && result.stdout.isEmpty { return [] }
        return parse(result.stdout)
    }

    /// lsof's field output: `p<pid>` starts a process, then `c<command>`, `L<login>`, and an
    /// `f<fd>` / `n<address>` pair for each socket.
    static func parse(_ output: String) -> [ListeningProcess] {
        var processes: [ListeningProcess] = []
        var pid: Int32?
        var command = ""
        var user = ""
        var addresses: [String] = []

        func flush() {
            if let pid { processes.append(ListeningProcess(pid: pid, command: command, user: user, addresses: addresses)) }
        }

        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                flush()
                pid = Int32(value)
                command = ""
                user = ""
                addresses = []
            case "c": command = value
            case "L": user = value
            case "n": if !addresses.contains(value) { addresses.append(value) }
            default: break
            }
        }
        flush()
        return processes
    }

    /// SIGTERM asks it to quit; `force` sends SIGKILL.
    public static func stop(pid: Int32, force: Bool = false) throws {
        guard Darwin.kill(pid, force ? SIGKILL : SIGTERM) == 0 else {
            switch errno {
            case EPERM: throw PortLookupError.notPermitted(pid: pid)
            case ESRCH: throw PortLookupError.alreadyExited(pid: pid)
            case let code: throw PortLookupError.failed(pid: pid, errno: code)
            }
        }
    }
}
