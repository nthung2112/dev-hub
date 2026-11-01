import Foundation

/// A Pomodoro: focus, then a short break, with a long break after every `roundsBeforeLongBreak` focus rounds.
public enum PomodoroPhase: String, Codable, Sendable, CaseIterable {
    case focus, shortBreak, longBreak

    public var title: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Short break"
        case .longBreak: return "Long break"
        }
    }

    public var isBreak: Bool { self != .focus }
}

/// The lengths, in minutes, chosen in the Mac tab.
public struct PomodoroPlan: Codable, Equatable, Sendable {
    public var focusMinutes: Int
    public var shortBreakMinutes: Int
    public var longBreakMinutes: Int
    public var roundsBeforeLongBreak: Int

    public static let standard = PomodoroPlan(focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, roundsBeforeLongBreak: 4)
    public static let focusChoices = [15, 20, 25, 30, 45, 50, 60]
    public static let shortBreakChoices = [3, 5, 10, 15]
    public static let longBreakChoices = [10, 15, 20, 30]

    public init(focusMinutes: Int, shortBreakMinutes: Int, longBreakMinutes: Int, roundsBeforeLongBreak: Int) {
        self.focusMinutes = focusMinutes
        self.shortBreakMinutes = shortBreakMinutes
        self.longBreakMinutes = longBreakMinutes
        self.roundsBeforeLongBreak = roundsBeforeLongBreak
    }

    public func length(of phase: PomodoroPhase) -> TimeInterval {
        let minutes: Int
        switch phase {
        case .focus: minutes = focusMinutes
        case .shortBreak: minutes = shortBreakMinutes
        case .longBreak: minutes = longBreakMinutes
        }
        return TimeInterval(max(1, minutes) * 60)
    }
}

/// A Pomodoro in progress. Running, it has `endsAt`; paused, it keeps what was left in `pausedRemaining`.
public struct PomodoroState: Codable, Equatable, Sendable {
    public var phase: PomodoroPhase
    /// Focus rounds finished in this cycle, before the current phase.
    public var completedFocus: Int
    /// How long the current phase is in all, for the progress ring.
    public var length: TimeInterval
    public var endsAt: Date?
    public var pausedRemaining: TimeInterval?

    public init(phase: PomodoroPhase, completedFocus: Int, length: TimeInterval, endsAt: Date?, pausedRemaining: TimeInterval?) {
        self.phase = phase
        self.completedFocus = completedFocus
        self.length = length
        self.endsAt = endsAt
        self.pausedRemaining = pausedRemaining
    }

    public var isPaused: Bool { endsAt == nil }

    public func remaining(at now: Date) -> TimeInterval {
        if let endsAt { return max(0, endsAt.timeIntervalSince(now)) }
        return max(0, pausedRemaining ?? length)
    }

    /// 0 when the phase starts, 1 when it's over.
    public func fraction(at now: Date) -> Double {
        guard length > 0 else { return 1 }
        return min(1, max(0, 1 - remaining(at: now) / length))
    }

    public func isOver(at now: Date) -> Bool {
        guard let endsAt else { return false }
        return endsAt <= now
    }

    /// `Focus · round 2 of 4`, `Short break`, `Long break`.
    public func title(plan: PomodoroPlan) -> String {
        guard phase == .focus else { return phase.title }
        let round = completedFocus % max(1, plan.roundsBeforeLongBreak) + 1
        return "Focus · round \(round) of \(plan.roundsBeforeLongBreak)"
    }
}

public enum Pomodoro {
    public static func start(_ phase: PomodoroPhase = .focus, completedFocus: Int = 0, plan: PomodoroPlan, now: Date) -> PomodoroState {
        let length = plan.length(of: phase)
        return PomodoroState(phase: phase, completedFocus: completedFocus, length: length,
                             endsAt: now.addingTimeInterval(length), pausedRemaining: nil)
    }

    public static func pause(_ state: PomodoroState, now: Date) -> PomodoroState {
        guard !state.isPaused else { return state }
        var paused = state
        paused.pausedRemaining = state.remaining(at: now)
        paused.endsAt = nil
        return paused
    }

    public static func resume(_ state: PomodoroState, now: Date) -> PomodoroState {
        guard state.isPaused else { return state }
        var running = state
        running.endsAt = now.addingTimeInterval(state.remaining(at: now))
        running.pausedRemaining = nil
        return running
    }

    /// What follows `state` when it ends or is skipped. A focus round leads to a break, which starts at
    /// once; a break ends the cycle step, and the next focus round waits for you (nil).
    public static func next(after state: PomodoroState, plan: PomodoroPlan, now: Date) -> PomodoroState? {
        switch state.phase {
        case .focus:
            let done = state.completedFocus + 1
            let long = done % max(1, plan.roundsBeforeLongBreak) == 0
            return start(long ? .longBreak : .shortBreak, completedFocus: done, plan: plan, now: now)
        case .shortBreak, .longBreak:
            return nil
        }
    }

    /// The banner when `phase` ends.
    public static func banner(ending phase: PomodoroPhase, next: PomodoroState?) -> (title: String, body: String) {
        switch phase {
        case .focus:
            let minutes = Int(((next?.length ?? 0) / 60).rounded())
            return ("Focus done", "Time for a \(next?.phase == .longBreak ? "long " : "")break: \(minutes) min.")
        case .shortBreak, .longBreak:
            return ("Break's over", "Start the next focus round when you're ready.")
        }
    }

    /// The focus round that follows a break you finished or skipped.
    public static func focusAfterBreak(completedFocus: Int, plan: PomodoroPlan, now: Date) -> PomodoroState {
        start(.focus, completedFocus: completedFocus, plan: plan, now: now)
    }

    /// `24:13`, `1:05:00`.
    public static func clock(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.up))
        let hours = total / 3600, minutes = total / 60 % 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }
}

/// The Pomodoro's sounds, from the Mac's own system sounds: a chime when a focus round or a break ends,
/// a different one for each so you can tell them apart without looking, and a soft tick when one starts.
public enum PomodoroSound: Equatable, Sendable, CaseIterable {
    case started, focusDone, breakOver

    public static func ending(_ phase: PomodoroPhase) -> PomodoroSound {
        phase == .focus ? .focusDone : .breakOver
    }

    /// A sound in `/System/Library/Sounds`, found by `NSSound(named:)`.
    public var systemName: String {
        switch self {
        case .started: return "Tink"
        case .focusDone: return "Glass"
        case .breakOver: return "Hero"
        }
    }

    public var volume: Float { self == .started ? 0.45 : 1 }
}

extension UtilitiesSettings {
    /// Whether the Pomodoro plays its sounds; on unless switched off.
    public static let pomodoroSoundsKey = "utilities.pomodoro.sounds"
    /// The Pomodoro lengths, as JSON `PomodoroPlan`.
    public static let pomodoroPlanKey = "utilities.pomodoro.plan"
    /// The Pomodoro running or paused, as JSON `PomodoroState`, so it carries on after a restart.
    public static let pomodoroStateKey = "utilities.pomodoro.state"
    /// Focus rounds finished in the cycle when the last break ended, for the next round's number.
    public static let pomodoroRoundsKey = "utilities.pomodoro.rounds"
}
