import AppKit
import Combine
import Network
import DevHubCore

/// One tab's state: its last good snapshot, which stays on screen when a later refresh fails.
@MainActor
final class TabState: ObservableObject, Identifiable {
    let tab: MonitorTab
    unowned let store: HubStore

    @Published fileprivate(set) var snapshot: MonitorSnapshot?
    /// `.error(…)` from the latest refresh; nil once a refresh succeeds.
    @Published fileprivate(set) var problem: MonitorStatus?
    @Published fileprivate(set) var isRefreshing = false
    @Published fileprivate(set) var lastRefreshed: Date?

    nonisolated let id: String
    var title: String { tab.title }

    init(tab: MonitorTab, store: HubStore) {
        self.tab = tab
        self.store = store
        id = tab.id
    }

    func detail<T>(_ type: T.Type) -> T? { snapshot?.detail as? T }

    fileprivate func apply(_ result: Result<MonitorSnapshot, Error>) {
        switch result {
        case .success(let snapshot):
            self.snapshot = snapshot
            problem = nil
            lastRefreshed = snapshot.fetchedAt
        case .failure(let error):
            problem = .error(error.localizedDescription)
        }
    }

    /// The tooltip and morning-summary line: `Mac 7 red`, or why there's none.
    var line: String {
        if case .error(let message) = problem { return "\(title): \(message)" }
        return snapshot?.summary ?? "\(title): loading…"
    }
}

@MainActor
final class HubStore: ObservableObject {
    enum Trigger {
        case launch, poll, wake, network, popoverOpened, manual, settingsChanged

        /// Automatic refreshes respect the once-a-minute floor; ones you asked for start right away.
        var isAutomatic: Bool {
            switch self {
            case .poll, .wake, .network, .popoverOpened, .launch: return true
            case .manual, .settingsChanged: return false
            }
        }

        /// Shown as the notch's live activity: the refreshes you ask for, and the first one at launch.
        /// The hourly ones, and those on wake, when the network returns or when the panel opens, stay quiet.
        var showsActivity: Bool { !isAutomatic || self == .launch }
    }

    @Published private(set) var isRefreshing = false
    /// The notch shows the round running now as a live activity (`Trigger.showsActivity`).
    @Published private(set) var refreshShowsActivity = false
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var now = Date()

    let settings: AppSettings
    let notifier: Notifier
    let groups: [TabGroup]
    private(set) var tabs: [TabState] = []
    private var consecutiveFailures = 0
    private var lastAttempt: Date?
    private var pollTimer: Timer?
    private var deferredTimer: Timer?
    private var minuteTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private let pathMonitor = NWPathMonitor()
    private var networkWasDown = false
    private var refreshAgain = false
    private var refreshAgainShowsActivity = false

    init(settings: AppSettings? = nil, notifier: Notifier? = nil, registry: [MonitorTab] = MonitorRegistry.tabs,
         groups: [TabGroup] = MonitorRegistry.groups) {
        self.settings = settings ?? AppSettings()
        self.notifier = notifier ?? Notifier()
        self.groups = groups
        tabs = registry.map { TabState(tab: $0, store: self) }
        if !tabs.contains(where: { $0.id == self.settings.selectedTab }) { self.settings.selectedTab = tabs.first?.id ?? "" }
        let saved = self.settings.selectedTab
        // A tab picked before it joined a group opens its group instead.
        if groups.contains(where: { $0.members.contains(saved) && $0.id != saved }) { select(tabID: saved) }
        for tab in tabs {
            tab.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        }
        // A tab switched back on loads straight away; one switched off just drops out.
        self.settings.$hiddenTabs.dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.refresh(.settingsChanged)
            }
            .store(in: &cancellables)
    }

    /// The tabs switched on in Settings, in tab-strip order. Only these are shown and refreshed.
    var visibleTabs: [TabState] {
        let ids = Set(TabVisibility.visible(tabs.map(\.id), hidden: settings.hiddenTabs))
        return tabs.filter { ids.contains($0.id) }
    }

    /// The tab strip: the visible tabs, with each group's members in one entry.
    var stripEntries: [StripEntry] {
        let visible = visibleTabs
        return TabGroups.entries(visible: visible.map(\.id), groups: groups).map { entry in
            let members = entry.members.compactMap { id in visible.first { $0.id == id } }
            return StripEntry(id: entry.id, title: entry.title ?? members.first?.title ?? entry.id, members: members, isGroup: entry.isGroup)
        }
    }

    /// Picks the entry that shows `tabID`.
    func select(tabID: String) {
        settings.selectedTab = TabGroups.entryID(for: tabID, groups: groups)
    }

    /// The picked entry. A saved member of a group picks its group's.
    var selectedEntry: StripEntry? {
        let entries = stripEntries
        let id = TabGroups.entryID(for: settings.selectedTab, groups: groups)
        return entries.first { $0.id == id } ?? entries.first
    }

    var badge: HubBadge? {
        let visible = visibleTabs
        return HubBadge.make(snapshots: visible.map(\.snapshot), problems: visible.map(\.problem))
    }

    var failingCount: Int { visibleTabs.reduce(0) { $0 + ($1.snapshot?.failingCount ?? 0) } }

    func start() {
        notifier.requestAuthorization()
        settings.$refreshMinutes.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.scheduleNextPoll() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(.wake) }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(satisfied: satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "local.devhub.network"))

        let minute = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.minuteTick() }
        }
        minute.tolerance = 5
        RunLoop.main.add(minute, forMode: .common)
        minuteTimer = minute

        refresh(.launch)
    }

    func stop() {
        pollTimer?.invalidate()
        deferredTimer?.invalidate()
        minuteTimer?.invalidate()
        pathMonitor.cancel()
    }

    func refresh(_ trigger: Trigger) {
        let current = Date()
        if trigger == .popoverOpened, !RefreshSchedule.isStale(lastSuccess: lastRefreshed, now: current) { return }
        guard !isRefreshing else {
            if !trigger.isAutomatic { refreshAgain = true }
            if trigger.showsActivity {
                refreshAgainShowsActivity = refreshAgain
                refreshShowsActivity = true
            }
            return
        }

        if trigger.isAutomatic {
            let delay = RefreshSchedule.delayBeforeFetch(lastAttempt: lastAttempt, now: current)
            if delay > 0 {
                deferRefresh(by: delay)
                return
            }
        }
        performRefresh(showsActivity: trigger.showsActivity)
    }

    /// Refreshes one tab on its own, for a tab whose own action changed what it reads. Skips
    /// notifications, so only use it for tabs that never send any.
    func refresh(tab: TabState) {
        guard !tab.isRefreshing else { return }
        let monitor = tab.tab.make(settings.defaults)
        tab.isRefreshing = true
        Task {
            let result: Result<MonitorSnapshot, Error>
            do { result = .success(try await monitor.refresh()) } catch { result = .failure(error) }
            tab.isRefreshing = false
            tab.apply(result)
        }
    }

    private func networkChanged(satisfied: Bool) {
        if !satisfied {
            networkWasDown = true
        } else if networkWasDown {
            networkWasDown = false
            refresh(.network)
        }
    }

    /// Every visible tab refreshes concurrently; each keeps its last good data when its own refresh fails.
    private func performRefresh(showsActivity: Bool) {
        deferredTimer?.invalidate()
        deferredTimer = nil
        refreshShowsActivity = showsActivity
        isRefreshing = true
        lastAttempt = Date()
        let defaults = settings.defaults
        let tabs = visibleTabs
        let monitors = tabs.map { $0.tab.make(defaults) }
        for tab in tabs { tab.isRefreshing = true }

        Task {
            defer {
                isRefreshing = false
                if refreshAgain {
                    let showsActivity = refreshAgainShowsActivity
                    refreshAgain = false
                    refreshAgainShowsActivity = false
                    performRefresh(showsActivity: showsActivity)
                } else {
                    scheduleNextPoll()
                }
            }
            var anyFailed = false
            await withTaskGroup(of: (Int, Result<MonitorSnapshot, Error>).self) { group in
                for (index, monitor) in monitors.enumerated() {
                    group.addTask {
                        do { return (index, .success(try await monitor.refresh())) } catch { return (index, .failure(error)) }
                    }
                }
                for await (index, result) in group {
                    let tab = tabs[index]
                    tab.isRefreshing = false
                    tab.apply(result)
                    if case .success(let snapshot) = result {
                        notifier.handleRefresh(tabID: tab.id, title: tab.title, snapshot: snapshot, settings: settings)
                    } else {
                        anyFailed = true
                    }
                }
            }
            consecutiveFailures = anyFailed ? consecutiveFailures + 1 : 0
            lastRefreshed = Date()
            now = Date()
            checkMorning()
        }
    }

    private func minuteTick() {
        now = Date()
        checkMorning()
    }

    /// The morning summary goes out on states from a refresh in the last 15 minutes; otherwise it
    /// asks for one and the refresh sends it.
    private func checkMorning() {
        guard notifier.isMorningDue(settings: settings, now: now) else { return }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < RefreshSchedule.staleAfter, !isRefreshing {
            notifier.sendMorning(lines: visibleTabs.map(\.line), settings: settings, now: now)
        } else {
            refresh(.poll)
        }
    }

    func sendTestNotification() {
        notifier.sendTest(lines: visibleTabs.map(\.line))
    }

    private func scheduleNextPoll() {
        pollTimer?.invalidate()
        let interval = RefreshSchedule.interval(baseMinutes: settings.refreshMinutes, consecutiveFailures: consecutiveFailures)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(.poll) }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func deferRefresh(by delay: TimeInterval) {
        guard deferredTimer == nil else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deferredTimer = nil
                self?.refresh(.poll)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        deferredTimer = timer
    }

    func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One button in the tab strip: a tab, or a group of tabs shown together.
struct StripEntry: Identifiable {
    let id: String
    let title: String
    /// The visible tabs it shows, in the group's order.
    let members: [TabState]
    let isGroup: Bool
}
