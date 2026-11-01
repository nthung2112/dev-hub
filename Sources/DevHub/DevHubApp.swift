import AppKit
import DevHubCore

@main
enum DevHubMain {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--dump") {
            Task { exit(await DebugDump.run(arguments: arguments)) }
            dispatchMain()
        }
        if arguments.contains("--render") {
            MainActor.assumeIsolated { DebugRender.run(arguments: arguments) }
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: HubStore?
    private var notch: NotchController?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.editMenu()
        let store = HubStore()
        PomodoroController.shared.attach(defaults: store.settings.defaults) { [weak store] title, body, withSound in
            store?.notifier.send(title: title, body: body, id: "pomodoro", sound: withSound)
        }
        let notch = NotchController(store: store)
        statusItem = StatusItemController(settings: store.settings, openSettings: { [weak notch] in
            notch?.openSettings()
        })
        notch.start()
        self.notch = notch
        self.store = store
        store.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        notch?.revealBriefly()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
        CaffeinateController.shared.stop()
        DisplayController.shared.restore()    }

    /// A menu bar app shows no menu bar, but text fields only get ⌘X/⌘C/⌘V/⌘A/⌘Z through an Edit menu.
    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Dev Hub", action: nil, keyEquivalent: ""))
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
