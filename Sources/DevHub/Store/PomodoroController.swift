import AppKit
import DevHubCore

/// The one Pomodoro Dev Hub runs. It carries on after a restart, sends a banner when a focus round or
/// break ends, and starts the break by itself; the next focus round waits for you.
@MainActor
final class PomodoroController: ObservableObject {
    static let shared = PomodoroController()

    @Published private(set) var state: PomodoroState?
    @Published var plan: PomodoroPlan = .standard {
        didSet { if plan != oldValue { save(plan, UtilitiesSettings.pomodoroPlanKey) } }
    }
    /// Focus rounds finished in the cycle, for the next round's number once a break is over.
    @Published private(set) var completedFocus = 0
    /// The chimes and the start tick. With them on, the banner stays silent so the two don't overlap.
    @Published var soundsOn = true {
        didSet { if soundsOn != oldValue { defaults?.set(soundsOn, forKey: UtilitiesSettings.pomodoroSoundsKey) } }
    }

    private var defaults: UserDefaults?
    private var notify: (_ title: String, _ body: String, _ withSound: Bool) -> Void = { _, _, _ in }
    private var timer: Task<Void, Never>?
    /// Kept while they play; a released `NSSound` stops.
    private var sounds: [PomodoroSound: NSSound] = [:]

    /// Loads what was running before Dev Hub last quit. A phase that ended meanwhile moves on now.
    func attach(defaults: UserDefaults, notify: @escaping (_ title: String, _ body: String, _ withSound: Bool) -> Void) {
        self.defaults = defaults
        self.notify = notify
        plan = load(PomodoroPlan.self, UtilitiesSettings.pomodoroPlanKey) ?? .standard
        completedFocus = defaults.integer(forKey: UtilitiesSettings.pomodoroRoundsKey)
        soundsOn = defaults.object(forKey: UtilitiesSettings.pomodoroSoundsKey) as? Bool ?? true
        state = load(PomodoroState.self, UtilitiesSettings.pomodoroStateKey)
        schedule()
    }

    func start() {
        set(Pomodoro.start(.focus, completedFocus: completedFocus, plan: plan, now: Date()))
        play(.started)
    }

    func pause() {
        guard let state else { return }
        set(Pomodoro.pause(state, now: Date()))
    }

    func resume() {
        guard let state else { return }
        set(Pomodoro.resume(state, now: Date()))
        play(.started)
    }

    /// Ends the current phase now, without a banner or a chime.
    func skip() {
        guard let state else { return }
        advance(from: state, announce: false)
        if self.state != nil { play(.started) }
    }

    /// Plays `sound` whatever the switch says, for trying it out.
    func preview(_ sound: PomodoroSound) {
        play(sound, force: true)
    }

    private func play(_ sound: PomodoroSound, force: Bool = false) {
        guard soundsOn || force else { return }
        let player = sounds[sound] ?? NSSound(named: NSSound.Name(sound.systemName))
        guard let player else { return }
        sounds[sound] = player
        player.stop()
        player.volume = sound.volume
        player.play()
    }

    /// Stops and starts the cycle again from round 1.
    func stop() {
        setRounds(0)
        set(nil)
    }

    private func advance(from ended: PomodoroState, announce: Bool) {
        let next = Pomodoro.next(after: ended, plan: plan, now: Date())
        if announce {
            let banner = Pomodoro.banner(ending: ended.phase, next: next)
            play(.ending(ended.phase))
            notify(banner.title, banner.body, !soundsOn)
        }
        if let next {
            setRounds(next.completedFocus)
            set(next)
        } else {
            setRounds(ended.completedFocus)
            set(nil)
        }
    }

    private func set(_ new: PomodoroState?) {
        state = new
        if let new { save(new, UtilitiesSettings.pomodoroStateKey) } else {
            defaults?.removeObject(forKey: UtilitiesSettings.pomodoroStateKey)
        }
        schedule()
    }

    private func setRounds(_ rounds: Int) {
        completedFocus = rounds
        defaults?.set(rounds, forKey: UtilitiesSettings.pomodoroRoundsKey)
    }

    /// Waits in short steps against the wall clock: one long sleep can fire seconds late (timer leeway grows with
    /// the wait), and a phase that ended while the Mac slept moves on at wake. App Nap is held off while it runs.
    private func schedule() {
        timer?.cancel()
        guard let state, let endsAt = state.endsAt else {
            endActivity()
            return
        }
        beginActivity()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                let left = endsAt.timeIntervalSinceNow
                if left <= 0 { break }
                try? await Task.sleep(for: .seconds(min(left, 5)), tolerance: .milliseconds(100))
            }
            guard !Task.isCancelled, let self, let current = self.state, current == state else { return }
            self.advance(from: current, announce: true)
        }
    }

    private var activity: NSObjectProtocol?

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Pomodoro timer")
    }

    private func endActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }

    private func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults?.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
