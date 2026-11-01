import Foundation
import Testing
@testable import DevHubCore

@Suite struct PomodoroTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let plan = PomodoroPlan.standard

    @Test func focusRunsForItsLengthAndFillsTheRing() {
        let focus = Pomodoro.start(plan: plan, now: now)
        #expect(focus.phase == .focus)
        #expect(focus.endsAt == now.addingTimeInterval(25 * 60))
        #expect(focus.remaining(at: now.addingTimeInterval(60)) == 24 * 60)
        #expect(abs(focus.fraction(at: now.addingTimeInterval(5 * 60)) - 0.2) < 1e-9)
        #expect(!focus.isOver(at: now.addingTimeInterval(24 * 60)))
        #expect(focus.isOver(at: now.addingTimeInterval(25 * 60)))
        #expect(focus.title(plan: plan) == "Focus · round 1 of 4")
    }

    @Test func pausingKeepsWhatWasLeft() {
        let focus = Pomodoro.start(plan: plan, now: now)
        let paused = Pomodoro.pause(focus, now: now.addingTimeInterval(10 * 60))
        #expect(paused.isPaused)
        #expect(paused.remaining(at: now.addingTimeInterval(3600)) == 15 * 60)
        #expect(!paused.isOver(at: now.addingTimeInterval(86_400)))
        let resumed = Pomodoro.resume(paused, now: now.addingTimeInterval(3600))
        #expect(resumed.endsAt == now.addingTimeInterval(3600 + 15 * 60))
        #expect(Pomodoro.pause(paused, now: now) == paused)
        #expect(Pomodoro.resume(focus, now: now) == focus)
    }

    @Test func aLongBreakComesAfterEveryFourthRound() {
        var focus = Pomodoro.start(plan: plan, now: now)
        var breaks: [PomodoroPhase] = []
        for _ in 0..<8 {
            let next = Pomodoro.next(after: focus, plan: plan, now: now)!
            breaks.append(next.phase)
            #expect(Pomodoro.next(after: next, plan: plan, now: now) == nil)
            focus = Pomodoro.focusAfterBreak(completedFocus: next.completedFocus, plan: plan, now: now)
        }
        #expect(breaks == [.shortBreak, .shortBreak, .shortBreak, .longBreak, .shortBreak, .shortBreak, .shortBreak, .longBreak])
        #expect(focus.title(plan: plan) == "Focus · round 1 of 4")
    }

    @Test func bannersSayWhatComesNext() {
        let focus = Pomodoro.start(plan: plan, now: now)
        let next = Pomodoro.next(after: focus, plan: plan, now: now)
        #expect(Pomodoro.banner(ending: .focus, next: next) == ("Focus done", "Time for a break: 5 min."))
        let fourth = Pomodoro.start(.focus, completedFocus: 3, plan: plan, now: now)
        let long = Pomodoro.next(after: fourth, plan: plan, now: now)
        #expect(Pomodoro.banner(ending: .focus, next: long) == ("Focus done", "Time for a long break: 15 min."))
        #expect(Pomodoro.banner(ending: .shortBreak, next: nil).title == "Break's over")
    }

    @Test func eachEndingHasItsOwnChime() {
        #expect(PomodoroSound.ending(.focus) == .focusDone)
        #expect(PomodoroSound.ending(.shortBreak) == .breakOver)
        #expect(PomodoroSound.ending(.longBreak) == .breakOver)
        let names = PomodoroSound.allCases.map(\.systemName)
        #expect(Set(names).count == names.count)
        for name in names {
            #expect(FileManager.default.fileExists(atPath: "/System/Library/Sounds/\(name).aiff"))
        }
        #expect(PomodoroSound.started.volume < PomodoroSound.focusDone.volume)
    }

    @Test func clockReadsLikeATimer() {
        #expect(Pomodoro.clock(25 * 60) == "25:00")
        #expect(Pomodoro.clock(59.2) == "1:00")
        #expect(Pomodoro.clock(0) == "0:00")
        #expect(Pomodoro.clock(3900) == "1:05:00")
    }

    @Test func stateSurvivesARestart() throws {
        let paused = Pomodoro.pause(Pomodoro.start(plan: plan, now: now), now: now.addingTimeInterval(90))
        let data = try JSONEncoder().encode(paused)
        #expect(try JSONDecoder().decode(PomodoroState.self, from: data) == paused)
    }
}
