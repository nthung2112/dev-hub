import Foundation
import DevHubCore

/// `DevHub --dump [utilities]`: refreshes the named tabs (every visible tab by default) and prints their snapshots
/// as JSON. Snapshots hold no secrets, so nothing private can reach stdout.
enum DebugDump {
    static func run(arguments: [String]) async -> Int32 {
        let wanted = Set(arguments.drop { $0 != "--dump" }.dropFirst().filter { !$0.hasPrefix("-") })
        let visible = Set(TabVisibility.visible(MonitorRegistry.tabs.map(\.id), hidden: TabVisibility.hidden(SettingsDomain.defaults)))
        let tabs = MonitorRegistry.tabs.filter { wanted.isEmpty ? visible.contains($0.id) : wanted.contains($0.id) }
        let unknown = wanted.subtracting(MonitorRegistry.tabs.map(\.id))
        guard unknown.isEmpty else {
            let known = MonitorRegistry.tabs.map(\.id).joined(separator: ", ")
            FileHandle.standardError.write(Data("devhub: unknown tab \(unknown.sorted().joined(separator: ", ")) (tabs: \(known))\n".utf8))
            return 2
        }

        var snapshots: [String: MonitorSnapshot] = [:]
        var failed = false
        for tab in tabs {
            do {
                let snapshot = try await tab.make(SettingsDomain.defaults).refresh()
                snapshots[tab.id] = snapshot
            } catch {
                failed = true
                FileHandle.standardError.write(Data((HubDump.errorLine(tab.id, error) + "\n").utf8))
            }
        }
        if !snapshots.isEmpty, let data = try? HubDump.encode(snapshots) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        return failed ? 1 : 0
    }
}
