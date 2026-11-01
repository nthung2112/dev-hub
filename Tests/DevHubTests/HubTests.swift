import Foundation
import Testing
@testable import DevHubCore

/// A third tab written only against `Monitor`: badge, diff, banners and dump need nothing else.
private struct DummyMonitor: Monitor {
    let id = "dummy"
    let title = "Dummy"
    var items: [MonitorItem]

    func refresh() async throws -> MonitorSnapshot {
        MonitorSnapshot(status: items.isEmpty ? .clean : .failing(items.count), fetchedAt: Date(timeIntervalSince1970: 0),
                        summary: "Dummy \(items.count) failing", scope: "all", items: items)
    }
}

private func item(_ id: String, _ severity: MonitorItem.Severity = .failing) -> MonitorItem {
    MonitorItem(id: id, severity: severity, title: "SVC \(id)", detail: "0 of 5 items")
}

private var bangkok: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Bangkok")!
    return c
}

private func at(_ text: String) -> Date {
    let f = DateFormatter()
    f.calendar = bangkok
    f.timeZone = bangkok.timeZone
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: text)!
}

@Suite struct HubTests {
    @Test func anyMonitorDrivesTheBadgeDiffAndDump() async throws {
        let monitors: [any Monitor] = [DummyMonitor(items: []), DummyMonitor(items: [])]
        var snapshots: [MonitorSnapshot] = []
        for monitor in monitors { snapshots.append(try await monitor.refresh()) }
        #expect(HubBadge.make(snapshots: snapshots, problems: [nil, nil]) == nil)

        let failing = try await DummyMonitor(items: [item("1")]).refresh()
        #expect(HubBadge.make(snapshots: [failing, snapshots[1]], problems: [nil, nil]) == .red)
        #expect(SnapshotDiff.events(previous: SnapshotDiff.record(snapshots[0]), current: failing) == [.flagged(item("1"))])
        #expect(String(decoding: try HubDump.encode(["dummy": failing]), as: UTF8.self).contains("Dummy 1 failing"))
    }

    @Test func statusEncodesReadably() throws {
        for status in [MonitorStatus.clean, .warning(2), .failing(7), .error("boom")] {
            let data = try JSONEncoder().encode(status)
            #expect(try JSONDecoder().decode(MonitorStatus.self, from: data) == status)
        }
        #expect(String(decoding: try JSONEncoder().encode(MonitorStatus.failing(7)), as: UTF8.self).contains(#""state":"failing""#))
    }

    @Test func badgeIsRedForFailuresOrangeForProblems() {
        let clean = MonitorSnapshot(status: .clean, fetchedAt: Date(), summary: "")
        let failing = MonitorSnapshot(status: .failing(2), fetchedAt: Date(), summary: "")
        #expect(HubBadge.make(snapshots: [clean, nil], problems: [nil, nil]) == nil)
        #expect(HubBadge.make(snapshots: [clean], problems: [.error("x")]) == .orange)
        #expect(HubBadge.make(snapshots: [failing], problems: [.error("x")]) == .red)
        #expect(HubBadge.make(snapshots: [MonitorSnapshot(status: .warning(3), fetchedAt: Date(), summary: "")], problems: [nil]) == nil)
    }

    @Test func diffFlagsNewAndChangedItemsAndRecoveries() {
        let before = LastSeen.Tab(scope: "a", items: [
            "1": .init(severity: .failing, title: "SVC 1"),
            "2": .init(severity: .noData, title: "SVC 2"),
            "3": .init(severity: .failing, title: "SVC 3"),
        ])
        let now = MonitorSnapshot(status: .failing(2), fetchedAt: Date(), summary: "", scope: "a",
                                  items: [item("1"), item("2"), item("4", .noData)])
        #expect(SnapshotDiff.events(previous: before, current: now) == [
            .flagged(item("2")), .flagged(item("4", .noData)), .recovered(id: "3", title: "SVC 3"),
        ])
    }

    @Test func noBannersOnTheFirstRefreshOrAfterTheScopeChanged() {
        let now = MonitorSnapshot(status: .failing(1), fetchedAt: Date(), summary: "", scope: "a", items: [item("1")])
        #expect(SnapshotDiff.events(previous: nil, current: now).isEmpty)
        #expect(SnapshotDiff.events(previous: .init(scope: "b", items: [:]), current: now).isEmpty)
    }

    @Test func bannersRollUpBeyondThree() {
        let few = HubSummary.banners([.flagged(item("1")), .flagged(item("2", .noData)), .recovered(id: "3", title: "SVC 3")],
                                     tabID: "alpha", tabTitle: "Alpha")
        #expect(few.map(\.title) == ["Alpha: SVC 1 is red", "Alpha: SVC 2 has no data", "Alpha: SVC 3 recovered"])
        #expect(few[0].body == "0 of 5 items")

        let many = HubSummary.banners((1...5).map { .flagged(item("\($0)", $0 > 3 ? .noData : .failing)) }, tabID: "alpha", tabTitle: "Alpha")
        #expect(many.count == 1)
        #expect(many[0].title == "Alpha: 5 newly flagged")

        let worded = MonitorItem(id: "x", severity: .failing, title: "SVC-9", detail: "1 overdue item", headline: "has overdue items")
        #expect(HubSummary.banners([.flagged(worded)], tabID: "beta", tabTitle: "Beta").first?.title == "Beta: SVC-9 has overdue items")
        #expect(many[0].body == "SVC 1, SVC 2, SVC 3, SVC 4, …")
    }

    @Test func lastSeenRoundTripsAndCapsSentKeys() throws {
        let url = try tempDirectory().appendingPathComponent("last-seen.json")
        var seen = LastSeen(tabs: ["alpha": .init(scope: "a", items: ["1": .init(severity: .failing, title: "SVC 1")])])
        for i in 0..<50 { seen.markSent("k\(i)") }
        #expect(seen.sentKeys.count == LastSeen.maxSentKeys)
        #expect(seen.hasSent("k49") && !seen.hasSent("k0"))
        try seen.save(to: url)
        #expect(LastSeen.load(from: url) == seen)
    }

    @Test func morningSummaryIsDueOnWorkingDayMornings() {
        #expect(HubReminders.isMorningDue(now: at("2026-10-15 09:00"), minuteOfDay: 540, calendar: bangkok))
        #expect(HubReminders.isMorningDue(now: at("2026-10-15 11:59"), minuteOfDay: 540, calendar: bangkok))
        #expect(!HubReminders.isMorningDue(now: at("2026-10-15 12:00"), minuteOfDay: 540, calendar: bangkok))
        #expect(!HubReminders.isMorningDue(now: at("2026-10-15 08:59"), minuteOfDay: 540, calendar: bangkok))
        #expect(!HubReminders.isMorningDue(now: at("2026-10-17 09:30"), minuteOfDay: 540, calendar: bangkok))
        #expect(HubReminders.morningKey(at("2026-10-15 09:00"), calendar: bangkok) == "morning-2026-10-15")
    }

    @Test func refreshScheduleBacksOffAndClamps() {
        #expect(RefreshSchedule.clampMinutes(5) == 15)
        #expect(RefreshSchedule.clampMinutes(500) == 240)
        #expect(RefreshSchedule.interval(baseMinutes: 60, consecutiveFailures: 0) == 3600)
        #expect(RefreshSchedule.interval(baseMinutes: 60, consecutiveFailures: 1) == 7200)
        #expect(RefreshSchedule.interval(baseMinutes: 60, consecutiveFailures: 5) == 240 * 60)
        #expect(RefreshSchedule.delayBeforeFetch(lastAttempt: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 20)) == 40)
        #expect(RefreshSchedule.isStale(lastSuccess: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 16 * 60)))
        #expect(!RefreshSchedule.isStale(lastSuccess: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 14 * 60)))
    }
}
