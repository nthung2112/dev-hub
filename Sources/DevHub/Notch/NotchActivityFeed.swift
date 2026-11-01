import Combine
import DevHubCore
import SwiftUI

/// Turns refreshes, the Pomodoro and Keep Awake into the notch's live activities. Refreshes you ask for and
/// the first one at launch show; the hourly ones and those on wake stay quiet.
@MainActor
final class NotchActivityFeed: ObservableObject {
    /// The one in the ears, and the rest as bubbles beside the notch.
    @Published private(set) var arrangement = NotchActivityArrangement()
    var current: NotchActivity? { arrangement.primary }
    /// The bubble you clicked, which keeps the ears until it ends.
    private var picked: NotchActivity.Kind?

    private let store: HubStore
    private let awake: CaffeinateController
    private let pomodoro: PomodoroController
    private var refresh: NotchActivity? { didSet { publish() } }
    private var total = 0
    private var wasRefreshing = false
    private var clearTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(store: HubStore, awake: CaffeinateController = .shared, pomodoro: PomodoroController? = nil) {
        self.store = store
        self.awake = awake
        let pomodoro = pomodoro ?? .shared
        self.pomodoro = pomodoro
        // `objectWillChange` fires before the change; the hop to the main run loop reads the new values.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        awake.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.publish() }
            .store(in: &cancellables)
        pomodoro.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.publish() }
            .store(in: &cancellables)
        publish()
    }

    /// Moves the activity in a bubble into the ears.
    func pick(_ kind: NotchActivity.Kind) {
        picked = kind
        publish()
    }

    private func publish() {
        let all = NotchActivity.all(refresh: refresh, pomodoro: pomodoro.state, awake: awake.state)
        if let picked, !all.contains(where: { $0.kind == picked }) { self.picked = nil }
        let next = NotchActivityArrangement.arrange(all, picked: picked)
        if arrangement != next { arrangement = next }
    }

    private func update() {
        if store.isRefreshing && store.refreshShowsActivity {
            let tabs = store.visibleTabs
            if !wasRefreshing {
                wasRefreshing = true
                total = tabs.count
                clearTask?.cancel()
            }
            let waiting = tabs.filter(\.isRefreshing).count
            show(.refreshing(done: max(0, total - waiting), total: total))
        } else if wasRefreshing {
            wasRefreshing = false
            let failed = store.visibleTabs.filter { $0.problem != nil }.count
            show(.refreshed(failed: failed))
            clearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(NotchActivity.finishedHold))
                guard !Task.isCancelled else { return }
                self?.show(nil)
            }
        }
    }

    private func show(_ activity: NotchActivity?) {
        if refresh != activity { refresh = activity }
    }
}

/// The live activity beside the camera: an indicator in the left ear, the line in the right one.
struct NotchActivityView: View {
    let activity: NotchActivity
    /// The width of each ear beside the cutout.
    let ear: CGFloat
    /// The black between the ears, over the camera.
    let middle: CGFloat
    /// The icon is in flight from a bubble; it shows once it lands.
    var iconHidden = false

    var body: some View {
        HStack(spacing: 0) {
            NotchActivityIcon(activity: activity)
                .opacity(iconHidden ? 0 : 1)
                .frame(width: ear)
            Color.clear.frame(width: middle)
            trailing
                .id(activity.kind)
                .transition(.asymmetric(insertion: .opacity.animation(.easeIn(duration: 0.15).delay(0.12)),
                                        removal: .opacity.animation(.easeOut(duration: 0.08))))
                // Held off the right edge: the pill's side sits 6 pt inside its frame, then 16 pt of black.
                .padding(.trailing, Self.trailingInset)
                .frame(width: ear, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.accessibilityLabel)
    }

    /// Focus is red, a break green, and paused orange, as in the Mac tab.
    static func tint(_ state: PomodoroState) -> Color {
        NotchActivityIcon.tint(state)
    }

    static let trailingInset: CGFloat = 22
}

/// An activity's symbol: a turning arrow while refreshing, a tick or a warning once done, the Pomodoro's
/// timer, leaf or pause, and Keep Awake's cup.
struct NotchActivityIcon: View {
    let activity: NotchActivity
    var size: CGFloat = 13

    var body: some View {
        switch activity {
        case .refreshing:
            // The system spinner draws dark grey on black; this turns at one revolution a second, in white.
            TimelineView(.animation) { context in
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
            }
        case let .refreshed(failed):
            Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: size + 1, weight: .semibold))
                .foregroundStyle(failed == 0 ? Color.green : Color.orange)
                .transition(.scale.combined(with: .opacity))
        case .keepingAwake:
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color.orange)
        case let .pomodoro(state):
            Image(systemName: state.isPaused ? "pause.fill" : state.phase.isBreak ? "leaf.fill" : "timer")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Self.tint(state))
                .contentTransition(.symbolEffect(.replace))
        }
    }

    static func tint(_ state: PomodoroState) -> Color {
        state.isPaused ? .orange : state.phase.isBreak ? .green : .red
    }

    /// The ring's colour: the Pomodoro's own, white for a refresh.
    static func ringTint(_ activity: NotchActivity) -> Color {
        if case let .pomodoro(state) = activity { return tint(state) }
        return .white
    }
}

extension NotchActivityView {
    fileprivate var trailing: some View {
        HStack(spacing: 5) {
            ActivityRing(activity: activity, diameter: 12, lineWidth: 2)
            line
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    /// A timed Keep Awake and a running Pomodoro count down by themselves (`24:13`); everything else is a fixed line.
    @ViewBuilder
    fileprivate var line: some View {
        if case let .keepingAwake(endsAt?) = activity, endsAt > Date() {
            Text(timerInterval: Date()...endsAt, countsDown: true, showsHours: true)
                .multilineTextAlignment(.center)
        } else if case let .pomodoro(state) = activity, let endsAt = state.endsAt, endsAt > Date() {
            Text(timerInterval: Date()...endsAt, countsDown: true, showsHours: false)
                .multilineTextAlignment(.center)
        } else {
            Text(activity.trailing)
                .contentTransition(.numericText())
                .animation(.snappy, value: activity.trailing)
        }
    }
}

/// The progress ring of a refresh or a Pomodoro; nothing for the others. A Pomodoro's follows the clock.
private struct ActivityRing: View {
    let activity: NotchActivity
    let diameter: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        if case let .pomodoro(state) = activity {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ProgressRing(fraction: state.fraction(at: context.date), tint: NotchActivityIcon.tint(state),
                             diameter: diameter, lineWidth: lineWidth)
            }
        } else if let fraction = activity.fraction {
            ProgressRing(fraction: fraction, tint: .white, diameter: diameter, lineWidth: lineWidth)
        }
    }
}

/// A small ring that fills clockwise from the top.
private struct ProgressRing: View {
    let fraction: Double
    let tint: Color
    var diameter: CGFloat = 12
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: lineWidth)
            Circle().trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
        .animation(.easeOut(duration: 0.25), value: fraction)
    }
}

/// A second or third activity, as a black bubble beside the notch: its symbol, ringed by its progress.
/// Clicking it moves it into the ears.
struct NotchActivityBubble: View {
    let activity: NotchActivity
    let diameter: CGFloat
    /// The icon is in flight to or from the ears; it shows once it lands.
    var iconHidden = false
    let pick: () -> Void
    @State private var hovering = false

    /// The icon's size in a bubble, as a share of the bubble.
    static let iconScale: CGFloat = 0.4

    var body: some View {
        ZStack {
            Circle().fill(Color.black)
            ActivityRing(activity: activity, diameter: diameter - 6, lineWidth: 2)
                .id(activity.kind)
                .transition(.opacity)
            NotchActivityIcon(activity: activity, size: diameter * Self.iconScale)
                .opacity(iconHidden ? 0 : 1)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .scaleEffect(hovering ? 1.12 : 1)
        .shadow(color: .black.opacity(hovering ? 0.5 : 0), radius: 4)
        .animation(.spring(response: 0.22, dampingFraction: 0.6), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(perform: pick)
        .help("Show \(activity.accessibilityLabel.lowercased()) in the notch")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, pick)
    }
}

/// A copy of an activity's icon travelling between the ears and a bubble when they swap. It springs along a
/// shallow arc and grows or shrinks to the size it lands at; the real icons stay hidden until it's there.
struct NotchIconFlight: Identifiable, Equatable {
    /// Unique for each swap, so a new swap starts new flights.
    let id: String
    let activity: NotchActivity
    let from: CGPoint
    let to: CGPoint
    let fromScale: CGFloat
    let toScale: CGFloat
}

struct NotchIconFlyer: View {
    let flight: NotchIconFlight
    let animation: Animation?
    @State private var progress: CGFloat = 0

    var body: some View {
        NotchActivityIcon(activity: flight.activity)
            .modifier(FlightPath(progress: progress, flight: flight))
            .onAppear { withAnimation(animation) { progress = 1 } }
    }
}

private struct FlightPath: ViewModifier, Animatable {
    var progress: CGFloat
    let flight: NotchIconFlight

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = progress
        // Dips a few points below the menu bar's centre line on the way, so the two icons pass rather than collide.
        let dip = sin(min(1, max(0, p)) * .pi) * 5
        content
            .scaleEffect(flight.fromScale + (flight.toScale - flight.fromScale) * p)
            .position(x: flight.from.x + (flight.to.x - flight.from.x) * p,
                      y: flight.from.y + (flight.to.y - flight.from.y) * p + dip)
    }
}
