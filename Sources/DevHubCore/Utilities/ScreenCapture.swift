import Foundation

/// macOS's Screenshot tool, the ⌘⇧5 toolbar. It takes screenshots and records the screen itself,
/// with its own permission, so Dev Hub only opens it.
public enum ScreenshotTool {
    static let open = URL(fileURLWithPath: "/usr/bin/open")

    /// The toolbar's timer choices, in seconds.
    public static let delays = [0, 5, 10]

    public static func launch() async throws {
        try await Shell.check(open, ["-a", "Screenshot"])
    }
}
