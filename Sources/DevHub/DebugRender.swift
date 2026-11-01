import AppKit
import SwiftUI
import DevHubCore

/// `DevHub --render <png> [tab] [--settings] [--dark]`: refreshes every tab, then draws the panel offscreen to a
/// PNG, for checking the layout without opening the menu bar item. With `--settings`, a tab opens its settings
/// page and no tab opens General. Banners and last-seen state are left alone.
@MainActor
enum DebugRender {
    static func run(arguments: [String]) {
        let rest = Array(arguments.drop { $0 != "--render" }.dropFirst())
        guard let path = rest.first, !path.hasPrefix("-") else {
            FileHandle.standardError.write(Data("devhub: --render needs an output path\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("devhub-render-last-seen.json")
        let store = HubStore(notifier: Notifier(stateURL: scratch))
        let tab = rest.dropFirst().first(where: { !$0.hasPrefix("-") })
        if let tab { store.select(tabID: tab) }
        store.refresh(.manual)

        Task { @MainActor in
            while store.isRefreshing { try? await Task.sleep(for: .milliseconds(200)) }
            let view = HubView(store: store, settings: store.settings, showSettings: rest.contains("--settings"),
                               settingsPage: tab ?? SettingsView.generalPage)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: rest.contains("--dark") ? .darkAqua : .aqua)
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            do {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("Rendered \(path) (\(Int(host.bounds.width))×\(Int(host.bounds.height)))")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("devhub: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }
}
