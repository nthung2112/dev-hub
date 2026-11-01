import Combine
import DevHubCore
import SwiftUI

private let openRadius = (top: 19.0, bottom: 24.0)
private let closedRadius = (top: 6.0, bottom: 14.0)

private struct NotchAlertCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while a full-screen app is in front and the alert draws on one line.
    var notchAlertIsCompact: Bool {
        get { self[NotchAlertCompactKey.self] }
        set { self[NotchAlertCompactKey.self] = newValue }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Where the bubbles are, in the panel with a top-left origin, so the pointer can click them.
private struct BubbleFramesKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private struct VisibleSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 { value = next }
    }
}

/// How the notch responds, from Settings.
struct NotchBehaviour: Equatable {
    var opensOnHover = true
    var hoverDelay = HoverDelay.instant.seconds
    var showsAlerts = false
}

/// One notch's state: open or closed, and how big the drawn shape is.
@MainActor
final class NotchModel: ObservableObject {
    let store: HubStore
    let settings: AppSettings
    /// Shared by every notch, so a refresh shows on each screen.
    let activity: NotchActivityFeed

    @Published var isOpen = false
    @Published var isHovering = false
    @Published var closedSize = CGSize(width: NotchSizing.fallbackWidth, height: NotchSizing.fallbackHeight)
    /// Usable area of the screen this notch is on, without the menu bar and the Dock.
    @Published var screenLimit = CGSize(width: 1280, height: 720)
    /// The drawn shape, reported by the view. Hit testing uses it, so the rest of the panel stays click-through.
    @Published var visibleSize: CGSize
    /// A full-screen app is in front, so the alert draws on one line.
    @Published var isCompact = false
    /// The live-activity bubbles beside the notch, top-left origin. Clicks there pick a bubble and don't open the panel.
    @Published var bubbleFrames: [CGRect] = []
    /// The open panel's natural height, kept between openings so the next one drops straight to it.
    @Published var contentHeight: CGFloat = 420
    @Published var behaviour = NotchBehaviour()
    /// The next time the panel opens, it opens on Settings. Cleared when it closes.
    var presentSettings = false
    /// The controller rechecks the pointer after the shape changes size.
    var onGeometryChange: () -> Void = {}
    /// Mouse-leave leaves the panel open while a menu or a confirmation is up.
    var allowsHoverClose: () -> Bool = { true }

    private var hoverTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(store: HubStore, settings: AppSettings, activity: NotchActivityFeed) {
        self.store = store
        self.settings = settings
        self.activity = activity
        visibleSize = CGSize(width: NotchSizing.fallbackWidth, height: NotchSizing.fallbackHeight)
        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        activity.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        CaffeinateController.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// The window is this big even while the notch is closed, so opening it does not move the window.
    /// Everything outside `visibleSize` ignores the pointer.
    var panelSize: CGSize {
        NotchSizing.panelSize(within: screenLimit, neckHeight: closedSize.height)
    }

    /// The tallest the tabbed panel may grow on this screen.
    var maxBodyHeight: CGFloat {
        let open = NotchSizing.openSize(bodyHeight: screenLimit.height, neckHeight: closedSize.height, within: screenLimit)
        return max(240, open.height - closedSize.height - NotchSizing.openBottomInset)
    }

    /// A click, as opposed to a hover. The controller then makes the panel key.
    var wantsKey = false

    func open() {
        hoverTask?.cancel()
        wantsKey = true
        isOpen = true
    }

    /// `inside` changed. Hover opens after the delay; leaving closes, unless a menu or confirmation is up.
    func pointer(inside: Bool) {
        hoverTask?.cancel()
        if inside {
            let entered = !isHovering
            isHovering = true
            guard entered, !isOpen, behaviour.opensOnHover else { return }
            let delay = behaviour.hoverDelay
            guard delay > 0 else {
                isOpen = true
                return
            }
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                guard !Task.isCancelled, isHovering, !isOpen else { return }
                isOpen = true
            }
        } else {
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                isHovering = false
                guard behaviour.opensOnHover, isOpen, allowsHoverClose() else { return }
                isOpen = false
            }
        }
    }
}

/// The notch: a black shape in the cutout, an alert when something needs attention, and the panel when open.
@MainActor
struct NotchView: View {
    @ObservedObject var model: NotchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The width reaches the panel's quickly, so the panel reads as dropping out of the notch.
    private let widthSpring = Animation.spring(response: 0.2, dampingFraction: 0.86)
    /// The height drops down and overshoots a little, like the Dynamic Island.
    private let dropSpring = Animation.spring(response: 0.38, dampingFraction: 0.66)
    /// The panel follows its content when a tab or Settings changes its height.
    private let resizeSpring = Animation.spring(response: 0.36, dampingFraction: 0.86)
    private let closedSpring = Animation.spring(response: 0.28, dampingFraction: 0.9)
    private let hoverSpring = Animation.spring(response: 0.22, dampingFraction: 0.6)
    /// The ears beside the cutout spring out like the Dynamic Island's.
    private let activitySpring = Animation.spring(response: 0.42, dampingFraction: 0.68)
    /// Icons trading places between a bubble and the ears travel far; a calmer spring keeps them from overshooting.
    private let swapSpring = Animation.spring(response: 0.42, dampingFraction: 0.86)

    /// How far the shape is open, 0 at the notch and 1 at the panel. Opening overshoots past 1;
    /// `NotchGrowth` clamps at 0, so closing always stops at the notch.
    @State private var widthProgress: CGFloat = 0
    @State private var heightProgress: CGFloat = 0
    /// The panel stays in place while the shape closes over it and is removed once it has closed,
    /// so a long page isn't torn down mid-animation.
    @State private var showsContent = false
    @State private var contentOpacity: CGFloat = 0
    /// The live activity as drawn; it follows the feed with a spring, so the ears grow out and back.
    @State private var shownActivity: NotchActivity?
    /// The other activities, as bubbles to the right of the notch.
    @State private var shownBubbles: [NotchActivity] = []
    /// Icons travelling between the ears and the bubbles after a swap.
    @State private var flights: [NotchIconFlight] = []
    @State private var flightGeneration = 0

    var body: some View {
        drawn
            .onPreferenceChange(VisibleSizeKey.self) { size in
                guard size.width > 1, size.height > 1, size != model.visibleSize else { return }
                model.visibleSize = size
                Task { @MainActor in model.onGeometryChange() }
            }
            .onPreferenceChange(ContentHeightKey.self) { height in
                guard model.isOpen, height > 0, abs(height - model.contentHeight) > 0.5 else { return }
                withAnimation(reduceMotion ? nil : resizeSpring) { model.contentHeight = height }
            }
            .onChange(of: model.isOpen) { _, isOpen in animateShape(open: isOpen) }
            .onChange(of: model.activity.arrangement) { old, new in
                // Growing out, shrinking back and swapping places are springs; a change of line in place is quicker.
                let swapped = old.primary != nil && new.primary != nil && old.layout.count == new.layout.count
                    && old.layout != new.layout
                let animation: Animation? = reduceMotion ? nil
                    : swapped ? swapSpring : old.layout != new.layout ? activitySpring : .snappy(duration: 0.25)
                if swapped && !reduceMotion { launchFlights(from: old, to: new) }
                withAnimation(animation) {
                    shownActivity = new.primary
                    shownBubbles = new.bubbles
                }
            }
            .onPreferenceChange(BubbleFramesKey.self) { frames in
                guard frames != model.bubbleFrames else { return }
                model.bubbleFrames = frames
                Task { @MainActor in model.onGeometryChange() }
            }
            .onAppear {
                widthProgress = model.isOpen ? 1 : 0
                heightProgress = model.isOpen ? 1 : 0
                showsContent = model.isOpen
                contentOpacity = model.isOpen ? 1 : 0
                shownActivity = model.activity.arrangement.primary
                shownBubbles = model.activity.arrangement.bubbles
            }
            .frame(width: model.panelSize.width, height: model.panelSize.height, alignment: .top)
            .preferredColorScheme(.dark)
    }

    private func animateShape(open: Bool) {
        guard !reduceMotion else {
            widthProgress = open ? 1 : 0
            heightProgress = open ? 1 : 0
            showsContent = open
            contentOpacity = open ? 1 : 0
            return
        }
        if open {
            showsContent = true
            withAnimation(widthSpring) { widthProgress = 1 }
            withAnimation(dropSpring) { heightProgress = 1 }
            withAnimation(.easeOut(duration: 0.2)) { contentOpacity = 1 }
        } else {
            // A taller panel takes a little longer to lift, so it doesn't snap shut.
            let lift = 0.24 + 0.16 * min(1, model.contentHeight / 600)
            let curve = { (duration: Double) in Animation.timingCurve(0.32, 0, 0.18, 1, duration: duration) }
            withAnimation(curve(lift)) { heightProgress = 0 }
            withAnimation(.easeIn(duration: lift * 0.7)) { contentOpacity = 0 }
            withAnimation(curve(0.2).delay(lift * 0.55), completionCriteria: .logicallyComplete) {
                widthProgress = 0
            } completion: {
                if !model.isOpen { showsContent = false }
            }
        }
    }

    /// The panel's contents never move: they sit centred at the top of the window, and the growing shape masks
    /// them. Inside the shape they would follow its animating edges and drift in from the side.
    private var drawn: some View {
        ZStack(alignment: .top) {
            Color.clear.frame(width: model.panelSize.width, height: model.panelSize.height)
            shape
            openContent
                .opacity(contentOpacity)
                .mask(alignment: .top) { Color.black.modifier(growth) }
                .allowsHitTesting(model.isOpen)
            ears
            bubbleRow
            flyers
        }
        .coordinateSpace(name: Self.panelSpace)
    }

    /// The main activity beside the camera, drawn over the shape.
    @ViewBuilder
    private var ears: some View {
        if let activity = shownActivity, !model.isOpen, !showsAlert {
            NotchActivityView(activity: activity, ear: Self.activityEar, middle: cutoutFrameWidth,
                              iconHidden: isFlying(activity.kind))
                .frame(height: model.closedSize.height)
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
        }
    }

    private static let panelSpace = "notchPanel"

    // MARK: Swapping

    private enum Place: Equatable {
        case ear
        case bubble(Int)
    }

    private func place(of kind: NotchActivity.Kind, in arrangement: NotchActivityArrangement) -> Place? {
        if arrangement.primary?.kind == kind { return .ear }
        return arrangement.bubbles.firstIndex { $0.kind == kind }.map(Place.bubble)
    }

    /// The centre of the icon at `place`, in the panel with a top-left origin.
    private func centre(of place: Place) -> CGPoint {
        let middle = model.panelSize.width / 2
        let y = model.closedSize.height / 2
        switch place {
        case .ear:
            return CGPoint(x: middle - cutoutFrameWidth / 2 - Self.activityEar / 2, y: y)
        case let .bubble(index):
            let d = bubbleDiameter
            let first = middle + closedFrame.width / 2 + Self.bubbleGap + d / 2
            return CGPoint(x: first + CGFloat(index) * (d + Self.bubbleGap), y: y)
        }
    }

    private func scale(at place: Place) -> CGFloat {
        place == .ear ? 1 : bubbleDiameter * NotchActivityBubble.iconScale / 13
    }

    /// Every activity that changes place flies there; the rest stay put.
    private func launchFlights(from old: NotchActivityArrangement, to new: NotchActivityArrangement) {
        flightGeneration += 1
        let generation = flightGeneration
        flights = ([new.primary].compactMap { $0 } + new.bubbles).compactMap { activity in
            guard let from = place(of: activity.kind, in: old), let to = place(of: activity.kind, in: new), from != to
            else { return nil }
            return NotchIconFlight(id: "\(generation)-\(activity.kind.rawValue)", activity: activity,
                                   from: centre(of: from), to: centre(of: to),
                                   fromScale: scale(at: from), toScale: scale(at: to))
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(560))
            if flightGeneration == generation { flights = [] }
        }
    }

    private func isFlying(_ kind: NotchActivity.Kind) -> Bool {
        flights.contains { $0.activity.kind == kind }
    }

    private var flyers: some View {
        Color.clear
            .frame(width: model.panelSize.width, height: model.panelSize.height)
            .overlay(alignment: .topLeading) {
                ForEach(flights) { flight in
                    NotchIconFlyer(flight: flight, animation: swapSpring)
                }
            }
            .allowsHitTesting(false)
    }
    private static let bubbleGap: CGFloat = 6

    /// As tall as the menu bar, less a little air, like the Dynamic Island's separate bubble.
    private var bubbleDiameter: CGFloat { max(22, model.closedSize.height - 6) }

    /// The second and third activities, in a row just right of the notch. They hide while the panel is open.
    private var bubbleRow: some View {
        let diameter = bubbleDiameter
        let hidden = model.isOpen || showsAlert
        return HStack(spacing: Self.bubbleGap) {
            if !hidden {
                // Keyed by place, not by activity: on a swap the bubble stays and only its icon trades places.
                ForEach(Array(shownBubbles.enumerated()), id: \.offset) { _, activity in
                    NotchActivityBubble(activity: activity, diameter: diameter, iconHidden: isFlying(activity.kind)) {
                        model.activity.pick(activity.kind)
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: BubbleFramesKey.self, value: [proxy.frame(in: .named(Self.panelSpace))])
                        }
                    }
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
        }
        .padding(.top, (model.closedSize.height - diameter) / 2)
        .padding(.leading, model.panelSize.width / 2 + closedFrame.width / 2 + Self.bubbleGap)
        .frame(width: model.panelSize.width, alignment: .topLeading)
        .animation(reduceMotion ? nil : closedSpring, value: hidden)
    }

    private var growth: NotchGrowth {
        NotchGrowth(widthProgress: widthProgress, heightProgress: heightProgress,
                    openHeight: model.closedSize.height + model.contentHeight + NotchSizing.openBottomInset,
                    closedWidth: closedFrame.width, closedHeight: closedFrame.height,
                    openWidth: NotchSizing.contentWidth + 2 * NotchSizing.openHorizontalInset)
    }

    /// The closed notch: the shape trims its top corners, so it meets the bezel at the hardware cutout.
    /// A live activity adds an ear on each side; both are the same width, so the cutout stays centred.
    private var closedFrame: CGSize {
        let ears = shownActivity == nil ? 0 : 2 * Self.activityEar
        return CGSize(width: cutoutFrameWidth + ears, height: model.closedSize.height)
    }

    private var cutoutFrameWidth: CGFloat { model.closedSize.width - 20 + 2 * closedRadius.bottom }

    private static let activityEar: CGFloat = 80

    private var shape: some View {
        ZStack(alignment: .top) {
            if showsAlert {
                closedContent
                    .background(Color.black)
                    .clipShape(NotchAlertShape(notch: hardwareNotch))
            } else {
                Color.black
                    .modifier(growth)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.black).frame(height: 1).padding(.horizontal, closedRadius.top)
                    }
            }
        }
        .animation(reduceMotion ? nil : hoverSpring) { content in
            content
                .scaleEffect(model.isHovering && !model.isOpen ? 1.06 : 1, anchor: .top)
                .shadow(color: model.isOpen || model.isHovering ? .black.opacity(0.7) : .clear, radius: 6)
        }
        .allowsHitTesting(false)
        .overlay(alignment: .top) { hitTarget }
        .animation(showsAlert && !reduceMotion ? closedSpring : nil, value: showsAlert)
    }

    /// Where the pointer counts: the shape's size once it has finished moving, not while it animates,
    /// so the size is reported once per change rather than every frame.
    @ViewBuilder
    private var hitTarget: some View {
        Group {
            if showsAlert {
                closedContent.hidden()
                    .contentShape(NotchAlertShape(notch: hardwareNotch, rounded: false))
            } else {
                Color.clear
                    .frame(width: model.isOpen ? growth.openWidth : closedFrame.width,
                           height: model.isOpen ? growth.openHeight : closedFrame.height)
                    .contentShape(Rectangle())
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: VisibleSizeKey.self, value: proxy.size)
            }
        }
        .modifier(ClosedNotchTap(isOpen: model.isOpen, open: { model.open() }))
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(model.isOpen)
        .accessibilityLabel(showsAlert ? (model.isCompact ? compactLine : alertLines.joined(separator: ", "))
                            : shownActivity.map { "Dev Hub, \($0.accessibilityLabel)" } ?? "Dev Hub")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { model.open() }
    }

    /// The panel at its final width and natural height, under the notch. The growing shape masks it,
    /// so it is revealed from the top down while it slides into place.
    @ViewBuilder
    private var openContent: some View {
        if showsContent {
            HubView(store: model.store, settings: model.settings, showSettings: model.presentSettings,
                    maximumHeight: model.maxBodyHeight, onClose: { model.isOpen = false })
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                }
                .padding(.top, model.closedSize.height)
                .transition(.asymmetric(
                    insertion: .offset(y: -28).animation(reduceMotion ? nil : dropSpring.delay(0.03)),
                    removal: .identity
                ))
        }
    }

    private var showsAlert: Bool {
        !model.isOpen && model.behaviour.showsAlerts && model.store.badge != nil
    }

    /// The hardware cutout: a little narrower than the closed window, so the shape meets the bezel.
    private var hardwareNotch: CGSize {
        CGSize(width: max(0, model.closedSize.width - 4), height: model.closedSize.height)
    }

    /// The gap under the camera, and the alert below it when a tab is red or a refresh needs attention.
    private var closedContent: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: model.closedSize.width - 20, height: model.closedSize.height)
            if showsAlert {
                NotchAlertBody(lines: alertLines, countLine: countLine, compactLine: compactLine, tint: alertTint)
                    .frame(width: NotchMetrics.alertAreaWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.notchAlertIsCompact, model.isCompact)
            }
        }
    }

    private var alertLines: [String] {
        let awake = CaffeinateController.shared.state.map { "Keep awake: \($0.line)" }
        return model.store.visibleTabs.map(\.line) + (awake.map { [$0] } ?? [])
    }

    private var countLine: String? {
        let count = model.store.failingCount
        guard model.settings.showCounts, count > 0 else { return nil }
        return "\(count) red"
    }

    private var compactLine: String {
        let count = model.store.failingCount
        if model.store.badge == .red, count > 0 { return "Dev Hub \(count) red" }
        if model.store.badge == .orange { return "Dev Hub needs attention" }
        return "Dev Hub"
    }

    private var alertTint: Color {
        model.store.badge == .orange ? .orange : .red
    }
}

/// Sizes a view between the closed notch and the open panel, and clips it to the notch outline.
/// The progress values are interpolated every frame, so the clamp at 0 holds even when a close
/// interrupts a bouncing open: the shape never shrinks inside the notch.
struct NotchGrowth: ViewModifier, Animatable {
    var widthProgress: CGFloat
    var heightProgress: CGFloat
    var openHeight: CGFloat
    /// Wider than the cutout while a live activity shows beside it.
    var closedWidth: CGFloat
    let closedHeight: CGFloat
    let openWidth: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(widthProgress, heightProgress), AnimatablePair(openHeight, closedWidth)) }
        set {
            widthProgress = newValue.first.first
            heightProgress = newValue.first.second
            openHeight = newValue.second.first
            closedWidth = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        let w = max(0, widthProgress)
        let h = max(0, heightProgress)
        let corners = min(1, h)
        content
            .frame(width: closedWidth + (openWidth - closedWidth) * w,
                   height: closedHeight + (openHeight - closedHeight) * h)
            .clipShape(NotchShape(topRadius: closedRadius.top + (openRadius.top - closedRadius.top) * corners,
                                  bottomRadius: closedRadius.bottom + (openRadius.bottom - closedRadius.bottom) * corners))
    }
}

/// A tap opens the closed notch. The gesture is absent while the panel is open, so clicks reach its buttons.
private struct ClosedNotchTap: ViewModifier {
    let isOpen: Bool
    let open: () -> Void

    func body(content: Content) -> some View {
        if isOpen {
            content
        } else {
            content.onTapGesture(perform: open)
        }
    }
}

/// The lines under the closed notch. One line while a full-screen app is in front.
private struct NotchAlertBody: View {
    let lines: [String]
    let countLine: String?
    let compactLine: String
    let tint: Color
    @Environment(\.notchAlertIsCompact) private var compact

    var body: some View {
        if compact {
            Text(compactLine)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                if let countLine {
                    Text(countLine)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}
