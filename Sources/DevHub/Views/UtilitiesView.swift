import AppKit
import SwiftUI
import DevHubCore

/// The Mac tab: machine utilities that run as you, none of which need admin rights.
struct UtilitiesView: View {
    @ObservedObject var tab: TabState
    @StateObject private var layout: UtilityLayout

    init(tab: TabState) {
        self.tab = tab
        _layout = StateObject(wrappedValue: UtilityLayout(defaults: tab.store.settings.defaults))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            if case .error(let message)? = tab.problem {
                ErrorText(message)
            }
            sections
        }
        .environmentObject(layout)
        .onAppear { tab.store.refresh(tab: tab) }
    }

    private var toolbar: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Mac utilities").font(.system(size: 13, weight: .semibold))
            Text("Run as you, no admin rights needed").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button(layout.allCollapsed ? "Expand all" : "Collapse all") {
                withAnimation(.easeInOut(duration: 0.15)) { layout.setAll(expanded: layout.allCollapsed) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder private var sections: some View {
        VStack(alignment: .leading, spacing: 10) {
            KeepAwakeSection(defaults: tab.store.settings.defaults)
            PomodoroSection()
            DisplaySection()
            PortSection(defaults: tab.store.settings.defaults)
            if let status = tab.detail(MachineStatus.self) {
                FinderSection(tab: tab, status: status)
                ScreenshotSection(tab: tab, status: status)
                PowerSection(tab: tab, status: status)
                CleanupSection()
                NetworkSection(status: status)
            } else if tab.problem == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading this Mac's settings…").foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }
}

/// Runs a section's action, shows its error, and re-reads the Mac's state once it's done.
@MainActor
private final class UtilityAction: ObservableObject {
    @Published var message: String?
    @Published var running = false

    func run(_ tab: TabState?, _ work: @escaping () async throws -> Void) {
        message = nil
        running = true
        Task {
            do {
                try await work()
            } catch {
                message = error.localizedDescription
            }
            running = false
            if let tab { tab.store.refresh(tab: tab) }
        }
    }
}

// MARK: - Keep awake

private struct KeepAwakeSection: View {
    let defaults: UserDefaults
    @ObservedObject private var controller = CaffeinateController.shared
    @State private var options: CaffeinateOptions
    @State private var duration: CaffeinateDuration
    @State private var message: String?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let raw = defaults.object(forKey: UtilitiesSettings.caffeinateOptionsKey) as? Int
        _options = State(initialValue: raw.map(CaffeinateOptions.init(rawValue:)) ?? .standard)
        let seconds = defaults.object(forKey: UtilitiesSettings.caffeinateDurationKey) as? Int
        _duration = State(initialValue: seconds.flatMap(CaffeinateDuration.init(rawValue:)) ?? .hour1)
    }

    var body: some View {
        UtilitySection("keepAwake", title: "Keep awake", subtitle: "Stop the Mac from sleeping",
                       symbol: "cup.and.saucer.fill", tint: .brown,
                       footer: "Runs caffeinate as you. It stops when the time is up, when you press Stop, or when Dev Hub quits.") {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                SettingsRow(title, help: detail(now: context.date)) {
                    Button {
                        controller.state == nil ? start() : controller.stop()
                    } label: {
                        Label(controller.state == nil ? "Start" : "Stop",
                              systemImage: controller.state == nil ? "cup.and.saucer" : "stop.circle")
                    }
                    .controlSize(.small)
                }
            }
            RowDivider()
            SettingsRow("Duration") {
                Picker("Duration", selection: $duration) {
                    ForEach(CaffeinateDuration.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .controlSize(.small)
            }
            RowDivider()
            HStack(spacing: 14) {
                checkbox("Display", .display, help: "Keeps the screen on (-d)")
                checkbox("Idle sleep", .idle, help: "Stops the Mac sleeping when you're away (-i)")
                checkbox("System sleep", .system, help: "Stops the Mac sleeping at all; only works on power (-s)")
                checkbox("Disk sleep", .disk, help: "Keeps the disks spinning (-m)")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            if let message {
                ErrorText(message).padding(.horizontal, 10).padding(.bottom, 8)
            }
        } status: {
            if let state = controller.state {
                StatusChip(state.endsAt.map { "On · until \($0.formatted(date: .omitted, time: .shortened))" } ?? "On",
                           tint: .green, symbol: "cup.and.saucer.fill")
            } else {
                StatusChip("Off")
            }
        }
        .onChange(of: options) { _, value in
            defaults.set(value.rawValue, forKey: UtilitiesSettings.caffeinateOptionsKey)
            if controller.state != nil { start() }
        }
        .onChange(of: duration) { _, value in
            defaults.set(value.rawValue, forKey: UtilitiesSettings.caffeinateDurationKey)
            if controller.state != nil { start() }
        }
    }

    private var title: String {
        controller.state?.line ?? "The Mac sleeps as usual"
    }

    /// `28 min left`, `Running for 2 h 5 min`.
    private func detail(now: Date) -> String? {
        guard let state = controller.state else { return nil }
        if let endsAt = state.endsAt {
            return "\(Self.minutes(endsAt.timeIntervalSince(now))) left"
        }
        return "Running for \(Self.minutes(now.timeIntervalSince(state.startedAt)))"
    }

    private static func minutes(_ interval: TimeInterval) -> String {
        let total = max(0, Int((interval / 60).rounded(.up)))
        return total >= 60 ? "\(total / 60) h \(total % 60) min" : "\(total) min"
    }

    private func checkbox(_ label: String, _ option: CaffeinateOptions, help: String) -> some View {
        Toggle(label, isOn: Binding(
            get: { options.contains(option) },
            set: { on in if on { options.insert(option) } else { options.remove(option) } }
        ))
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        .help(help)
    }

    private func start() {
        message = nil
        do {
            try controller.start(options: options, duration: duration)
        } catch {
            message = "Couldn't start caffeinate: \(error.localizedDescription)"
        }
    }
}

// MARK: - Pomodoro

private struct PomodoroSection: View {
    @ObservedObject private var pomodoro = PomodoroController.shared

    var body: some View {
        UtilitySection("pomodoro", title: "Pomodoro", subtitle: "Focus in rounds, with breaks between",
                       symbol: "timer", tint: .red,
                       footer: "A break starts by itself when a focus round ends, and the next round waits for you. A banner says when each one is over. It carries on if Dev Hub restarts.") {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                clock(now: context.date)
            }
            RowDivider()
            lengths
            RowDivider()
            soundRow
        } status: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                status(now: context.date)
            }
        }
    }

    private func clock(now: Date) -> some View {
        let state = pomodoro.state
        let plan = pomodoro.plan
        let remaining = state?.remaining(at: now) ?? plan.length(of: .focus)
        let tint = state.map(NotchActivityView.tint) ?? .secondary
        return HStack(spacing: 12) {
            ZStack {
                Circle().stroke(tint.opacity(0.18), lineWidth: 4)
                Circle().trim(from: 0, to: state?.fraction(at: now) ?? 0)
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: state?.fraction(at: now))
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(Pomodoro.clock(remaining))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                Text(subtitle(state: state, plan: plan))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            controls(state: state)
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
    }

    private func subtitle(state: PomodoroState?, plan: PomodoroPlan) -> String {
        guard let state else {
            let round = pomodoro.completedFocus % max(1, plan.roundsBeforeLongBreak) + 1
            return "Ready · round \(round) of \(plan.roundsBeforeLongBreak)"
        }
        return state.title(plan: plan) + (state.isPaused ? " · paused" : "")
    }

    @ViewBuilder
    private func controls(state: PomodoroState?) -> some View {
        HStack(spacing: 6) {
            if let state {
                Button {
                    state.isPaused ? pomodoro.resume() : pomodoro.pause()
                } label: {
                    Label(state.isPaused ? "Resume" : "Pause", systemImage: state.isPaused ? "play.fill" : "pause.fill")
                }
                Button { pomodoro.skip() } label: {
                    Label(state.phase.isBreak ? "Skip break" : "Skip", systemImage: "forward.end.fill")
                }
                .help(state.phase.isBreak ? "End the break now" : "End this focus round now and start the break")
                Button { pomodoro.stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop and start again from round 1")
            } else {
                Button { pomodoro.start() } label: {
                    Label("Start focus", systemImage: "play.fill")
                }
            }
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }

    private var lengths: some View {
        HStack(spacing: 14) {
            minutesPicker("Focus", value: $pomodoro.plan.focusMinutes, choices: PomodoroPlan.focusChoices)
            minutesPicker("Short break", value: $pomodoro.plan.shortBreakMinutes, choices: PomodoroPlan.shortBreakChoices)
            minutesPicker("Long break", value: $pomodoro.plan.longBreakMinutes, choices: PomodoroPlan.longBreakChoices)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .help("New lengths apply from the next focus round or break. A long break comes after every \(pomodoro.plan.roundsBeforeLongBreak) focus rounds.")
    }

    private var soundRow: some View {
        HStack(spacing: 8) {
            Toggle("Sounds", isOn: $pomodoro.soundsOn)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help("A chime when a focus round or a break ends, and a soft tick when one starts. The banner stays silent while these are on.")
            Spacer(minLength: 8)
            Text("Try").font(.caption2).foregroundStyle(.secondary)
            previewButton("Focus done", .focusDone)
            previewButton("Break over", .breakOver)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func previewButton(_ label: String, _ sound: PomodoroSound) -> some View {
        Button { pomodoro.preview(sound) } label: {
            Label(label, systemImage: "speaker.wave.2.fill")
        }
        .controlSize(.small)
        .help("Play the \(label.lowercased()) chime (\(sound.systemName))")
    }

    private func minutesPicker(_ label: String, value: Binding<Int>, choices: [Int]) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 12))
            Picker(label, selection: value) {
                ForEach(choices.contains(value.wrappedValue) ? choices : (choices + [value.wrappedValue]).sorted(), id: \.self) {
                    Text("\($0) min").tag($0)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func status(now: Date) -> some View {
        if let state = pomodoro.state {
            let left = Pomodoro.clock(state.remaining(at: now))
            StatusChip(state.isPaused ? "Paused · \(left)" : "\(state.phase.isBreak ? "Break" : "Focus") · \(left)",
                       tint: NotchActivityView.tint(state),
                       symbol: state.isPaused ? "pause.fill" : state.phase.isBreak ? "leaf.fill" : "timer")
        } else {
            StatusChip("Off")
        }
    }
}

// MARK: - Displays

private struct DisplaySection: View {
    @ObservedObject private var displays = DisplayController.shared

    var body: some View {
        UtilitySection("displays", title: displays.externals.count > 1 ? "External displays" : "External display",
                       subtitle: "Resolution, arrangement and brightness", symbol: "display.2", tint: .blue,
                       footer: "Changes apply straight away and stay, as in System Settings > Displays.") {
            if displays.externals.isEmpty {
                SettingsRow("No external display connected", help: displays.builtin.map { "\($0.name): \($0.summary)" }) {
                    Button("Detect") { displays.reload() }.controlSize(.small)
                }
            } else {
                if displays.displays.filter({ $0.mirrorOf == nil }).count > 1 {
                    ArrangementCanvas(displays: displays)
                    RowDivider()
                }
                ForEach(Array(displays.externals.enumerated()), id: \.element.id) { index, external in
                    if index > 0 { RowDivider() }
                    ExternalDisplayRows(displays: displays, external: external)
                }
                RowDivider()
                BrightnessRow(displays: displays)
                if let builtin = displays.builtin {
                    RowDivider()
                    SwitchRow("Turn off the built-in screen",
                              help: builtin.isMain
                                  ? "The menu bar is on the built-in screen: make the external display the main one first."
                                  : "Backlight off and picture black. It comes back when you switch this off, unplug the display, or quit Dev Hub.",
                              isOn: Binding(get: { displays.builtinOff }, set: { displays.setBuiltinOff($0) }),
                              disabled: displays.externals.contains { $0.mirrorOf != nil })
                }
            }
            if let message = displays.message {
                ErrorText(message).padding(.horizontal, 10).padding(.bottom, 8)
            }
        } status: {
            switch displays.externals.count {
            case 0: StatusChip("None connected")
            case 1: StatusChip(displays.externals[0].name, tint: .blue, symbol: "checkmark")
            case let count: StatusChip("\(count) connected", tint: .blue, symbol: "checkmark")
            }
        }
    }
}

private struct ExternalDisplayRows: View {
    @ObservedObject var displays: DisplayController
    let external: DisplayInfo

    private var mirrored: Bool { external.mirrorOf != nil }

    var body: some View {
        SettingsRow(external.name, help: external.summary + (mirrored ? " · mirroring the built-in screen" : "")) {
            Image(systemName: mirrored ? "rectangle.on.rectangle" : "display")
                .foregroundStyle(.secondary)
        }
        RowDivider()
        SettingsRow("Resolution") {
            Picker("Resolution", selection: Binding(
                get: { external.current?.size },
                set: { size in if let size { displays.setSize(size, on: external) } }
            )) {
                ForEach(sizes) { Text($0.label).tag(Optional($0)) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize().controlSize(.small)
        }
        let rates = external.current.map { DisplayModes.refreshOptions(external.modes, size: $0.size) } ?? []
        if rates.count > 1 {
            RowDivider()
            SettingsRow("Refresh rate") {
                Picker("Refresh rate", selection: Binding(
                    get: { external.current?.id },
                    set: { id in if let mode = rates.first(where: { $0.id == id }) { displays.setMode(mode, on: external) } }
                )) {
                    ForEach(rates) { Text($0.refreshLabel).tag(Optional($0.id)) }
                    if let current = external.current, !rates.contains(where: { $0.id == current.id }) {
                        Text(current.refreshLabel).tag(Optional(current.id))
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize().controlSize(.small)
            }
        }
        if let builtin = displays.builtin {
            RowDivider()
            SwitchRow("Main display", help: "Where the menu bar and Dock go.", isOn: Binding(
                get: { external.isMain },
                set: { on in displays.makeMain(on ? external : builtin) }
            ), disabled: mirrored)
            RowDivider()
            SwitchRow("Mirror the built-in screen", help: "The same picture on both, e.g. for presenting.", isOn: Binding(
                get: { mirrored },
                set: { displays.setMirroring($0, external: external) }
            ))
        }
    }

    /// Every size the display offers, plus the current one if it somehow isn't among them.
    private var sizes: [DisplaySize] {
        let all = external.sizes
        guard let current = external.current?.size, !all.contains(current) else { return all }
        return [current] + all
    }
}

/// The displays drawn to scale, as in System Settings > Displays > Arrange. Drag one and it lands
/// flush against the nearest edge, lining up with its neighbour when close; click one and the
/// arrow keys nudge it along its edge a point at a time.
private struct ArrangementCanvas: View {
    @ObservedObject var displays: DisplayController
    @State private var drag: ArrangementDrag?
    /// The arrangement on screen before Core Graphics has it, while nudges wait to be applied.
    @State private var pending: [UInt32: DisplayFrame]?
    @State private var selected: UInt32?
    @State private var applyTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private static let space = "arrangement"
    /// How close an edge comes, in canvas points, before it lines up with its neighbour's.
    private static let snapDistance: CGFloat = 8
    /// How long the arrow keys wait for the next press before moving the real display.
    private static let nudgeDelay = Duration.milliseconds(700)

    private var arranged: [DisplayInfo] { displays.displays.filter { $0.mirrorOf == nil } }
    private var current: [UInt32: DisplayFrame] { Dictionary(uniqueKeysWithValues: arranged.map { ($0.id, $0.frame) }) }
    private var shown: [UInt32: DisplayFrame] { pending ?? current }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let layout = drag?.layout ?? ArrangementLayout(frames: Array(shown.values), size: proxy.size)
                ZStack(alignment: .topLeading) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { selected = nil }
                    ForEach(arranged) { tile($0, layout: layout) }
                    if let drag, let target = drag.target {
                        let rect = layout.rect(target)
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)
                    }
                }
                .coordinateSpace(.named(Self.space))
            }
            .frame(height: 170)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(focused ? 0.18 : 0.08)))
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                nudge(press.key, by: press.modifiers.contains(.shift) ? 10 : 1) ? .handled : .ignored
            }
            Text(caption)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .onChange(of: displays.displays) { _, _ in pending = nil }
        .onDisappear { if applyTask != nil { apply() } }
    }

    private func tile(_ info: DisplayInfo, layout: ArrangementLayout) -> some View {
        let dragging = drag?.id == info.id
        let translation = dragging ? drag?.translation ?? .zero : .zero
        let rect = layout.rect(shown[info.id] ?? info.frame).offsetBy(dx: translation.width, dy: translation.height)
        let isSelected = selected == info.id
        return ZStack(alignment: .top) {
            (info.isBuiltin ? Color.gray : Color.blue).opacity(dragging ? 0.45 : 0.32)
            if info.isMain {
                Color.primary.opacity(0.55).frame(height: max(3, rect.height * 0.08))
            }
            Text(info.name)
                .font(.system(size: 10, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.3), lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { select(info.id) }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                .onChanged { value in dragChanged(info.id, value.translation, layout: layout) }
                .onEnded { _ in dragEnded() }
        )
        .help(info.isMain ? "\(info.name) · has the menu bar" : info.name)
        .position(x: rect.midX, y: rect.midY)
        .zIndex(dragging ? 1 : 0)
    }

    private var caption: String {
        if let drag, let target = drag.target {
            var frames = shown
            frames[drag.id] = target
            return describe(drag.id, in: frames).map { "\($0)." } ?? "Release to place it here."
        }
        if let selected, let line = describe(selected, in: shown) {
            return "\(line). The arrow keys nudge it 1 pt, or 10 pt with ⇧."
        }
        return "Drag a display to move it; it lands against the nearest edge. Click one to nudge it with the arrow keys."
    }

    /// `DELL U2723QE is to the right of Built-in Retina Display, 120 pt lower`
    private func describe(_ id: UInt32, in frames: [UInt32: DisplayFrame]) -> String? {
        guard let placement = DisplayArrangement.placement(of: id, in: frames),
              let name = arranged.first(where: { $0.id == id })?.name,
              let anchor = arranged.first(where: { $0.id == placement.anchor })?.name else { return nil }
        return "\(name) is \(placement.side.phrase) \(anchor), \(placement.detail)"
    }

    private func select(_ id: UInt32) {
        selected = id
        focused = true
    }

    private func dragChanged(_ id: UInt32, _ translation: CGSize, layout: ArrangementLayout) {
        guard let frame = shown[id] else { return }
        var state = drag.flatMap { $0.id == id ? $0 : nil } ?? ArrangementDrag(id: id, layout: layout)
        if drag == nil { select(id) }
        state.translation = translation
        let scale = state.layout.scale
        state.target = DisplayArrangement.snapped(
            id, x: frame.x + Int((translation.width / scale).rounded()), y: frame.y + Int((translation.height / scale).rounded()),
            frames: shown, snap: Int((Self.snapDistance / scale).rounded()))
        drag = state
    }

    private func dragEnded() {
        guard let state = drag else { return }
        drag = nil
        guard let target = state.target else { return }
        var next = shown
        next[state.id] = target
        guard next != shown else { return }
        pending = next
        apply()
    }

    /// True when the key moved, or tried to move, the selected display.
    private func nudge(_ key: KeyEquivalent, by step: Int) -> Bool {
        guard drag == nil, let id = selected, let frame = shown[id] else { return false }
        var x = frame.x
        var y = frame.y
        switch key {
        case .leftArrow: x -= step
        case .rightArrow: x += step
        case .upArrow: y -= step
        case .downArrow: y += step
        default: return false
        }
        guard let moved = DisplayArrangement.snapped(id, x: x, y: y, frames: shown, snap: 0) else { return false }
        var next = shown
        next[id] = moved
        guard next != shown else { return true }
        pending = next
        applyTask?.cancel()
        applyTask = Task {
            try? await Task.sleep(for: Self.nudgeDelay)
            guard !Task.isCancelled else { return }
            apply()
        }
        return true
    }

    private func apply() {
        applyTask?.cancel()
        applyTask = nil
        guard let pending else { return }
        displays.arrange(pending)
        if displays.message != nil { self.pending = nil }
    }
}

private struct ArrangementDrag {
    let id: UInt32
    /// Held for the whole drag, so the canvas doesn't rescale under the pointer.
    let layout: ArrangementLayout
    var translation: CGSize = .zero
    /// Where the display lands if it's let go now.
    var target: DisplayFrame?
}

/// Maps display points onto the canvas: every display scaled to fit, with room around them to drag into.
private struct ArrangementLayout {
    let scale: CGFloat
    let minX: CGFloat
    let minY: CGFloat
    let inset: CGSize

    init(frames: [DisplayFrame], size: CGSize) {
        let margin = CGFloat(frames.map { max($0.width, $0.height) }.max() ?? 1) * 0.15
        let minX = CGFloat(frames.map(\.x).min() ?? 0) - margin
        let minY = CGFloat(frames.map(\.y).min() ?? 0) - margin
        let width = max(1, CGFloat(frames.map(\.maxX).max() ?? 1) + margin - minX)
        let height = max(1, CGFloat(frames.map(\.maxY).max() ?? 1) + margin - minY)
        let scale = max(0.001, min(size.width / width, size.height / height))
        self.scale = scale
        self.minX = minX
        self.minY = minY
        inset = CGSize(width: (size.width - width * scale) / 2, height: (size.height - height * scale) / 2)
    }

    func rect(_ frame: DisplayFrame) -> CGRect {
        CGRect(x: inset.width + (CGFloat(frame.x) - minX) * scale, y: inset.height + (CGFloat(frame.y) - minY) * scale,
               width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
    }
}

/// The external monitor's own brightness over DDC, or dimming the picture when it doesn't take DDC.
private struct BrightnessRow: View {
    @ObservedObject var displays: DisplayController

    var body: some View {
        switch displays.hardwareBrightness {
        case .available:
            SettingsRow("Brightness", help: displays.externals.count > 1 ? "Sets every external monitor." : nil) {
                slider(Binding(get: { displays.brightness }, set: { displays.setBrightness($0) }), in: 0...100)
            }
        case .checking, .unknown:
            SettingsRow("Brightness", help: "Asking the monitor for its brightness…") {
                ProgressView().controlSize(.mini)
            }
        case .unsupported:
            ForEach(displays.externals) { external in
                SettingsRow(displays.externals.count > 1 ? "Dim \(external.name)" : "Dim",
                            help: "The monitor didn't answer a brightness request over DDC, so this darkens the picture instead.") {
                    VStack(alignment: .trailing, spacing: 4) {
                        slider(Binding(get: { displays.dimLevel(external) }, set: { displays.setDimLevel($0, on: external) }),
                               in: 0.2...1)
                        Button("Try the monitor's own brightness") { displays.assumeHardwareBrightness() }
                            .buttonStyle(.link).font(.caption2)
                    }
                }
            }
        }
    }

    private func slider(_ value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sun.min").foregroundStyle(.secondary)
            Slider(value: value, in: range).frame(width: 150).controlSize(.small)
            Image(systemName: "sun.max").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Port killer

private struct PortSection: View {
    let defaults: UserDefaults
    @State private var portText: String
    @State private var results: [ListeningProcess]?
    @State private var lookedUp: Int?
    @State private var looking = false
    @State private var message: String?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        _portText = State(initialValue: defaults.string(forKey: UtilitiesSettings.portKey) ?? "3000")
    }

    var body: some View {
        UtilitySection("port", title: "What's on this port?", subtitle: "Find and stop the process holding a port",
                       symbol: "point.3.connected.trianglepath.dotted", tint: .purple,
                       footer: "Quit asks the process to stop; Force quit kills it straight away. Only your own processes can be stopped.") {
            HStack(spacing: 6) {
                TextField("Port", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 80)
                    .onSubmit(lookUp)
                Menu("Common") {
                    ForEach(PortLookup.commonPorts, id: \.self) { port in
                        Button(String(port)) {
                            portText = String(port)
                            lookUp()
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
                Spacer()
                if looking { ProgressView().controlSize(.mini) }
                Button("Look up", action: lookUp)
                    .controlSize(.small)
                    .disabled(PortLookup.port(portText) == nil || looking)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            if let message {
                ErrorText(message).padding(.horizontal, 10).padding(.bottom, 8)
            }
            if let results, let lookedUp {
                RowDivider()
                if results.isEmpty {
                    Label("Nothing is listening on port \(String(lookedUp)).", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                } else {
                    ForEach(results) { process in
                        ProcessRow(process: process) { force in stop(process, force: force) }
                    }
                }
            }
        } status: {
            if let results, let lookedUp {
                if results.isEmpty {
                    StatusChip("\(String(lookedUp)) is free", tint: .green)
                } else {
                    StatusChip("\(String(lookedUp)) in use", tint: .orange, symbol: "exclamationmark")
                }
            }
        }
        .onChange(of: portText) { _, text in defaults.set(text, forKey: UtilitiesSettings.portKey) }
    }

    private func lookUp() {
        guard let port = PortLookup.port(portText) else {
            message = PortLookupError.invalidPort.localizedDescription
            return
        }
        message = nil
        looking = true
        Task {
            do {
                results = try await PortLookup.listening(on: port)
                lookedUp = port
            } catch {
                message = error.localizedDescription
            }
            looking = false
        }
    }

    private func stop(_ process: ListeningProcess, force: Bool) {
        do {
            try PortLookup.stop(pid: process.pid, force: force)
            message = nil
        } catch {
            message = error.localizedDescription
        }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            lookUp()
        }
    }
}

private struct ProcessRow: View {
    let process: ListeningProcess
    let onStop: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(process.command).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(([("PID \(process.pid)"), process.user] + process.addresses).filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button("Quit") { onStop(false) }.controlSize(.small)
            Button(role: .destructive) { onStop(true) } label: {
                Text("Force quit").foregroundStyle(.red)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.orange.opacity(0.05))
        .contextMenu {
            Button("Copy PID \(process.pid)") { Clipboard.copy(String(process.pid)) }
            Button("Copy kill command") { Clipboard.copy("kill \(process.pid)") }
        }
    }
}

// MARK: - Finder

private struct FinderSection: View {
    @ObservedObject var tab: TabState
    let status: MachineStatus
    @StateObject private var action = UtilityAction()

    var body: some View {
        UtilitySection("finder", title: "Finder & Desktop", subtitle: "Hidden files, desktop icons and extensions",
                       symbol: "folder.fill", tint: .cyan, footer: "Finder restarts to apply a change, closing its windows.") {
            ActionSwitchRow("Show hidden files", help: "Dotfiles such as .zshrc and .gitignore. ⌘⇧. toggles it in a Finder window too.",
                            value: status.showHiddenFiles, action: action, tab: tab, work: MacDefaults.setShowHiddenFiles)
            RowDivider()
            ActionSwitchRow("Hide desktop icons", help: "Clears the desktop for screen sharing. The files stay in ~/Desktop.",
                            value: status.hideDesktopIcons, action: action, tab: tab, work: MacDefaults.setHideDesktopIcons)
            RowDivider()
            ActionSwitchRow("Show all file extensions", value: status.showAllExtensions, action: action, tab: tab,
                            work: MacDefaults.setShowAllExtensions)
            RowDivider()
            SettingsRow("Restart", help: "When Finder or the Dock stops responding.") {
                HStack(spacing: 6) {
                    Button("Finder") { action.run(nil) { try await MacDefaults.restart("Finder") } }
                    Button("Dock") { action.run(nil) { try await MacDefaults.restart("Dock") } }
                }
                .controlSize(.small)
                .disabled(action.running)
            }
            if let message = action.message {
                ErrorText(message).padding(.horizontal, 10).padding(.bottom, 8)
            }
        } status: {
            if action.running {
                ProgressView().controlSize(.mini)
            } else {
                let on = [status.showHiddenFiles ? "Hidden files" : nil, status.hideDesktopIcons ? "No icons" : nil].compactMap { $0 }
                if !on.isEmpty { StatusChip(on.joined(separator: " · "), tint: .cyan) }
            }
        }
    }
}

/// A switch that shows the Mac's setting and runs `work` to change it, holding the new position
/// until the next read catches up.
private struct ActionSwitchRow: View {
    let label: String
    var help: String?
    let value: Bool
    @ObservedObject var action: UtilityAction
    @ObservedObject var tab: TabState
    let work: (Bool) async throws -> Void
    @State private var pending: Bool?

    init(_ label: String, help: String? = nil, value: Bool, action: UtilityAction, tab: TabState,
         work: @escaping (Bool) async throws -> Void) {
        self.label = label
        self.help = help
        self.value = value
        self.action = action
        self.tab = tab
        self.work = work
    }

    var body: some View {
        SwitchRow(label, help: help, isOn: Binding(
            get: { pending ?? value },
            set: { on in
                pending = on
                action.run(tab) { try await work(on) }
            }
        ), disabled: action.running)
        .onChange(of: value) { _, _ in pending = nil }
        .onChange(of: action.running) { _, running in
            if !running, action.message != nil { pending = nil }
        }
    }
}

// MARK: - Screenshots

private struct ScreenshotSection: View {
    @ObservedObject var tab: TabState
    let status: MachineStatus
    @StateObject private var action = UtilityAction()

    private static let clipboardTag = "clipboard"
    private static let chooseTag = "choose"

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var standardFolders: [(String, String)] {
        [("Desktop", "Desktop"), ("Downloads", "Downloads"), ("Documents", "Documents")].map {
            ($0.0, home.appendingPathComponent($0.1).standardizedFileURL.path)
        }
    }

    var body: some View {
        UtilitySection("screenshots", title: "Screenshots & recording", subtitle: "The capture tool and its settings",
                       symbol: "camera.viewfinder", tint: .pink,
                       footer: "The Mac's own settings, also used by ⌘⇧3, ⌘⇧4 and ⌘⇧5. Microphone and click options for recordings are in the tool's Options menu.") {
            ScreenshotToolButton(action: action)
            RowDivider()
            SettingsRow("Save to") {
                Picker("Save to", selection: Binding(get: { currentTag }, set: choose)) {
                    ForEach(Self.standardFolders, id: \.1) { Text($0.0).tag($0.1) }
                    if let custom = customFolder {
                        Text(URL(fileURLWithPath: custom).lastPathComponent).tag(custom)
                    }
                    Divider()
                    Text("Clipboard").tag(Self.clipboardTag)
                    Divider()
                    Text("Choose folder…").tag(Self.chooseTag)
                }
                .labelsHidden().pickerStyle(.menu).fixedSize().controlSize(.small)
                .disabled(action.running)
            }
            RowDivider()
            SettingsRow("Format") {
                Picker("Format", selection: Binding(get: { status.screenshotType }, set: { type in
                    action.run(tab) { try await MacDefaults.setScreenshotType(type) }
                })) {
                    ForEach(MacDefaults.screenshotTypes, id: \.self) { Text($0.uppercased()).tag($0) }
                    if !MacDefaults.screenshotTypes.contains(status.screenshotType) {
                        Text(status.screenshotType.uppercased()).tag(status.screenshotType)
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize().controlSize(.small)
                .disabled(action.running)
            }
            RowDivider()
            SettingsRow("Timer", help: "How long the tool waits after you press Capture or Record.") {
                Picker("Timer", selection: Binding(get: { status.captureDelay }, set: { seconds in
                    action.run(tab) { try await MacDefaults.setCaptureDelay(seconds) }
                })) {
                    ForEach(ScreenshotTool.delays, id: \.self) { Text($0 == 0 ? "None" : "\($0) seconds").tag($0) }
                    if !ScreenshotTool.delays.contains(status.captureDelay) {
                        Text("\(status.captureDelay) seconds").tag(status.captureDelay)
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize().controlSize(.small)
                .disabled(action.running)
            }
            RowDivider()
            ActionSwitchRow("Window shadow", help: "The drop shadow around window screenshots.",
                            value: status.windowShadow, action: action, tab: tab, work: MacDefaults.setWindowShadow)
            RowDivider()
            ActionSwitchRow("Floating thumbnail", help: "The preview in the corner after a capture. Off saves straight away.",
                            value: status.showThumbnail, action: action, tab: tab, work: MacDefaults.setShowThumbnail)
            if let message = action.message {
                ErrorText(message).padding(.horizontal, 10).padding(.bottom, 8)
            }
        } status: {
            StatusChip("\(destinationName) · \(status.screenshotType.uppercased())", tint: .pink)
        }
    }

    /// `Documents`, `Clipboard`, or the custom folder's name.
    private var destinationName: String {
        if status.screenshotToClipboard { return "Clipboard" }
        return Self.standardFolders.first { $0.1 == location }?.0 ?? URL(fileURLWithPath: location).lastPathComponent
    }

    private var location: String {
        status.screenshotLocation.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? Self.standardFolders[0].1
    }

    /// The folder screenshots go to when it isn't one of the standard ones.
    private var customFolder: String? {
        Self.standardFolders.contains { $0.1 == location } ? nil : location
    }

    private var currentTag: String {
        status.screenshotToClipboard ? Self.clipboardTag : location
    }

    private func choose(_ tag: String) {
        switch tag {
        case Self.clipboardTag:
            action.run(tab) { try await MacDefaults.setScreenshotsToClipboard() }
        case Self.chooseTag:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Save screenshots here"
            panel.directoryURL = URL(fileURLWithPath: location)
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            action.run(tab) { try await MacDefaults.setScreenshotLocation(folder) }
        default:
            action.run(tab) { try await MacDefaults.setScreenshotLocation(URL(fileURLWithPath: tag)) }
        }
    }
}

/// Opens macOS's Screenshot tool, which screenshots or records the screen, a window or a selection.
/// The panel closes first so it isn't in the way.
private struct ScreenshotToolButton: View {
    @ObservedObject var action: UtilityAction
    @State private var hovering = false

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .devHubClosePopover, object: nil)
            action.run(nil) { try await ScreenshotTool.launch() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Screenshot tool").font(.system(size: 13, weight: .semibold))
                    Text("Capture or record the screen, a window or a selection")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("⌘⇧5")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.pink.opacity(hovering ? 0.18 : 0.10), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Opens the same toolbar as ⌘⇧5")
        .padding(10)
    }
}

// MARK: - Display & power

private struct PowerSection: View {
    @ObservedObject var tab: TabState
    let status: MachineStatus
    @StateObject private var action = UtilityAction()

    var body: some View {
        UtilitySection("power", title: "Power & screen", subtitle: "Battery, disk space and quick actions",
                       symbol: "bolt.fill", tint: .green) {
            HStack(spacing: 8) {
                if let battery = status.battery {
                    StatTile(title: "Battery", value: "\(battery.percent)%", detail: batteryDetail(battery),
                             symbol: batterySymbol, fraction: Double(battery.percent) / 100, tint: batteryTint(battery))
                }
                if let free = status.freeDisk, let total = status.totalDisk, total > 0 {
                    let used = Double(total - free) / Double(total)
                    StatTile(title: "Disk", value: Format.bytes(free), detail: "free of \(Format.bytes(total))",
                             symbol: "internaldrive.fill", fraction: used, tint: used > 0.9 ? .red : used > 0.8 ? .orange : .blue)
                }
            }
            .padding(10)
            RowDivider()
            HStack(spacing: 6) {
                Button { action.run(nil) { try await MachineInfo.sleepDisplay() } } label: {
                    Label("Sleep display", systemImage: "display")
                }
                Button { action.run(nil) { try await MachineInfo.startScreenSaver() } } label: {
                    Label("Screen saver", systemImage: "sparkles.tv")
                }
                Button { action.run(tab) { try await MachineInfo.toggleDarkMode() } } label: {
                    Label(status.darkMode ? "Light mode" : "Dark mode", systemImage: status.darkMode ? "sun.max" : "moon")
                }
                .help("Switches the whole Mac's appearance. macOS asks once to let Dev Hub control System Events.")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .disabled(action.running)
            .padding(.horizontal, 10).padding(.vertical, 8)
            if let message = action.message {
                ErrorText(message).padding(.horizontal, 10).padding(.bottom, 8)
            }
        } status: {
            if let battery = status.battery {
                StatusChip("\(battery.percent)%", tint: batteryTint(battery), symbol: battery.isCharging ? "bolt.fill" : nil)
            }
        }
    }

    /// `Charging · 1:05 to full`, `On battery · 3:10 left`
    private func batteryDetail(_ battery: BatteryStatus) -> String {
        let parts = battery.line.split(separator: "·").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        let text = parts.joined(separator: " · ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private func batteryTint(_ battery: BatteryStatus) -> Color {
        if battery.isCharging || battery.onAC { return .green }
        return battery.percent <= 10 ? .red : battery.percent <= 20 ? .orange : .green
    }

    private var batterySymbol: String {
        guard let battery = status.battery else { return "internaldrive" }
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.percent {
        case 76...: return "battery.100"
        case 51...: return "battery.75"
        case 26...: return "battery.50"
        case 11...: return "battery.25"
        default: return "battery.0"
        }
    }
}

// MARK: - Dev cleanup

private struct CleanupSection: View {
    @State private var sizes: [CleanupTarget: Int64] = [:]
    @State private var checking = false
    @State private var cleaning: CleanupTarget?
    @State private var confirming: CleanupTarget?
    @State private var message: String?

    var body: some View {
        UtilitySection("cleanup", title: "Dev caches", subtitle: "Free the space Xcode, Yarn and Gradle caches take",
                       symbol: "shippingbox.fill", tint: .orange,
                       footer: "Each is rebuilt or downloaded again by its tool the next time it's needed.") {
            ForEach(Array(CleanupTarget.allCases.enumerated()), id: \.element) { index, target in
                if index > 0 { RowDivider() }
                SettingsRow(target.title, help: sizeText(target)) {
                    HStack(spacing: 6) {
                        if cleaning == target { ProgressView().controlSize(.mini) }
                        Button("Empty…") { confirming = target }
                            .controlSize(.small)
                            .disabled(cleaning != nil || sizes[target] == 0)
                    }
                }
            }
            RowDivider()
            HStack {
                if checking { ProgressView().controlSize(.mini) }
                Spacer()
                Button(sizes.isEmpty ? "Check sizes" : "Check again") { checkSizes() }
                    .controlSize(.small)
                    .disabled(checking || cleaning != nil)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            if let message {
                ErrorText(message).padding(.horizontal, 10).padding(.bottom, 8)
            }
        } status: {
            if checking || cleaning != nil {
                ProgressView().controlSize(.mini)
            } else if !sizes.isEmpty {
                let total = sizes.values.reduce(0, +)
                StatusChip(total == 0 ? "All empty" : "\(Format.bytes(total)) total", tint: total > 5_000_000_000 ? .orange : .secondary)
            }
        }
        .confirmationDialog(confirming.map { "Empty \($0.title)?" } ?? "", isPresented: Binding(
            get: { confirming != nil },
            set: { if !$0 { confirming = nil } }
        ), presenting: confirming) { target in
            Button("Empty \(target.title)", role: .destructive) { clean(target) }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(target.warning)
        }
    }

    private func sizeText(_ target: CleanupTarget) -> String {
        if let size = sizes[target] { return size == 0 ? "Empty" : Format.bytes(size) }
        return checking ? "Checking…" : "Size not checked yet"
    }

    private func checkSizes() {
        checking = true
        message = nil
        Task {
            for target in CleanupTarget.allCases {
                sizes[target] = await DevCleanup.size(of: DevCleanup.directories(target))
            }
            checking = false
        }
    }

    private func clean(_ target: CleanupTarget) {
        cleaning = target
        message = nil
        Task {
            do {
                try await DevCleanup.clean(target)
            } catch {
                message = "Couldn't empty \(target.title): \(error.localizedDescription)"
            }
            sizes[target] = await DevCleanup.size(of: DevCleanup.directories(target))
            cleaning = nil
        }
    }
}

// MARK: - Network

private struct NetworkSection: View {
    let status: MachineStatus
    @State private var keys: [URL] = SSHKeys.publicKeys()
    @State private var selectedKey: URL?

    var body: some View {
        UtilitySection("network", title: "Network", subtitle: "Speed, addresses and your SSH public key",
                       symbol: "wifi", tint: .indigo) {
            LiveSpeedRow()
            RowDivider()
            SpeedTestRow()
            RowDivider()
            SettingsRow("Local IP address", help: status.localIP ?? "Not connected") {
                if let ip = status.localIP { CopyButton(text: ip) }
            }
            RowDivider()
            SettingsRow("Wi-Fi", help: status.wifiName ?? "Not on Wi-Fi, or macOS hides the network name") {
                if let name = status.wifiName { CopyButton(text: name) }
            }
            RowDivider()
            SettingsRow("SSH public key", help: keys.isEmpty ? "No public key in ~/.ssh" : nil) {
                if !keys.isEmpty {
                    HStack(spacing: 6) {
                        if keys.count > 1 {
                            Picker("Key", selection: Binding(get: { key }, set: { selectedKey = $0 })) {
                                ForEach(keys, id: \.self) { Text($0.lastPathComponent).tag(Optional($0)) }
                            }
                            .labelsHidden().pickerStyle(.menu).fixedSize().controlSize(.small)
                        } else if let key {
                            Text(key.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        CopyButton(text: key.flatMap { try? SSHKeys.read($0) } ?? "")
                    }
                }
            }
        } status: {
            if let ip = status.localIP {
                StatusChip(ip, tint: .indigo)
            } else {
                StatusChip("Offline", tint: .red, symbol: "wifi.slash")
            }
        }
        .onAppear { keys = SSHKeys.publicKeys() }
    }

    private var key: URL? {
        selectedKey.flatMap { keys.contains($0) ? $0 : nil } ?? keys.first { $0.lastPathComponent == "id_ed25519.pub" } ?? keys.first
    }
}

/// What the Mac is downloading and uploading right now, updated every second while it's shown.
private struct LiveSpeedRow: View {
    @ObservedObject private var meter = NetworkMeter.shared

    var body: some View {
        SettingsRow("Speed now", help: "Everything this Mac sends and receives over Wi-Fi and Ethernet.") {
            HStack(spacing: 12) {
                SpeedLabel(bits: meter.rate?.download, symbol: "arrow.down", tint: .green)
                SpeedLabel(bits: meter.rate?.upload, symbol: "arrow.up", tint: .blue)
            }
            .font(.system(size: 12, design: .monospaced))
        }
        .onAppear { meter.start() }
        .onDisappear { meter.stop() }
    }
}

/// `↓ 28.0 Mbps` with a coloured arrow: green for download, blue for upload.
private struct SpeedLabel: View {
    let bits: Double?
    let symbol: String
    let tint: Color
    var minWidth: CGFloat = 96

    var body: some View {
        Label {
            Text(bits.map(Format.bitRate) ?? "–")
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .frame(minWidth: minWidth, alignment: .trailing)
    }
}

/// Runs macOS's `networkQuality` against Apple's servers and keeps the last result.
private struct SpeedTestRow: View {
    @ObservedObject private var runner = SpeedTestRunner.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsRow("Speed test", help: help) {
                HStack(spacing: 6) {
                    if runner.running { ProgressView().controlSize(.mini) }
                    Button(runner.running ? "Testing…" : (runner.result == nil ? "Run" : "Run again")) { runner.run() }
                        .controlSize(.small)
                        .disabled(runner.running)
                        .help("Uses macOS's networkQuality, which measures against Apple's servers for up to 20 seconds")
                }
            }
            if let result = runner.result {
                HStack(spacing: 14) {
                    SpeedLabel(bits: result.download, symbol: "arrow.down.circle.fill", tint: .green, minWidth: 0)
                    SpeedLabel(bits: result.upload, symbol: "arrow.up.circle.fill", tint: .blue, minWidth: 0)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                if let latency = latencyLine(result) {
                    Text(latency)
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                }
                Spacer().frame(height: 2)
            }
            if let message = runner.message {
                ErrorText(message).padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
    }

    private var help: String {
        if runner.running { return "Measuring download and upload at the same time, up to 20 seconds…" }
        guard let result = runner.result else { return "Measures your connection's top download and upload speed." }
        let time = result.finishedAt.formatted(date: .omitted, time: .shortened)
        return "Last run at \(time)" + (result.interface.map { " over \($0)" } ?? "")
    }

    /// `Latency 141 ms when idle, 1048 ms when busy`
    private func latencyLine(_ result: SpeedTestResult) -> String? {
        guard let idle = result.idleLatency else { return nil }
        let busy = result.loadedLatency.map { ", \(Int($0.rounded())) ms when busy" } ?? ""
        return "Latency \(Int(idle.rounded())) ms when idle\(busy)"
    }
}
