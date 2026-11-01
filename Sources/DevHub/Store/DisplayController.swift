import AppKit
import Combine
import DevHubCore

/// The display setup the Mac tab shows and changes, re-read whenever a display is plugged in,
/// unplugged or reconfigured.
@MainActor
final class DisplayController: ObservableObject {
    static let shared = DisplayController()

    enum HardwareBrightness: Equatable {
        case unknown, checking, available, unsupported
    }

    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var message: String?
    @Published private(set) var hardwareBrightness: HardwareBrightness = .unknown
    /// 0-100, the external monitors' brightness over DDC.
    @Published private(set) var brightness: Double = 50
    /// 0-1 by display, for software dimming; displays at full brightness are left out.
    @Published private(set) var dimLevels: [UInt32: Double] = [:]
    @Published private(set) var builtinOff = false

    private var savedBuiltinBrightness: Float?
    /// True while Dev Hub has changed some display's colours, so other apps' colour changes are
    /// left alone otherwise.
    private var coloursChanged = false
    private var observer: NSObjectProtocol?
    private var brightnessTask: Task<Void, Never>?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    var builtin: DisplayInfo? { displays.first(where: \.isBuiltin) }
    var externals: [DisplayInfo] { displays.filter { !$0.isBuiltin } }

    func reload() {
        let before = Set(externals.map(\.id))
        displays = Displays.list()
        let ids = Set(displays.map(\.id))
        dimLevels = dimLevels.filter { ids.contains($0.key) }
        if externals.isEmpty {
            // Never leave the only screen dark.
            if builtinOff { setBuiltinOff(false) }
            hardwareBrightness = .unknown
        } else if Set(externals.map(\.id)) != before {
            checkHardwareBrightness()
        }
        applyColours()
    }

    // MARK: Arrangement

    func setMode(_ mode: DisplayModeOption, on display: DisplayInfo) {
        perform { try Displays.setMode(mode, on: display.id) }
    }

    func setSize(_ size: DisplaySize, on display: DisplayInfo) {
        guard let mode = DisplayModes.best(display.modes, size: size, refreshRate: display.current?.refreshRate) else { return }
        setMode(mode, on: display)
    }

    func makeMain(_ display: DisplayInfo) {
        perform { try Displays.makeMain(display.id) }
    }

    func setMirroring(_ on: Bool, external: DisplayInfo) {
        guard let builtin else { return }
        if on, builtinOff { setBuiltinOff(false) }
        perform { try Displays.mirror(external.id, of: on ? builtin.id : nil) }
    }

    /// Moves the displays to `frames`; the main display stays at the origin and the rest follow.
    func arrange(_ frames: [UInt32: DisplayFrame]) {
        guard let main = displays.first(where: \.isMain)?.id else { return }
        perform { try Displays.arrange(frames, main: main) }
    }

    private func perform(_ change: () throws -> Void) {
        message = nil
        do {
            try change()
        } catch {
            message = error.localizedDescription
        }
        reload()
    }

    // MARK: Brightness

    func checkHardwareBrightness() {
        hardwareBrightness = .checking
        Task {
            if let value = await DDCBrightness.shared.readBrightness() {
                brightness = Double(value)
                hardwareBrightness = .available
            } else {
                hardwareBrightness = .unsupported
            }
        }
    }

    /// For a monitor that takes brightness over DDC but doesn't report it.
    func assumeHardwareBrightness() {
        hardwareBrightness = .available
    }

    /// Waits for the slider to settle a moment, since each DDC write takes a while.
    func setBrightness(_ value: Double) {
        brightness = value
        brightnessTask?.cancel()
        brightnessTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            if await !DDCBrightness.shared.setBrightness(Int(value.rounded())) {
                message = "The monitor didn't take the brightness change. Use Dim instead."
                hardwareBrightness = .unsupported
            }
        }
    }

    func dimLevel(_ display: DisplayInfo) -> Double { dimLevels[display.id] ?? 1 }

    func setDimLevel(_ level: Double, on display: DisplayInfo) {
        dimLevels[display.id] = level >= 0.99 ? nil : level
        applyColours()
    }

    // MARK: Built-in screen

    /// Backlight down and picture black while an external display is connected.
    func setBuiltinOff(_ off: Bool) {
        guard let builtin, off != builtinOff else { return }
        if off {
            guard !externals.isEmpty else { return }
            savedBuiltinBrightness = BuiltinBrightness.get(builtin.id)
            BuiltinBrightness.set(builtin.id, 0)
        } else {
            BuiltinBrightness.set(builtin.id, savedBuiltinBrightness ?? 0.5)
            savedBuiltinBrightness = nil
        }
        builtinOff = off
        applyColours()
    }

    /// Puts every display back to its colour profile, then re-applies dimming and the black
    /// built-in screen. A display reconfiguration resets them, so this runs after every reload.
    private func applyColours() {
        let changing = !dimLevels.isEmpty || builtinOff
        guard changing || coloursChanged else { return }
        coloursChanged = changing
        SoftwareDimming.restoreAll()
        for (id, level) in dimLevels where !(builtinOff && id == builtin?.id) {
            SoftwareDimming.set(id, level: level)
        }
        if builtinOff, let builtin { SoftwareDimming.set(builtin.id, level: 0) }
    }

    /// Called when Dev Hub quits: the built-in screen and every display's colours come back.
    func restore() {
        if builtinOff { setBuiltinOff(false) }
        dimLevels = [:]
        applyColours()
    }
}
