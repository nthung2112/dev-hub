import CoreGraphics
import Foundation
import Testing
@testable import DevHubCore

@Suite struct NotchTests {
    @Test func alertNeckIsCentredOverTheBody() {
        let layout = NotchAlertLayout(notch: CGSize(width: 185, height: 32), area: CGSize(width: 370, height: 60))
        #expect(layout.neck == CGRect(x: 92.5, y: 0, width: 185, height: 32))
        #expect(layout.body == CGRect(x: 0, y: 32, width: 370, height: 60))
        #expect(layout.size == CGSize(width: 370, height: 92))
    }

    @Test func bandBesideTheNotchIsOutsideTheAlert() {
        let layout = NotchAlertLayout(notch: CGSize(width: 185, height: 32), area: CGSize(width: 370, height: 60))
        #expect(!layout.contains(CGPoint(x: 40, y: 10)))
        #expect(!layout.contains(CGPoint(x: 330, y: 10)))
        #expect(layout.contains(CGPoint(x: 185, y: 10)))
        #expect(layout.contains(CGPoint(x: 40, y: 50)))
    }

    @Test func joinCornersAreInsideOnlyNearTheNeck() {
        let layout = NotchAlertLayout(notch: CGSize(width: 185, height: 32), area: CGSize(width: 370, height: 60))
        let y = layout.body.minY - 1
        #expect(layout.contains(CGPoint(x: layout.neck.minX - 2, y: y)))
        #expect(layout.contains(CGPoint(x: layout.neck.maxX + 2, y: y)))
        #expect(!layout.contains(CGPoint(x: layout.neck.minX - 7, y: y)))
        #expect(!layout.contains(CGPoint(x: layout.neck.maxX + 7, y: y)))
        #expect(!layout.contains(CGPoint(x: layout.neck.minX - 5, y: layout.body.minY - 5)))
        #expect(!layout.contains(CGPoint(x: layout.neck.maxX + 5, y: layout.body.minY - 5)))
    }

    @Test func hitTestingIgnoresTheMenuBarBandBesideAnAlert() {
        let panel = CGSize(width: 600, height: 800)
        let visible = CGSize(width: 370, height: 92)
        let closed = CGSize(width: 189, height: 32)
        let origin = (panel.width - visible.width) / 2
        #expect(!NotchHit.contains(CGPoint(x: origin + 10, y: 10), panel: panel, visible: visible, closed: closed, showsAlert: true))
        #expect(NotchHit.contains(CGPoint(x: origin + 185, y: 10), panel: panel, visible: visible, closed: closed, showsAlert: true))
        #expect(NotchHit.contains(CGPoint(x: origin + 10, y: 50), panel: panel, visible: visible, closed: closed, showsAlert: true))
        #expect(!NotchHit.contains(CGPoint(x: 10, y: 10), panel: panel, visible: visible, closed: closed, showsAlert: true))
    }

    @Test func closedNotchFillsTheCutoutOrAFallbackPill() {
        #expect(NotchSizing.closedSize(screenWidth: 1512, leftAuxiliary: 660, rightAuxiliary: 656,
                                       menuBarHeight: 24, topSafeInset: 38) == CGSize(width: 200, height: 38))
        #expect(NotchSizing.closedSize(screenWidth: 1512, leftAuxiliary: nil, rightAuxiliary: nil,
                                       menuBarHeight: 24, topSafeInset: 0) == CGSize(width: 185, height: 24))
        #expect(NotchSizing.closedSize(screenWidth: 800, leftAuxiliary: nil, rightAuxiliary: 40,
                                       menuBarHeight: 0, topSafeInset: 0) == CGSize(width: 185, height: 32))
    }

    @Test func openNotchClampsToTheVisibleScreen() {
        let roomy = CGSize(width: 1512, height: 900)
        #expect(NotchSizing.openSize(bodyHeight: 400, neckHeight: 32, within: roomy) == CGSize(width: 582, height: 444))
        #expect(NotchSizing.resolve(CGSize(width: 720, height: 360), within: CGSize(width: 700, height: 300))
            == CGSize(width: 700, height: 280))
        let panel = NotchSizing.panelSize(within: CGSize(width: 700, height: 300), neckHeight: 32)
        #expect(panel == CGSize(width: 582, height: 300))
    }

    @Test func displayChoiceUsesTheMainScreenWhenTheChosenOneIsGone() {
        let displays = [NotchDisplay(id: "a", name: "Built-in"), NotchDisplay(id: "b", name: "Desk")]
        #expect(NotchDisplayChoice.main.resolve(among: displays).map(\.id) == ["a"])
        #expect(NotchDisplayChoice.all.resolve(among: displays).map(\.id) == ["a", "b"])
        #expect(NotchDisplayChoice.display(id: "b", name: "Desk").resolve(among: displays).map(\.id) == ["b"])
        #expect(NotchDisplayChoice.display(id: "gone", name: "Old").resolve(among: displays).map(\.id) == ["a"])
        #expect(NotchDisplayChoice.main.resolve(among: []).isEmpty)
    }

    @Test func refreshActivityCountsTabsAndSaysHowItEnded() {
        let running = NotchActivity.refreshing(done: 3, total: 11)
        #expect(running.trailing == "3/11")
        #expect(running.fraction == 3.0 / 11.0)
        #expect(running.accessibilityLabel == "Refreshing, 3 of 11 tabs done")
        #expect(NotchActivity.refreshing(done: 12, total: 11).trailing == "11/11")
        #expect(NotchActivity.refreshing(done: 0, total: 0).fraction == nil)
        #expect(NotchActivity.refreshed(failed: 0).trailing == "Done")
        #expect(NotchActivity.refreshed(failed: 0).fraction == nil)
        #expect(NotchActivity.refreshed(failed: 2).trailing == "2 failed")
        #expect(NotchActivity.refreshed(failed: 1).accessibilityLabel == "Refreshed, 1 tab need attention")
    }

    @Test func keepAwakeShowsUntilARefreshTakesOver() {
        let ends = Date(timeIntervalSince1970: 1_000_000)
        let timed = KeepAwakeState(startedAt: Date(timeIntervalSince1970: 0), endsAt: ends)
        let untimed = KeepAwakeState(startedAt: Date(timeIntervalSince1970: 0), endsAt: nil)
        #expect(NotchActivity.showing(refresh: nil, awake: nil) == nil)
        #expect(NotchActivity.showing(refresh: nil, awake: timed) == .keepingAwake(endsAt: ends))
        #expect(NotchActivity.showing(refresh: .refreshing(done: 1, total: 3), awake: timed) == .refreshing(done: 1, total: 3))
        #expect(NotchActivity.showing(refresh: .refreshed(failed: 0), awake: untimed) == .refreshed(failed: 0))
        #expect(NotchActivity.keepingAwake(endsAt: nil).trailing == "Awake")
        #expect(NotchActivity.keepingAwake(endsAt: nil).fraction == nil)
        #expect(NotchActivity.keepingAwake(endsAt: nil).accessibilityLabel == "Awake until stopped")
    }

    @Test func pomodoroTakesTheNotchFromKeepAwakeButNotFromARefresh() {
        let now = Date(timeIntervalSince1970: 0)
        let focus = Pomodoro.start(plan: .standard, now: now)
        let awake = KeepAwakeState(startedAt: now, endsAt: nil)
        #expect(NotchActivity.showing(refresh: nil, pomodoro: focus, awake: awake) == .pomodoro(focus))
        #expect(NotchActivity.showing(refresh: .refreshed(failed: 0), pomodoro: focus, awake: awake) == .refreshed(failed: 0))
        #expect(NotchActivity.showing(refresh: nil, pomodoro: nil, awake: awake) == .keepingAwake(endsAt: nil))
        #expect(NotchActivity.pomodoro(focus).fraction == nil)
    }

    @Test func extraActivitiesBecomeBubblesAndAPickedOneTakesTheEars() {
        let now = Date(timeIntervalSince1970: 0)
        let focus = Pomodoro.start(plan: .standard, now: now)
        let awake = KeepAwakeState(startedAt: now, endsAt: nil)
        let refresh = NotchActivity.refreshing(done: 1, total: 4)
        let all = NotchActivity.all(refresh: refresh, pomodoro: focus, awake: awake)
        #expect(all.map(\.kind) == [.refresh, .pomodoro, .keepAwake])

        let plain = NotchActivityArrangement.arrange(all, picked: nil)
        #expect(plain.primary == refresh)
        #expect(plain.bubbles.map(\.kind) == [.pomodoro, .keepAwake])

        let picked = NotchActivityArrangement.arrange(all, picked: .keepAwake)
        #expect(picked.layout == [.keepAwake, .refresh, .pomodoro])

        // A pick that isn't running any more falls back to the usual order.
        let gone = NotchActivityArrangement.arrange([.pomodoro(focus)], picked: .refresh)
        #expect(gone.layout == [.pomodoro])
        #expect(NotchActivityArrangement.arrange([], picked: .pomodoro) == NotchActivityArrangement())
        #expect(NotchActivity.refreshed(failed: 2).kind == .refresh)
    }

    @Test func hoverDelayMatchesTheNotchPauses() {
        #expect(HoverDelay.instant.seconds == 0)
        #expect(HoverDelay.short.seconds == 0.15)
        #expect(HoverDelay.medium.seconds == 0.4)
        #expect(HoverDelay.long.seconds == 0.8)
    }
}

@Suite struct FullScreenCheckTests {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    private func isFullScreen(_ bounds: CGRect, pid: Int32 = 42, layer: Int = 0, topInset: CGFloat = 38,
                              systemSaysFullScreen: Bool = true) -> Bool {
        FullScreenCheck.isFullScreen([FullScreenCheck.Window(pid: pid, layer: layer, bounds: bounds)],
                                     screen: screen, topInset: topInset, frontmostPID: 42,
                                     systemSaysFullScreen: systemSaysFullScreen)
    }

    @Test func fullScreenWindowOfTheFrontApp() {
        #expect(isFullScreen(CGRect(x: 0, y: 0.5, width: 1512, height: 982)))
        #expect(isFullScreen(CGRect(x: 0, y: 0.5, width: 1512, height: 982), topInset: 0))
    }

    @Test func fullScreenWindowBelowTheNotch() {
        #expect(isFullScreen(CGRect(x: 0, y: 38, width: 1512, height: 944)))
        #expect(isFullScreen(CGRect(x: 0, y: 38.5, width: 1512, height: 943.5)))
        #expect(!isFullScreen(CGRect(x: 0, y: 38, width: 1512, height: 944), topInset: 0))
    }

    @Test func belowTheNotchCountsOnlyWithTheSystemSignal() {
        #expect(!isFullScreen(CGRect(x: 0, y: 38, width: 1512, height: 944), systemSaysFullScreen: false))
        #expect(!isFullScreen(screen, systemSaysFullScreen: false))
    }

    @Test func otherAppOrOtherLayerOrSmallerWindowIsNot() {
        #expect(!isFullScreen(screen, pid: 7))
        #expect(!isFullScreen(screen, layer: 25))
        #expect(!isFullScreen(CGRect(x: 0, y: 38, width: 1512, height: 900)))
        #expect(!isFullScreen(CGRect(x: 0, y: 0, width: 1512, height: 900)))
        #expect(!isFullScreen(CGRect(x: 0, y: 0, width: 1200, height: 982)))
        #expect(!isFullScreen(CGRect(x: 0, y: 38, width: 1200, height: 944)))
    }

    @Test func windowsSkipsIncompleteEntries() {
        let pid = kCGWindowOwnerPID as String
        let layer = kCGWindowLayer as String
        let bounds = kCGWindowBounds as String
        let rect = CGRect(x: 10, y: 20, width: 300, height: 400)
        let list: [[String: Any]] = [
            [pid: NSNumber(value: 42), layer: NSNumber(value: 0), bounds: rect.dictionaryRepresentation],
            [layer: NSNumber(value: 0), bounds: rect.dictionaryRepresentation],
            [pid: NSNumber(value: 43), bounds: rect.dictionaryRepresentation],
            [pid: NSNumber(value: 44), layer: NSNumber(value: 0)],
        ]
        #expect(FullScreenCheck.windows(from: list) == [FullScreenCheck.Window(pid: 42, layer: 0, bounds: rect)])
    }
}
