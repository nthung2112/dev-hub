import Foundation
import Testing
@testable import DevHubCore

@Suite struct TabVisibilityTests {
    private let all = ["alpha", "beta", "gamma", "delta", "epsilon"]

    @Test func hiddenTabsDropOutInOrder() {
        #expect(TabVisibility.visible(all, hidden: ["gamma", "delta"]) == ["alpha", "beta", "epsilon"])
        #expect(TabVisibility.visible(all, hidden: []) == all)
    }

    @Test func oneTabAlwaysStaysOn() {
        #expect(TabVisibility.visible(all, hidden: all) == ["alpha"])
        let hidden = TabVisibility.setting("epsilon", visible: false, all: all, hidden: ["alpha", "beta", "gamma", "delta"])
        #expect(hidden == ["alpha", "beta", "gamma", "delta"])
    }

    @Test func switchingKeepsTabStripOrderAndForgetsRemovedTabs() {
        var hidden = TabVisibility.setting("delta", visible: false, all: all, hidden: ["gone"])
        hidden = TabVisibility.setting("alpha", visible: false, all: all, hidden: hidden)
        #expect(hidden == ["alpha", "delta"])
        #expect(TabVisibility.setting("alpha", visible: true, all: all, hidden: hidden) == ["delta"])
    }

    @Test func aGroupTakesItsFirstVisibleMembersPlace() {
        let groups = [TabGroup(id: "delta", title: "Grouped", members: ["delta", "epsilon"])]
        let entries = TabGroups.entries(visible: ["alpha", "delta", "epsilon", "gamma"], groups: groups)
        #expect(entries.map(\.id) == ["alpha", "delta", "gamma"])
        #expect(entries[1].title == "Grouped" && entries[1].members == ["delta", "epsilon"] && entries[1].isGroup)
        #expect(entries[0].title == nil && entries[0].members == ["alpha"] && !entries[0].isGroup)

        let oneMember = TabGroups.entries(visible: ["alpha", "epsilon", "gamma"], groups: groups)
        #expect(oneMember.map(\.id) == ["alpha", "delta", "gamma"] && oneMember[1].members == ["epsilon"])
        #expect(TabGroups.entries(visible: ["alpha", "delta"], groups: groups)[1].members == ["delta"])
        #expect(TabGroups.entries(visible: ["alpha", "gamma"], groups: groups).map(\.id) == ["alpha", "gamma"], "both hidden leaves no entry")
        #expect(TabGroups.entries(visible: ["alpha", "gamma"], groups: []).map(\.id) == ["alpha", "gamma"])

        #expect(TabGroups.entryID(for: "epsilon", groups: groups) == "delta", "a saved group member opens the group")
        #expect(TabGroups.entryID(for: "delta", groups: groups) == "delta")
        #expect(TabGroups.entryID(for: "gamma", groups: groups) == "gamma")
    }

    @Test func readsTheSavedList() throws {
        let defaults = try #require(UserDefaults(suiteName: "devhub-tests-\(UUID().uuidString)"))
        #expect(TabVisibility.hidden(defaults) == [])
        defaults.set(["gamma"], forKey: TabVisibility.hiddenKey)
        #expect(TabVisibility.hidden(defaults) == ["gamma"])
    }
}
