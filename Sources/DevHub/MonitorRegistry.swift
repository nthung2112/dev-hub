import Foundation
import SwiftUI
import DevHubCore

/// Every tab, in tab-strip order. A new tab is its `Monitor` in `Sources/DevHubCore/<Name>/`, its
/// view in `Views/`, and one line here.
enum MonitorRegistry {
    static let tabs: [MonitorTab] = [
        MonitorTab(make: { UtilitiesMonitor(defaults: $0) }, content: { UtilitiesView(tab: $0) }),
        MonitorTab(make: { TrendingMonitor(defaults: $0) }, content: { TrendingView(tab: $0) }),
    ]

    /// Tabs that share one strip entry. Each member still refreshes, reports and has settings on its own.
    static let groups: [TabGroup] = []
}

/// A registered tab: how to build its monitor from the current settings, and its views.
struct MonitorTab: Identifiable, Sendable {
    let id: String
    let title: String
    let make: @Sendable (UserDefaults) -> any Monitor
    let content: @MainActor @Sendable (TabState) -> AnyView
    let settings: (@MainActor @Sendable (TabState) -> AnyView)?

    init<M: Monitor, Content: View>(
        make: @escaping @Sendable (UserDefaults) -> M,
        content: @escaping @MainActor @Sendable (TabState) -> Content
    ) {
        self.init(make: make, content: content, settings: Optional<@MainActor @Sendable (TabState) -> EmptyView>.none)
    }

    init<M: Monitor, Content: View, Settings: View>(
        make: @escaping @Sendable (UserDefaults) -> M,
        content: @escaping @MainActor @Sendable (TabState) -> Content,
        settings: (@MainActor @Sendable (TabState) -> Settings)?
    ) {
        let probe = make(UserDefaults(suiteName: "local.devhub.registry") ?? .standard)
        id = probe.id
        title = probe.title
        self.make = { make($0) }
        self.content = { AnyView(content($0)) }
        self.settings = settings.map { view in { @MainActor @Sendable tab in AnyView(view(tab)) } }
    }
}
