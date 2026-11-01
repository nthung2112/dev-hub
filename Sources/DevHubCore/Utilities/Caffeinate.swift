import Combine
import Foundation

/// What Keep Awake stops from sleeping, as `caffeinate` flags.
public struct CaffeinateOptions: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `-d`: the display stays on.
    public static let display = CaffeinateOptions(rawValue: 1 << 0)
    /// `-i`: the Mac doesn't idle-sleep.
    public static let idle = CaffeinateOptions(rawValue: 1 << 1)
    /// `-s`: the Mac doesn't sleep at all; macOS only honours it on AC power.
    public static let system = CaffeinateOptions(rawValue: 1 << 2)
    /// `-m`: disks don't idle-sleep.
    public static let disk = CaffeinateOptions(rawValue: 1 << 3)

    public static let standard: CaffeinateOptions = [.display, .idle]
}

/// How long Keep Awake lasts; `untilStopped` runs until you press Stop or quit Dev Hub.
public enum CaffeinateDuration: Int, CaseIterable, Identifiable, Sendable {
    case minutes15 = 900
    case minutes30 = 1800
    case hour1 = 3600
    case hours2 = 7200
    case hours4 = 14400
    case untilStopped = 0

    public var id: Int { rawValue }

    public var seconds: Int? { self == .untilStopped ? nil : rawValue }

    public var label: String {
        switch self {
        case .minutes15: return "15 minutes"
        case .minutes30: return "30 minutes"
        case .hour1: return "1 hour"
        case .hours2: return "2 hours"
        case .hours4: return "4 hours"
        case .untilStopped: return "Until stopped"
        }
    }
}

public enum Caffeinate {
    public static let executable = URL(fileURLWithPath: "/usr/bin/caffeinate")

    /// `-d -i -t 900 -w 4242`. `-w` ends caffeinate with Dev Hub, even if Dev Hub crashes. With no
    /// option ticked it keeps the Mac from idle-sleeping, as `caffeinate` does by default.
    public static func arguments(options: CaffeinateOptions, duration: CaffeinateDuration, pid: Int32) -> [String] {
        var flags: [String] = []
        if options.contains(.display) { flags.append("-d") }
        if options.contains(.idle) || options.isEmpty { flags.append("-i") }
        if options.contains(.disk) { flags.append("-m") }
        if options.contains(.system) { flags.append("-s") }
        if let seconds = duration.seconds { flags += ["-t", String(seconds)] }
        return flags + ["-w", String(pid)]
    }
}

/// Where Keep Awake stands, readable from any thread.
public struct KeepAwakeState: Sendable, Equatable {
    public let startedAt: Date
    /// Nil when it runs until stopped.
    public let endsAt: Date?

    /// `Awake until 14:30`, `Awake until stopped`.
    public var line: String {
        guard let endsAt else { return "Awake until stopped" }
        return "Awake until \(endsAt.formatted(date: .omitted, time: .shortened))"
    }
}

/// The one `caffeinate` Dev Hub runs. Started and stopped on the main thread; `current` can be
/// read from anywhere.
public final class CaffeinateController: ObservableObject, @unchecked Sendable {
    public static let shared = CaffeinateController()

    @Published public private(set) var state: KeepAwakeState?

    private let lock = NSLock()
    private var process: Process?
    private var locked: KeepAwakeState?

    public init() {}

    public var current: KeepAwakeState? { lock.withLock { locked } }
    public var isActive: Bool { current != nil }

    /// Replaces any running Keep Awake with a new one.
    public func start(options: CaffeinateOptions, duration: CaffeinateDuration, now: Date = Date()) throws {
        stop()
        let process = Process()
        process.executableURL = Caffeinate.executable
        process.arguments = Caffeinate.arguments(options: options, duration: duration,
                                                 pid: ProcessInfo.processInfo.processIdentifier)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            self?.ended(ended)
        }
        try process.run()
        let state = KeepAwakeState(startedAt: now, endsAt: duration.seconds.map { now.addingTimeInterval(TimeInterval($0)) })
        lock.withLock {
            self.process = process
            locked = state
        }
        publish(state)
    }

    public func stop() {
        let running = lock.withLock { () -> Process? in
            defer {
                process = nil
                locked = nil
            }
            return process
        }
        guard let running else { return }
        running.terminationHandler = nil
        if running.isRunning { running.terminate() }
        publish(nil)
    }

    /// The timer ran out, or caffeinate was killed outside Dev Hub.
    private func ended(_ ended: Process) {
        let wasCurrent = lock.withLock { () -> Bool in
            guard process === ended else { return false }
            process = nil
            locked = nil
            return true
        }
        if wasCurrent { publish(nil) }
    }

    private func publish(_ state: KeepAwakeState?) {
        if Thread.isMainThread {
            self.state = state
        } else {
            DispatchQueue.main.async { self.state = self.current }
        }
    }
}
