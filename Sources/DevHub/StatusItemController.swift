import AppKit

extension Notification.Name {
    /// Closes the panel, e.g. so it isn't in a screenshot.
    static let devHubClosePopover = Notification.Name("local.devhub.closePopover")
    /// Opens Settings in a notch that is already open.
    static let devHubShowSettings = Notification.Name("local.devhub.showSettings")
}

/// The menu bar icon opens a menu. The panel itself lives on the notch.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let settings: AppSettings
    private let openSettings: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var alertsItem: NSMenuItem?
    private var loginItem: NSMenuItem?

    init(settings: AppSettings, openSettings: @escaping () -> Void) {
        self.settings = settings
        self.openSettings = openSettings
        super.init()

        let item = statusItem
        item.button?.image = Self.icon
        item.button?.toolTip = "Dev Hub"
        let menu = NSMenu()
        menu.delegate = self
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let alerts = NSMenuItem(title: "Show Alerts on the Notch", action: #selector(toggleAlerts(_:)), keyEquivalent: "")
        alerts.target = self
        menu.addItem(alerts)
        alertsItem = alerts
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        loginItem = login
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dev Hub", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        alertsItem?.state = settings.showsAlerts ? .on : .off
        loginItem?.state = settings.launchAtLogin ? .on : .off
    }

    @objc private func showSettings(_ sender: Any?) {
        openSettings()
    }

    @objc private func toggleAlerts(_ sender: NSMenuItem) {
        settings.showsAlerts.toggle()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        settings.setLaunchAtLogin(!settings.launchAtLogin)
    }

    /// The app icon, cropped into the menu bar slot. An SF Symbol stands in for `swift run`.
    private static var icon: NSImage? {
        guard let icon = Bundle.main.image(forResource: "AppIcon") else {
            let symbol = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Dev Hub")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
            symbol?.isTemplate = true
            return symbol
        }
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let source = NSRect(origin: .zero, size: icon.size).insetBy(dx: icon.size.width * 0.08, dy: icon.size.height * 0.08)
            icon.draw(in: rect, from: source, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Dev Hub"
        return image
    }
}
