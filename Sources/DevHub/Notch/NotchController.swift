import AppKit
import Combine
import DevHubCore
import SwiftUI

/// A connected screen, named the way Settings shows it.
enum NotchScreens {
    static func info(_ screen: NSScreen) -> NotchDisplay {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let uuid = number.flatMap { CGDisplayCreateUUIDFromDisplayID($0.uint32Value)?.takeRetainedValue() }
            .flatMap { CFUUIDCreateString(nil, $0) as String? }
        return NotchDisplay(id: uuid ?? screen.localizedName, name: screen.localizedName)
    }

    static func closedSize(on screen: NSScreen) -> CGSize {
        NotchSizing.closedSize(
            screenWidth: screen.frame.width,
            leftAuxiliary: screen.auxiliaryTopLeftArea?.width,
            rightAuxiliary: screen.auxiliaryTopRightArea?.width,
            menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY,
            topSafeInset: screen.safeAreaInsets.top
        )
    }

    static func connected() -> [NotchDisplay] {
        NSScreen.screens.map(info)
    }
}

/// One notch: its panel and model on one display.
@MainActor
private struct Notch {
    let displayID: String
    var screen: NSScreen
    let panel: NotchPanel
    let model: NotchModel
    let openSubscription: AnyCancellable
}

/// Puts a notch on each chosen display and opens the panel from it.
@MainActor
final class NotchController {
    private let store: HubStore
    private let settings: AppSettings
    private var notches: [Notch] = []
    private var cancellables: Set<AnyCancellable> = []
    private var monitors: [Any] = []
    private var menuTracking = 0
    private var pointerWasInside: [ObjectIdentifier: Bool] = [:]
    private var autoCloseTask: Task<Void, Never>?
    private var compactRecheckTask: Task<Void, Never>?

    private let activity: NotchActivityFeed

    init(store: HubStore) {
        self.store = store
        settings = store.settings
        activity = NotchActivityFeed(store: store)
    }

    func start() {
        rebuild()
        settings.$notchDisplay.dropFirst()
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        Publishers.Merge3(
            settings.$opensOnHover.dropFirst().map { _ in () },
            settings.$hoverDelay.dropFirst().map { _ in () },
            settings.$showsAlerts.dropFirst().map { _ in () }
        )
        .sink { [weak self] _ in self?.applyBehaviour() }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.screensChanged() }
            .store(in: &cancellables)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.activeSpaceDidChange() }
            .store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in self?.updateCompact() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in self?.menuBegan() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { [weak self] _ in self?.menuEnded() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .devHubClosePopover)
            .sink { [weak self] _ in self?.closeAll() }
            .store(in: &cancellables)

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask.union([.leftMouseDown, .rightMouseDown]), handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask.union([.leftMouseDown, .rightMouseDown]), handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(monitor)
        }
        syncPointer()
    }

    /// Settings in the menu bar opens the notch on the General page.
    func openSettings() {
        guard let notch = notches.first else { return }
        notch.model.presentSettings = true
        notch.model.wantsKey = true
        notch.model.isOpen = true
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .devHubShowSettings, object: nil)
        }
    }

    /// Opening the app while it is already running shows the notch, then closes it if the pointer stays away.
    func revealBriefly() {
        guard let notch = notches.first else { return }
        notch.model.wantsKey = true
        notch.model.isOpen = true
        autoCloseTask?.cancel()
        autoCloseTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            guard !Self.pointerInside(notch, mouse: NSEvent.mouseLocation) else { return }
            notch.model.isOpen = false
        }
    }

    // MARK: Pointer

    private var holdsOpen: Bool {
        if menuTracking > 0 || NSApp.modalWindow != nil { return true }
        return notches.contains { notch in
            notch.panel.attachedSheet != nil || notch.panel.childWindows?.isEmpty == false
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            let mouse = NSEvent.mouseLocation
            for notch in notches where notch.model.isOpen && Self.pointerInside(notch, mouse: mouse) {
                notch.model.wantsKey = true
                focus(notch)
            }
            closeIfClickedOutside()
        }
        syncPointer()
    }

    /// The panel accepts clicks only on the drawn shape. The menu-bar icons beside an alert stay usable.
    private func syncPointer() {
        let mouse = NSEvent.mouseLocation
        let held = holdsOpen
        for notch in notches {
            let id = ObjectIdentifier(notch.panel)
            let inside = Self.pointerInside(notch, mouse: mouse)
            // A bubble takes clicks, to pick it, but resting on it doesn't open the panel.
            let onBubble = !notch.model.isOpen && Self.pointerOnBubble(notch, mouse: mouse)
            notch.panel.ignoresMouseEvents = held ? false : !(inside || onBubble)
            let was = pointerWasInside[id] ?? false
            guard inside != was else { continue }
            pointerWasInside[id] = inside
            if !held { notch.model.pointer(inside: inside) }
        }
    }

    private func closeIfClickedOutside() {
        guard !holdsOpen else { return }
        let mouse = NSEvent.mouseLocation
        for notch in notches where notch.model.isOpen {
            if Self.pointerInside(notch, mouse: mouse) { continue }
            if notch.panel.childWindows?.contains(where: { $0.frame.contains(mouse) }) == true { continue }
            notch.model.isOpen = false
            pointerWasInside[ObjectIdentifier(notch.panel)] = false
        }
    }

    private func closeAll() {
        for notch in notches { notch.model.isOpen = false }
    }

    private static func pointerOnBubble(_ notch: Notch, mouse: NSPoint) -> Bool {
        let frame = notch.panel.frame
        guard frame.contains(mouse) else { return false }
        let fromTop = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
        return notch.model.bubbleFrames.contains { $0.insetBy(dx: -2, dy: -2).contains(fromTop) }
    }

    private static func pointerInside(_ notch: Notch, mouse: NSPoint) -> Bool {
        let frame = notch.panel.frame
        guard frame.contains(mouse) else { return false }
        let fromTop = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
        let showsAlert = !notch.model.isOpen && notch.model.behaviour.showsAlerts && notch.model.store.badge != nil
        return NotchHit.contains(fromTop, panel: frame.size, visible: notch.model.visibleSize,
                                 closed: notch.model.closedSize, showsAlert: showsAlert)
    }

    private func menuBegan() {
        menuTracking += 1
        syncPointer()
    }

    private func menuEnded() {
        menuTracking = max(0, menuTracking - 1)
        guard menuTracking == 0 else { return }
        let mouse = NSEvent.mouseLocation
        for notch in notches {
            let inside = Self.pointerInside(notch, mouse: mouse)
            pointerWasInside[ObjectIdentifier(notch.panel)] = inside
            notch.panel.ignoresMouseEvents = !inside
            notch.model.pointer(inside: inside)
        }
    }

    // MARK: Notches

    private func applyBehaviour() {
        let behaviour = NotchBehaviour(opensOnHover: settings.opensOnHover,
                                       hoverDelay: settings.hoverDelay.seconds,
                                       showsAlerts: settings.showsAlerts)
        for notch in notches { notch.model.behaviour = behaviour }
        syncPointer()
    }

    private func screensChanged() {
        let screens = NSScreen.screens
        let displays = screens.map(NotchScreens.info)
        let wanted = settings.notchDisplay.resolve(among: displays).map(\.id)
        guard wanted == notches.map(\.displayID) else {
            rebuild()
            return
        }
        for index in notches.indices {
            guard let at = displays.firstIndex(where: { $0.id == notches[index].displayID }) else { continue }
            notches[index].screen = screens[at]
            place(notches[index].panel, notches[index].model, on: screens[at])
        }
        updateCompact()
        syncPointer()
    }

    /// Sizes the notch for its screen and puts its panel at the top centre.
    private func place(_ panel: NotchPanel, _ model: NotchModel, on screen: NSScreen) {
        model.screenLimit = screen.visibleFrame.size
        model.closedSize = NotchScreens.closedSize(on: screen)
        let size = model.panelSize
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height),
                       display: true)
    }

    private func rebuild() {
        for notch in notches { notch.panel.orderOut(nil) }
        notches = []
        pointerWasInside.removeAll()
        let screens = NSScreen.screens
        let displays = screens.map(NotchScreens.info)
        let choice = settings.notchDisplay
        for display in choice.resolve(among: displays) {
            guard let index = displays.firstIndex(of: display) else { continue }
            let screen = screens[index]
            let model = NotchModel(store: store, settings: settings, activity: activity)
            model.behaviour = NotchBehaviour(opensOnHover: settings.opensOnHover,
                                             hoverDelay: settings.hoverDelay.seconds,
                                             showsAlerts: settings.showsAlerts)
            model.allowsHoverClose = { [weak self] in self?.holdsOpen == false }
            model.onGeometryChange = { [weak self] in self?.syncPointer() }
            let panel = NotchPanel(size: model.panelSize)
            let host = NotchHostingView(rootView: NotchView(model: model))
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = host
            place(panel, model, on: screen)
            panel.orderFrontRegardless()
            let openSubscription = model.$isOpen.dropFirst().sink { [weak self, weak model] isOpen in
                guard let self, let model else { return }
                if isOpen {
                    for other in self.notches where other.model !== model && other.model.isOpen {
                        other.model.isOpen = false
                    }
                }
                self.note(model, isOpen: isOpen)
            }
            notches.append(Notch(displayID: display.id, screen: screen, panel: panel, model: model,
                                 openSubscription: openSubscription))
        }
        updateCompact()
        syncPointer()
    }

    /// A click or Settings makes the panel key. Hovering leaves the app in use with the keyboard.
    private func focus(_ notch: Notch) {
        notch.model.wantsKey = false
        notch.panel.allowsKey = true
        NSApp.activate(ignoringOtherApps: true)
        notch.panel.makeKey()
    }

    /// Opening refreshes stale tabs. The panel takes the keyboard when `wantsKey` is set.
    private func note(_ model: NotchModel, isOpen: Bool) {
        guard let notch = notches.first(where: { $0.model === model }) else { return }
        if isOpen {
            notch.panel.allowsKey = true
            if model.wantsKey { focus(notch) }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard model.isOpen else { return }
                self?.store.refresh(.popoverOpened)
            }
        } else {
            notch.panel.allowsKey = false
            notch.model.presentSettings = false
            if notch.panel.isKeyWindow { notch.panel.resignKey() }
        }
        syncPointer()
    }

    /// Checks at once and again 0.5 s later: the window list can still show the old Space when the change is posted.
    private func activeSpaceDidChange() {
        updateCompact()
        compactRecheckTask?.cancel()
        compactRecheckTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            updateCompact()
        }
    }

    /// Draws each notch's alert on one line while the front app on its screen is full screen.
    private func updateCompact() {
        guard let primary = NSScreen.screens.first, !notches.isEmpty else { return }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = FullScreenCheck.windows(from: list)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let systemSaysFullScreen = !NSApp.currentSystemPresentationOptions.isDisjoint(with: [.fullScreen, .autoHideMenuBar, .hideMenuBar])
        for notch in notches {
            let screen = notch.screen
            let frame = CGRect(x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY,
                               width: screen.frame.width, height: screen.frame.height)
            let compact = FullScreenCheck.isFullScreen(windows, screen: frame, topInset: screen.safeAreaInsets.top,
                                                       frontmostPID: frontmost, systemSaysFullScreen: systemSaysFullScreen)
            if notch.model.isCompact != compact { notch.model.isCompact = compact }
        }
    }
}
