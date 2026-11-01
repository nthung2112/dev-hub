import AppKit
import SwiftUI
import DevHubCore

/// The popover: tab strip on top, the selected tab (or Settings) in a scrolling middle, and a footer.
struct HubView: View {
    @ObservedObject var store: HubStore
    @ObservedObject var settings: AppSettings
    var onClose: () -> Void = {}
    /// Caps the panel on a short screen. Nil lets it grow with its content, up to the screen, as `--render` does.
    var maximumHeight: CGFloat?
    @State private var showSettings: Bool
    private let settingsPage: String

    init(store: HubStore, settings: AppSettings, showSettings: Bool = false, settingsPage: String = SettingsView.generalPage,
         maximumHeight: CGFloat? = nil, onClose: @escaping () -> Void = {}) {
        self.store = store
        self.settings = settings
        self.onClose = onClose
        self.maximumHeight = maximumHeight
        self.settingsPage = settingsPage
        _showSettings = State(initialValue: showSettings)
    }

    /// The middle scrolls once it would run past the screen; header and footer stay put.
    private var maxScrollHeight: CGFloat {
        if let maximumHeight {
            // Header, footer and the tab strip stay on screen; the middle takes the rest.
            return max(160, maximumHeight - 200)
        }
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(240, screen - 170)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            Divider()
            ScrollView {
                Group {
                    if showSettings {
                        SettingsView(store: store, settings: settings, page: settingsPage)
                    } else if let tab = store.selectedEntry?.members.first {
                        // A group's members all show the group's view, so its first member's will do.
                        tab.tab.content(tab)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .frame(maxHeight: maxScrollHeight)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            footer
                .padding(14)
        }
        .frame(width: 520)
        .onReceive(NotificationCenter.default.publisher(for: .devHubShowSettings)) { _ in
            showSettings = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Dev Hub").font(.headline)
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
            }
            FlowLayout(spacing: 4) {
                ForEach(Array(store.stripEntries.enumerated()), id: \.element.id) { index, entry in
                    TabButton(entry: entry, index: index, isSelected: !showSettings && entry.id == store.selectedEntry?.id) {
                        settings.selectedTab = entry.id
                        showSettings = false
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let refreshed = store.lastRefreshed {
                Text("Updated \(refreshed.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button(showSettings ? "Done" : "Settings") { showSettings.toggle() }
                .keyboardShortcut(",", modifiers: .command)
            Button("Refresh") { store.refresh(.manual) }
                .disabled(store.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }
}

/// `Mac ● 14`: the entry's title with a dot (red failing, orange failed) and the red count, across
/// every tab it shows.
private struct TabButton: View {
    let entry: StripEntry
    let index: Int
    let isSelected: Bool
    let action: () -> Void

    private var failing: Int { entry.members.reduce(0) { $0 + ($1.snapshot?.failingCount ?? 0) } }

    private var dot: Color? {
        if failing > 0 { return .red }
        if entry.members.contains(where: { $0.problem != nil }) { return .orange }
        return nil
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(entry.title).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if entry.members.contains(where: \.isRefreshing) {
                    ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 8, height: 8)
                } else if let dot {
                    Circle().fill(dot).frame(width: 6, height: 6)
                }
                if failing > 0 {
                    Text("\(failing)").font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(TabShortcut(index: index))
        .help(entry.members.map(\.line).joined(separator: "\n") + (index < 9 ? " (⌘\(index + 1))" : ""))
    }
}

/// ⌘1…⌘9 switch tabs.
private struct TabShortcut: ViewModifier {
    let index: Int

    func body(content: Content) -> some View {
        if index < 9, let key = "\(index + 1)".first {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        } else {
            content
        }
    }
}
