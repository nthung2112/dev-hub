import Foundation

/// What the closed notch shows beside the camera while something you asked for runs, like a Live Activity
/// in the Dynamic Island: an indicator on the left of the cutout and a short line on the right.
public enum NotchActivity: Equatable, Sendable {
    /// A refresh you started: `done` of `total` tabs have answered.
    case refreshing(done: Int, total: Int)
    /// It finished; `failed` tabs had a failed refresh.
    case refreshed(failed: Int)
    /// Keep Awake is on, until `endsAt` or, when nil, until it's stopped. It stays for as long as it runs;
    /// a refresh you start takes its place until that refresh has finished.
    case keepingAwake(endsAt: Date?)
    /// A Pomodoro focus round or break, running or paused.
    case pomodoro(PomodoroState)

    /// How long the finished state stays before the notch shrinks back.
    public static let finishedHold: TimeInterval = 1.8

    /// `3/11`, `Done`, `2 failed`, `Awake`. A timed Keep Awake draws a countdown instead.
    public var trailing: String {
        switch self {
        case let .refreshing(done, total): return "\(min(done, total))/\(total)"
        case let .refreshed(failed): return failed == 0 ? "Done" : "\(failed) failed"
        case .keepingAwake: return "Awake"
        case let .pomodoro(state): return Pomodoro.clock(state.remaining(at: Date()))
        }
    }

    /// Which activity this is, whatever state it's in; a refresh that finished is still the refresh.
    public enum Kind: String, Sendable, CaseIterable {
        case refresh, pomodoro, keepAwake
    }

    public var kind: Kind {
        switch self {
        case .refreshing, .refreshed: return .refresh
        case .pomodoro: return .pomodoro
        case .keepingAwake: return .keepAwake
        }
    }

    /// Everything running, most important first: a refresh while it runs or has just finished, then a
    /// Pomodoro, then Keep Awake.
    public static func all(refresh: NotchActivity?, pomodoro: PomodoroState? = nil,
                           awake: KeepAwakeState?) -> [NotchActivity] {
        [refresh, pomodoro.map { .pomodoro($0) }, awake.map { .keepingAwake(endsAt: $0.endsAt) }].compactMap { $0 }
    }

    /// The one in the ears when nothing is picked.
    public static func showing(refresh: NotchActivity?, pomodoro: PomodoroState? = nil,
                               awake: KeepAwakeState?) -> NotchActivity? {
        all(refresh: refresh, pomodoro: pomodoro, awake: awake).first
    }

    /// How far along it is, for a progress ring; nil once finished.
    public var fraction: Double? {
        guard case let .refreshing(done, total) = self, total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }

    public var accessibilityLabel: String {
        switch self {
        case let .refreshing(done, total): return "Refreshing, \(min(done, total)) of \(total) tabs done"
        case let .refreshed(failed):
            return failed == 0 ? "Refreshed" : "Refreshed, \(failed) tab\(failed == 1 ? "" : "s") need attention"
        case let .keepingAwake(endsAt):
            return KeepAwakeState(startedAt: Date(), endsAt: endsAt).line
        case let .pomodoro(state):
            let left = "\(Pomodoro.clock(state.remaining(at: Date()))) left"
            return "\(state.phase.title)\(state.isPaused ? ", paused" : ""), \(left)"
        }
    }
}

/// Several activities at once, as the Dynamic Island shows them: one in the ears beside the camera and the
/// rest as small bubbles to its right. Clicking a bubble picks it for the ears; it stays there until it ends.
public struct NotchActivityArrangement: Equatable, Sendable {
    public var primary: NotchActivity?
    public var bubbles: [NotchActivity]

    /// Bubbles beyond this many aren't shown; with three kinds of activity it's never reached today.
    public static let maxBubbles = 2

    public init(primary: NotchActivity? = nil, bubbles: [NotchActivity] = []) {
        self.primary = primary
        self.bubbles = bubbles
    }

    /// `activities` most important first. The picked kind takes the ears while it runs; the rest keep their order.
    public static func arrange(_ activities: [NotchActivity], picked: NotchActivity.Kind?) -> NotchActivityArrangement {
        guard !activities.isEmpty else { return NotchActivityArrangement() }
        let primaryIndex = picked.flatMap { kind in activities.firstIndex { $0.kind == kind } } ?? 0
        var rest = activities
        let primary = rest.remove(at: primaryIndex)
        return NotchActivityArrangement(primary: primary, bubbles: Array(rest.prefix(maxBubbles)))
    }

    /// Which activity is where, without their changing numbers; a change here is a swap worth animating.
    public var layout: [NotchActivity.Kind] {
        (primary.map { [$0.kind] } ?? []) + bubbles.map(\.kind)
    }
}
