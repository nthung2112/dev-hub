import Foundation

public enum RefreshSchedule {
    public static let intervalRange = 15...240
    public static let defaultMinutes = 60
    /// Never fetch more often than this, whatever triggered the refresh.
    public static let minimumSpacing: TimeInterval = 60
    public static let maximumInterval: TimeInterval = 240 * 60
    /// Opening the popover refreshes data older than this.
    public static let staleAfter: TimeInterval = 15 * 60

    public static func clampMinutes(_ minutes: Int) -> Int {
        min(max(minutes, intervalRange.lowerBound), intervalRange.upperBound)
    }

    /// The poll interval, doubling after each consecutive failure up to 4 hours.
    public static func interval(baseMinutes: Int, consecutiveFailures: Int) -> TimeInterval {
        let base = TimeInterval(clampMinutes(baseMinutes) * 60)
        let factor = pow(2, Double(min(max(consecutiveFailures, 0), 10)))
        return max(minimumSpacing, min(base * factor, max(base, maximumInterval)))
    }

    /// How long to wait before a fetch is allowed; zero when one may start now.
    public static func delayBeforeFetch(lastAttempt: Date?, now: Date) -> TimeInterval {
        guard let lastAttempt else { return 0 }
        return max(0, minimumSpacing - now.timeIntervalSince(lastAttempt))
    }

    public static func isStale(lastSuccess: Date?, now: Date) -> Bool {
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) > staleAfter
    }
}
