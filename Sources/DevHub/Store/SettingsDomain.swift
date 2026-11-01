import Foundation

/// Settings live in the `local.devhub` domain whether the app runs as the bundle or via `swift run`.
enum SettingsDomain {
    static let bundleIdentifier = "local.devhub"

    static var defaults: UserDefaults {
        if Bundle.main.bundleIdentifier == bundleIdentifier { return .standard }
        return UserDefaults(suiteName: bundleIdentifier) ?? .standard
    }
}
