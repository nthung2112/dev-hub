import Foundation

/// Which tabs are switched on. A hidden tab is left out of the panel and never refreshed, so it
/// makes no requests, drives no browser, and doesn't count towards the badge or banners.
public enum TabVisibility {
    public static let hiddenKey = "tabs.hidden"

    public static func hidden(_ defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: hiddenKey) ?? []
    }

    /// `all` in order, without the hidden ones. At least one tab always stays on: with every tab
    /// hidden, the first one shows.
    public static func visible(_ all: [String], hidden: [String]) -> [String] {
        let off = Set(hidden)
        let on = all.filter { !off.contains($0) }
        return on.isEmpty ? Array(all.prefix(1)) : on
    }

    /// The hidden list after switching `id` on or off. Switching off the last visible tab is refused.
    public static func setting(_ id: String, visible: Bool, all: [String], hidden: [String]) -> [String] {
        var off = hidden.filter { all.contains($0) && $0 != id }
        if !visible {
            guard all.contains(where: { $0 != id && !off.contains($0) }) else { return hidden }
            off.append(id)
        }
        return all.filter { off.contains($0) }
    }
}
