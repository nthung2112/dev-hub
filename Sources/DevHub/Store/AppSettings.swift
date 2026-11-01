import Foundation
import DevHubCore

/// Settings every tab shares. A tab's own settings are kept by its settings view.
@MainActor
final class AppSettings: ObservableObject {
    let defaults: UserDefaults

    @Published var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: Keys.refreshMinutes) } }
    /// Off by default; shows the number of red items at the top of the notch alert.
    @Published var showCounts: Bool { didSet { defaults.set(showCounts, forKey: Keys.showCounts) } }
    /// Hover opens the notch. Off, a click opens it and it stays until you close it.
    @Published var opensOnHover: Bool { didSet { defaults.set(opensOnHover, forKey: Keys.opensOnHover) } }
    @Published var hoverDelay: HoverDelay { didSet { defaults.set(hoverDelay.rawValue, forKey: Keys.hoverDelay) } }
    /// The lines under the closed notch when a tab is red or a refresh needs attention.
    @Published var showsAlerts: Bool { didSet { defaults.set(showsAlerts, forKey: Keys.showsAlerts) } }
    @Published var notchDisplay: NotchDisplayChoice {
        didSet { defaults.set(try? JSONEncoder().encode(notchDisplay), forKey: Keys.notchDisplay) }
    }
    @Published var selectedTab: String { didSet { defaults.set(selectedTab, forKey: Keys.selectedTab) } }
    /// Tab IDs switched off in Settings.
    @Published var hiddenTabs: [String] { didSet { defaults.set(hiddenTabs, forKey: TabVisibility.hiddenKey) } }
    @Published var notifyFlagged: Bool { didSet { defaults.set(notifyFlagged, forKey: Keys.flagged) } }
    @Published var notifyRecovered: Bool { didSet { defaults.set(notifyRecovered, forKey: Keys.recovered) } }
    @Published var notifyMorningSummary: Bool { didSet { defaults.set(notifyMorningSummary, forKey: Keys.morning) } }
    /// Minutes after midnight, 09:00 by default.
    @Published var morningMinuteOfDay: Int { didSet { defaults.set(morningMinuteOfDay, forKey: Keys.morningMinute) } }
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginError: String?

    private enum Keys {
        static let refreshMinutes = "refresh.minutes"
        static let showCounts = "menuBar.showCounts"
        static let opensOnHover = "notch.opensOnHover"
        static let hoverDelay = "notch.hoverDelay"
        static let showsAlerts = "notch.showsAlerts"
        static let notchDisplay = "notch.display"
        static let selectedTab = "tabs.selected"
        static let flagged = "notify.flagged"
        static let recovered = "notify.recovered"
        static let morning = "notify.morningSummary"
        static let morningMinute = "notify.morningMinuteOfDay"
    }

    init(defaults: UserDefaults = SettingsDomain.defaults) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.refreshMinutes: RefreshSchedule.defaultMinutes,
            Keys.showCounts: false,
            Keys.opensOnHover: true,
            Keys.hoverDelay: HoverDelay.instant.rawValue,
            Keys.showsAlerts: false,
            Keys.flagged: true,
            Keys.recovered: true,
            Keys.morning: true,
            Keys.morningMinute: 9 * 60,
        ])
        refreshMinutes = RefreshSchedule.clampMinutes(defaults.integer(forKey: Keys.refreshMinutes))
        showCounts = defaults.bool(forKey: Keys.showCounts)
        opensOnHover = defaults.bool(forKey: Keys.opensOnHover)
        hoverDelay = HoverDelay(rawValue: defaults.string(forKey: Keys.hoverDelay) ?? "") ?? .instant
        showsAlerts = defaults.bool(forKey: Keys.showsAlerts)
        notchDisplay = Self.storedDisplay(defaults)
        selectedTab = defaults.string(forKey: Keys.selectedTab) ?? ""
        hiddenTabs = TabVisibility.hidden(defaults)
        notifyFlagged = defaults.bool(forKey: Keys.flagged)
        notifyRecovered = defaults.bool(forKey: Keys.recovered)
        notifyMorningSummary = defaults.bool(forKey: Keys.morning)
        morningMinuteOfDay = min(max(defaults.integer(forKey: Keys.morningMinute), 0), 24 * 60 - 1)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    private static func storedDisplay(_ defaults: UserDefaults) -> NotchDisplayChoice {
        guard let data = defaults.data(forKey: Keys.notchDisplay),
              let choice = try? JSONDecoder().decode(NotchDisplayChoice.self, from: data) else { return .all }
        return choice
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Couldn't update launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}
