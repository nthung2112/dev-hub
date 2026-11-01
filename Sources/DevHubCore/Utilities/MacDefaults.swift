import Foundation

/// macOS settings read and written through `/usr/bin/defaults`, plus the restarts that apply them.
/// Everything here runs as the signed-in user: none of it needs admin rights.
public enum MacDefaults {
    static let defaults = URL(fileURLWithPath: "/usr/bin/defaults")
    static let killall = URL(fileURLWithPath: "/usr/bin/killall")

    public static let finder = "com.apple.finder"
    public static let screencapture = "com.apple.screencapture"
    public static let global = "-g"

    /// Screenshot formats `screencapture` can save.
    public static let screenshotTypes = ["png", "jpg", "pdf", "heic", "tiff"]

    // MARK: Reading

    /// `1`, `true` or `YES` is on; `0`, `false` or `NO` is off; a missing key is nil.
    static func parseBool(_ result: ShellResult) -> Bool? {
        guard result.succeeded else { return nil }
        switch result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }

    /// The trimmed value, nil when the key is missing or empty.
    static func parseString(_ result: ShellResult) -> String? {
        guard result.succeeded else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public static func readBool(_ domain: String, _ key: String) async -> Bool? {
        (try? await Shell.run(defaults, ["read", domain, key])).flatMap(parseBool)
    }

    public static func readString(_ domain: String, _ key: String) async -> String? {
        (try? await Shell.run(defaults, ["read", domain, key])).flatMap(parseString)
    }

    // MARK: Writing

    public static func writeBool(_ domain: String, _ key: String, _ value: Bool) async throws {
        try await Shell.check(defaults, ["write", domain, key, "-bool", value ? "true" : "false"])
    }

    public static func writeString(_ domain: String, _ key: String, _ value: String) async throws {
        try await Shell.check(defaults, ["write", domain, key, "-string", value])
    }

    /// Quits `process` so macOS relaunches it with the new settings. Finder, Dock and
    /// SystemUIServer come straight back.
    public static func restart(_ process: String) async throws {
        try await Shell.check(killall, [process])
    }

    // MARK: Finder

    public static func setShowHiddenFiles(_ on: Bool) async throws {
        try await writeBool(finder, "AppleShowAllFiles", on)
        try? await restart("Finder")
    }

    public static func setHideDesktopIcons(_ hide: Bool) async throws {
        try await writeBool(finder, "CreateDesktop", !hide)
        try? await restart("Finder")
    }

    public static func setShowAllExtensions(_ on: Bool) async throws {
        try await writeBool(global, "AppleShowAllExtensions", on)
        try? await restart("Finder")
    }

    // MARK: Screenshots

    /// `~/Documents/` as `defaults` stores it, expanded to a full path.
    public static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    public static func setScreenshotLocation(_ folder: URL) async throws {
        try await writeString(screencapture, "location", folder.path)
        try await writeString(screencapture, "target", "file")
        try? await restart("SystemUIServer")
    }

    public static func setScreenshotsToClipboard() async throws {
        try await writeString(screencapture, "target", "clipboard")
        try? await restart("SystemUIServer")
    }

    public static func setWindowShadow(_ on: Bool) async throws {
        try await writeBool(screencapture, "disable-shadow", !on)
        try? await restart("SystemUIServer")
    }

    public static func setShowThumbnail(_ on: Bool) async throws {
        try await writeBool(screencapture, "show-thumbnail", on)
        try? await restart("SystemUIServer")
    }

    /// The Screenshot tool's timer: 0, 5 or 10 seconds.
    public static func setCaptureDelay(_ seconds: Int) async throws {
        guard ScreenshotTool.delays.contains(seconds) else { return }
        try await Shell.check(defaults, ["write", screencapture, "captureDelay", "-int", String(seconds)])
    }

    public static func setScreenshotType(_ type: String) async throws {
        guard screenshotTypes.contains(type) else { return }
        try await writeString(screencapture, "type", type)
        try? await restart("SystemUIServer")
    }
}
