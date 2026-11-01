import Foundation

/// The Mac tab: Keep Awake, a port killer, Finder and screenshot switches, quick actions, cache
/// cleanup and network details. A refresh only reads the Mac's state for the view, so the tab never
/// turns red and never sends a banner.
public struct UtilitiesMonitor: Monitor {
    public let id = "utilities"
    public let title = "Mac"
    private let read: @Sendable (Date) async -> MachineStatus
    private let now: @Sendable () -> Date

    public init(defaults: UserDefaults) {
        self.init()
    }

    init(read: @escaping @Sendable (Date) async -> MachineStatus = { await MachineInfo.read(now: $0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.read = read
        self.now = now
    }

    public func refresh() async throws -> MonitorSnapshot {
        UtilitiesRules.monitorSnapshot(await read(now()))
    }
}

public enum UtilitiesRules {
    /// Always clean: the tab has nothing to flag.
    public static func monitorSnapshot(_ status: MachineStatus) -> MonitorSnapshot {
        MonitorSnapshot(status: .clean, fetchedAt: status.fetchedAt, summary: summary(status), detail: status)
    }

    /// `Mac: 82% · charging · 120 GB free of 494 GB`
    public static func summary(_ status: MachineStatus) -> String {
        let parts = [status.battery?.line, status.diskLine].compactMap { $0 }
        return parts.isEmpty ? "Mac: utilities" : "Mac: " + parts.joined(separator: " · ")
    }
}
