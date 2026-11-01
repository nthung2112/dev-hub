import AppKit
import SwiftUI
import DevHubCore

/// Settings in pages: General (tabs, refresh, notifications, notch) and one per visible tab, picked
/// from a strip whose dots show each tab's health.
struct SettingsView: View {
    static let generalPage = "general"

    @ObservedObject var store: HubStore
    @ObservedObject var settings: AppSettings
    @State private var page: String

    init(store: HubStore, settings: AppSettings, page: String = SettingsView.generalPage) {
        self.store = store
        self.settings = settings
        _page = State(initialValue: page)
    }

    /// The visible tabs that have a settings page.
    private var configurableTabs: [TabState] { store.visibleTabs.filter { $0.tab.settings != nil } }
    private var pageTab: TabState? { configurableTabs.first { $0.id == page } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            pagePicker
            if let tab = pageTab, let section = tab.tab.settings {
                section(tab).id(tab.id)
            } else {
                generalPage
            }
        }
    }

    // MARK: Page picker

    private var pagePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings").font(.system(size: 15, weight: .semibold))
            FlowLayout(spacing: 4) {
                PageChip(title: "General", systemImage: "gearshape", dot: nil, isSelected: pageTab == nil) {
                    page = Self.generalPage
                }
                ForEach(configurableTabs) { tab in
                    PageChip(title: tab.title, systemImage: nil, dot: tab.health.colour, isSelected: pageTab?.id == tab.id) {
                        page = tab.id
                    }
                    .help("\(tab.title) settings · \(tab.health.line)")
                }
            }
        }
    }

    // MARK: General

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            tabsGroup
            refreshGroup
            notificationsGroup
            notchGroup
        }
    }

    private var tabsGroup: some View {
        SettingsGroup("Tabs", footer: "A hidden tab isn't refreshed at all: no requests, no badge or banners. Its settings come back when you show it again. At least one tab stays on.") {
            ForEach(Array(store.tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 { RowDivider() }
                TabRow(tab: tab, isVisible: isVisible(tab.id), isLastVisible: isLastVisible(tab.id),
                       visibility: visibility(tab.id)) {
                    page = tab.id
                }
            }
        }
    }

    private var refreshGroup: some View {
        SettingsGroup("Refresh", footer: "Also on wake, when the network comes back, and when you open the panel with data older than 15 minutes. After errors it waits longer, up to 4 hours.") {
            SettingsRow("Check every") {
                Picker("Check every", selection: $settings.refreshMinutes) {
                    ForEach(intervalChoices, id: \.self) { minutes in
                        Text(Self.intervalLabel(minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .controlSize(.small)
            }
            RowDivider()
            SettingsRow("Last checked", help: lastCheckedLine) {
                Button {
                    store.refresh(.manual)
                } label: {
                    Label("Refresh now", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(store.isRefreshing)
            }
        }
    }

    private var notificationsGroup: some View {
        SettingsGroup("Notifications", footer: "When more than three things change at once, they're rolled into one banner.") {
            if !store.notifier.isAvailable {
                Label("Banners only work from the bundled app. Build it with scripts/build-app.sh.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                RowDivider()
            }
            SwitchRow("Newly flagged",
                      help: "Something a tab flags turns up here.",
                      isOn: $settings.notifyFlagged)
            RowDivider()
            SwitchRow("Recovered", help: "Something that was flagged goes back to normal.", isOn: $settings.notifyRecovered)
            RowDivider()
            SettingsRow("Morning summary", help: "On working days, one banner with a line per tab.") {
                HStack(spacing: 8) {
                    DatePicker("Time", selection: morningTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .controlSize(.small)
                        .disabled(!settings.notifyMorningSummary)
                        .opacity(settings.notifyMorningSummary ? 1 : 0.5)
                    Toggle("Morning summary", isOn: $settings.notifyMorningSummary)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
            RowDivider()
            SettingsRow("Test", help: "Sends a banner with each tab's current line.") {
                Button("Send test notification") { store.sendTestNotification() }
                    .controlSize(.small)
                    .disabled(!store.notifier.isAvailable)
            }
        }
    }

    private var notchGroup: some View {
        SettingsGroup("Notch", footer: "Hover the top centre of the screen to open Dev Hub. Alerts are off by default; the menu bar icon has the same switch.") {
            SettingsRow("Show notch on", help: "Every screen by default. A screen without a notch gets a black pill at the top centre of its menu bar.") {
                Picker("Show notch on", selection: $settings.notchDisplay) {
                    Text("Main display").tag(NotchDisplayChoice.main)
                    ForEach(notchDisplays) { display in
                        Text(display.name).tag(choice(for: display))
                    }
                    if case let .display(id, name) = settings.notchDisplay, !notchDisplays.contains(where: { $0.id == id }) {
                        Text("\(name) (not connected)").tag(settings.notchDisplay)
                    }
                    Text("All displays").tag(NotchDisplayChoice.all)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .controlSize(.small)
            }
            RowDivider()
            SwitchRow("Open on hover",
                      help: "When this is off, click the notch to open it. It stays open until you close it.",
                      isOn: $settings.opensOnHover)
            RowDivider()
            SettingsRow("Hover delay", help: "How long the pointer rests on the notch before it opens. None opens it as soon as the pointer arrives.") {
                Picker("Hover delay", selection: $settings.hoverDelay) {
                    ForEach(HoverDelay.allCases, id: \.self) { delay in
                        Text(delay.title).tag(delay)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .controlSize(.small)
                .disabled(!settings.opensOnHover)
            }
            RowDivider()
            SwitchRow("Show alerts on the notch",
                      help: "The lines under the notch when something is red or a refresh failed.",
                      isOn: $settings.showsAlerts)
            RowDivider()
            SwitchRow("Show the red count on the notch",
                      help: "The total, above those lines. The lines themselves stay either way.",
                      isOn: $settings.showCounts)
            RowDivider()
            SwitchRow("Launch at login", help: "Takes effect at your next login.", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.setLaunchAtLogin($0) }
            ))
            if let error = settings.launchAtLoginError {
                ErrorText(error)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
    }

    private var notchDisplays: [NotchDisplay] { NotchScreens.connected() }

    /// The picker's tag for a connected display. The saved choice keeps its stored name, so it stays selected.
    private func choice(for display: NotchDisplay) -> NotchDisplayChoice {
        if case let .display(id, name) = settings.notchDisplay, id == display.id {
            return .display(id: id, name: name)
        }
        return .display(id: display.id, name: display.name)
    }

    // MARK: Helpers

    private var lastCheckedLine: String {
        if store.isRefreshing { return "Refreshing now…" }
        guard let refreshed = store.lastRefreshed else { return "Not yet" }
        return "\(refreshed.formatted(date: .omitted, time: .shortened)), every visible tab"
    }

    private var intervalChoices: [Int] {
        var choices = [15, 30, 45, 60, 90, 120, 180, 240].filter(RefreshSchedule.intervalRange.contains)
        if !choices.contains(settings.refreshMinutes) {
            choices.append(settings.refreshMinutes)
            choices.sort()
        }
        return choices
    }

    static func intervalLabel(_ minutes: Int) -> String {
        guard minutes % 60 == 0 else { return "\(minutes) minutes" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    private var allTabIDs: [String] { store.tabs.map(\.id) }

    private func isVisible(_ id: String) -> Bool {
        TabVisibility.visible(allTabIDs, hidden: settings.hiddenTabs).contains(id)
    }

    private func visibility(_ id: String) -> Binding<Bool> {
        Binding(
            get: { isVisible(id) },
            set: { on in settings.hiddenTabs = TabVisibility.setting(id, visible: on, all: allTabIDs, hidden: settings.hiddenTabs) }
        )
    }

    private func isLastVisible(_ id: String) -> Bool {
        TabVisibility.visible(allTabIDs, hidden: settings.hiddenTabs) == [id]
    }

    /// The morning time as a `Date` today, stored as minutes after midnight.
    private var morningTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(byAdding: .minute, value: settings.morningMinuteOfDay, to: Calendar.current.startOfDay(for: Date())) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                settings.morningMinuteOfDay = (c.hour ?? 9) * 60 + (c.minute ?? 0)
            }
        )
    }
}

/// One segment of the page strip: `⚙ General` or `● Mac`.
private struct PageChip: View {
    let title: String
    let systemImage: String?
    let dot: Color?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11))
                }
                if let dot {
                    Circle().fill(dot).frame(width: 7, height: 7)
                }
                Text(title).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

/// A tab in the General page: its health, a way to its settings, and whether it's shown.
private struct TabRow: View {
    @ObservedObject var tab: TabState
    let isVisible: Bool
    let isLastVisible: Bool
    let visibility: Binding<Bool>
    let openSettings: () -> Void

    private var health: TabHealth { isVisible ? tab.health : .off }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: health.symbol)
                .font(.system(size: 13))
                .foregroundStyle(health.colour)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title).font(.system(size: 12, weight: .medium))
                Text(health.line)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(health.line)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isVisible, tab.tab.settings != nil {
                Button(action: openSettings) {
                    HStack(spacing: 2) {
                        Text("Settings")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                }
                .controlSize(.small)
                .help("Open the \(tab.title) settings")
            }
            Toggle("Show \(tab.title)", isOn: visibility)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isLastVisible)
                .help(isLastVisible ? "At least one tab stays on" : (isVisible ? "Hide the \(tab.title) tab" : "Show the \(tab.title) tab"))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}
