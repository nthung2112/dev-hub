import Foundation

/// Tabs that share one entry in the tab strip. Each member keeps its own monitor, settings page and
/// switch in General › Tabs; only the strip and the panel show them together.
public struct TabGroup: Sendable, Equatable {
    /// The entry's id, which is also what `tabs.selected` holds while it's picked.
    public let id: String
    public let title: String
    /// In the order the group shows them.
    public let members: [String]

    public init(id: String, title: String, members: [String]) {
        self.id = id
        self.title = title
        self.members = members
    }
}

public enum TabGroups {
    /// One entry in the strip: a tab on its own, or a group's visible members.
    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: String
        /// The group's title; nil for a tab on its own, which shows its own.
        public let title: String?
        public let members: [String]

        public var isGroup: Bool { title != nil }
    }

    /// `visible` in strip order, each group folded into one entry where its first visible member
    /// is. A group with one member left visible still shows under its own title.
    public static func entries(visible: [String], groups: [TabGroup]) -> [Entry] {
        var entries: [Entry] = []
        var placed: Set<String> = []
        for id in visible {
            if let group = groups.first(where: { $0.members.contains(id) }) {
                guard placed.insert(group.id).inserted else { continue }
                entries.append(Entry(id: group.id, title: group.title, members: group.members.filter(visible.contains)))
            } else {
                entries.append(Entry(id: id, title: nil, members: [id]))
            }
        }
        return entries
    }

    /// The entry that shows `tabID`: its group's, or its own.
    public static func entryID(for tabID: String, groups: [TabGroup]) -> String {
        groups.first { $0.members.contains(tabID) }?.id ?? tabID
    }
}
