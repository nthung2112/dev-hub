import Foundation
import UserNotifications
import DevHubCore

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let stateURL: URL
    private(set) var lastSeen: LastSeen

    /// UNUserNotificationCenter traps when the process is not a bundled app (e.g. `swift run`).
    let isAvailable = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil

    init(stateURL: URL = LastSeen.defaultURL) {
        self.stateURL = stateURL
        lastSeen = LastSeen.load(from: stateURL) ?? LastSeen()
        super.init()
    }

    func requestAuthorization() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("DevHub: notification authorization failed: \(error.localizedDescription)") }
        }
    }

    /// `sound` off leaves the banner silent, for callers that play their own.
    func send(title: String, body: String, id: String = UUID().uuidString, sound: Bool = true) {
        guard isAvailable else {
            NSLog("DevHub (notifications unavailable outside the .app bundle): \(title) - \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound ? .default : nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func sendTest(lines: [String]) {
        send(title: "Dev Hub", body: HubSummary.morning(lines))
    }

    // MARK: - Rules

    /// Diffs a tab against what its last refresh saw, sends the enabled banners, then persists.
    func handleRefresh(tabID: String, title: String, snapshot: MonitorSnapshot, settings: AppSettings) {
        let events = SnapshotDiff.events(previous: lastSeen.tabs[tabID], current: snapshot).filter { event in
            switch event {
            case .flagged: return settings.notifyFlagged
            case .recovered: return settings.notifyRecovered
            }
        }
        let stamp = Int(Date().timeIntervalSince1970)
        for banner in HubSummary.banners(events, tabID: tabID, tabTitle: title) {
            send(title: banner.title, body: banner.body, id: "\(banner.id)-\(stamp)")
        }
        var next = lastSeen
        next.tabs[tabID] = SnapshotDiff.record(snapshot)
        persist(next)
    }

    func isMorningDue(settings: AppSettings, now: Date) -> Bool {
        settings.notifyMorningSummary && !lastSeen.hasSent(HubReminders.morningKey(now))
            && HubReminders.isMorningDue(now: now, minuteOfDay: settings.morningMinuteOfDay)
    }

    func sendMorning(lines: [String], settings: AppSettings, now: Date) {
        guard isMorningDue(settings: settings, now: now) else { return }
        let key = HubReminders.morningKey(now)
        send(title: "Good morning · Dev Hub", body: HubSummary.morning(lines), id: key)
        var next = lastSeen
        next.markSent(key)
        persist(next)
    }

    private func persist(_ state: LastSeen) {
        lastSeen = state
        do {
            try state.save(to: stateURL)
        } catch {
            NSLog("DevHub: couldn't save last-seen state: \(error.localizedDescription)")
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
