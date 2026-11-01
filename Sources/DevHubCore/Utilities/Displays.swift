import AppKit
import CoreGraphics
import Foundation

/// One way a display can run: its size in points, its pixels, and its refresh rate.
public struct DisplayModeOption: Sendable, Equatable, Hashable, Identifiable {
    /// `CGDisplayMode.ioDisplayModeID`, unique per display.
    public let id: Int32
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Hz; 0 when the display doesn't say.
    public let refreshRate: Double

    public init(id: Int32, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double) {
        self.id = id
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
    }

    /// Drawn at twice the pixels, so text stays sharp.
    public var isHiDPI: Bool { pixelWidth > width }

    public var size: DisplaySize { DisplaySize(width: width, height: height, hiDPI: isHiDPI) }

    /// `120 Hz`, `59.94 Hz`
    public var refreshLabel: String {
        guard refreshRate > 0 else { return "Default" }
        let rounded = (refreshRate * 100).rounded() / 100
        return rounded == rounded.rounded() ? "\(Int(rounded)) Hz" : String(format: "%.2f Hz", rounded)
    }
}

/// What a resolution looks like on screen, whatever its refresh rate.
public struct DisplaySize: Sendable, Equatable, Hashable, Identifiable {
    public let width: Int
    public let height: Int
    public let hiDPI: Bool

    public var id: String { "\(width)x\(height)\(hiDPI ? "@2x" : "")" }

    /// `1920 × 1080 (HiDPI)`, `2560 × 1440`
    public var label: String { "\(width) × \(height)" + (hiDPI ? " (HiDPI)" : "") }
}

/// Where a display sits. The main display's origin is (0, 0) and y grows downward, which is
/// Core Graphics' global display space, the same space `CGConfigureDisplayOrigin` writes.
public struct DisplayFrame: Sendable, Equatable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
}

/// Which edge of another display this one sits against.
public enum DisplaySide: String, CaseIterable, Sendable {
    case left, above, right, below

    var isBeside: Bool { self == .left || self == .right }

    /// `to the left of`, `above`, so it reads in a sentence.
    public var phrase: String {
        switch self {
        case .left: return "to the left of"
        case .right: return "to the right of"
        case .above: return "above"
        case .below: return "below"
        }
    }
}

/// How a display lines up against the neighbour it shares the most edge with.
public struct DisplayPlacement: Sendable, Equatable {
    public enum Alignment: Sendable, Equatable {
        case start, centre, end
    }

    public let anchor: UInt32
    public let side: DisplaySide
    /// Points from the anchor's top (beside it) or left edge (above or below it) to this display's.
    public let offset: Int
    public let alignment: Alignment?

    /// `tops aligned`, `centred`, `120 pt lower`
    public var detail: String {
        switch (alignment, side.isBeside) {
        case (.start?, true): return "tops aligned"
        case (.end?, true): return "bottoms aligned"
        case (.start?, false): return "left edges aligned"
        case (.end?, false): return "right edges aligned"
        case (.centre?, _): return "centred"
        case (nil, true): return offset > 0 ? "\(offset) pt lower" : "\(-offset) pt higher"
        case (nil, false): return offset > 0 ? "\(offset) pt to the right" : "\(-offset) pt to the left"
        }
    }
}

/// A connected display and how it's set up.
public struct DisplayInfo: Sendable, Equatable, Identifiable {
    /// `CGDirectDisplayID`
    public let id: UInt32
    public let name: String
    public let isBuiltin: Bool
    public let isMain: Bool
    /// The display this one shows a copy of, when mirroring.
    public let mirrorOf: UInt32?
    public let frame: DisplayFrame
    public let current: DisplayModeOption?
    public let modes: [DisplayModeOption]

    public init(id: UInt32, name: String, isBuiltin: Bool, isMain: Bool, mirrorOf: UInt32?, frame: DisplayFrame,
                current: DisplayModeOption?, modes: [DisplayModeOption]) {
        self.id = id
        self.name = name
        self.isBuiltin = isBuiltin
        self.isMain = isMain
        self.mirrorOf = mirrorOf
        self.frame = frame
        self.current = current
        self.modes = modes
    }

    /// `2560 × 1440 · 60 Hz · HiDPI`
    public var summary: String {
        guard let current else { return "Unknown mode" }
        var parts = ["\(current.width) × \(current.height)"]
        if current.refreshRate > 0 { parts.append(current.refreshLabel) }
        if current.isHiDPI { parts.append("HiDPI") }
        return parts.joined(separator: " · ")
    }

    public var sizes: [DisplaySize] { DisplayModes.sizes(modes) }
}

public enum DisplayError: Error, LocalizedError, Equatable {
    case failed(String, Int32)
    case modeGone

    public var errorDescription: String? {
        switch self {
        case .failed(let action, let code): return "Couldn't \(action) (Core Graphics error \(code))."
        case .modeGone: return "That display mode isn't available any more. The display may have been unplugged."
        }
    }
}

public enum DisplayModes {
    /// Each size once, largest first, with HiDPI before the plain size of the same points.
    public static func sizes(_ modes: [DisplayModeOption]) -> [DisplaySize] {
        var seen: Set<DisplaySize> = []
        return modes.map(\.size).filter { seen.insert($0).inserted }.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.hiDPI && !$1.hiDPI
        }
    }

    /// The modes for `size`, fastest refresh first.
    public static func refreshOptions(_ modes: [DisplayModeOption], size: DisplaySize) -> [DisplayModeOption] {
        var seen: Set<Double> = []
        return modes.filter { $0.size == size }.sorted { $0.refreshRate > $1.refreshRate }.filter { seen.insert($0.refreshRate).inserted }
    }

    /// The mode for `size` closest to `refreshRate`, so changing resolution keeps the refresh rate
    /// when it can.
    public static func best(_ modes: [DisplayModeOption], size: DisplaySize, refreshRate: Double?) -> DisplayModeOption? {
        let options = refreshOptions(modes, size: size)
        guard let refreshRate else { return options.first }
        return options.min { abs($0.refreshRate - refreshRate) < abs($1.refreshRate - refreshRate) }
    }
}

/// Works out arrangements without touching the hardware, so they can be checked on their own.
public enum DisplayArrangement {
    /// Neighbours share at least this much edge, in points, or the shorter display's whole edge.
    static let minimumShared = 40

    /// Where `moving` lands when dropped with its top-left corner at (`x`, `y`): flush against the
    /// nearest edge of another display without covering any, kept where it was dropped along that
    /// edge, and pulled onto the neighbour's top, centre or bottom (left, centre or right) when
    /// within `snap` points. A spot that keeps every display joined beats a closer one that would
    /// leave one floating. Nil when the display is missing or is the only one.
    public static func snapped(_ moving: UInt32, x: Int, y: Int, frames: [UInt32: DisplayFrame], snap: Int) -> DisplayFrame? {
        guard var dropped = frames[moving], dropped.width > 0, dropped.height > 0 else { return nil }
        dropped.x = x
        dropped.y = y
        let others = frames.keys.sorted().filter { $0 != moving }.compactMap { frames[$0] }
        let candidates = others.flatMap { other in
            DisplaySide.allCases.map { flush(dropped, against: other, on: $0, snap: snap) }
        }
        .filter { candidate in !others.contains { intersects(candidate, $0) } }
        .map { candidate -> (frame: DisplayFrame, joined: Bool, distance: Int) in
            var all = frames
            all[moving] = candidate
            let dx = candidate.x - x
            let dy = candidate.y - y
            return (candidate, connected(all.keys.sorted().compactMap { all[$0] }), dx * dx + dy * dy)
        }
        return candidates.min { ($0.joined ? 0 : 1, $0.distance) < ($1.joined ? 0 : 1, $1.distance) }?.frame
    }

    /// Shifts every display so `main` is at the origin, where Core Graphics keeps the menu bar's screen.
    public static func normalized(_ frames: [UInt32: DisplayFrame], main: UInt32) -> [UInt32: DisplayFrame] {
        guard let origin = frames[main], origin.x != 0 || origin.y != 0 else { return frames }
        return frames.mapValues { frame in
            var frame = frame
            frame.x -= origin.x
            frame.y -= origin.y
            return frame
        }
    }

    /// The neighbour `id` shares the longest edge with, and how it lines up against it.
    public static func placement(of id: UInt32, in frames: [UInt32: DisplayFrame]) -> DisplayPlacement? {
        guard let frame = frames[id] else { return nil }
        var best: (shared: Int, placement: DisplayPlacement)?
        for other in frames.keys.sorted() where other != id {
            guard let anchor = frames[other], let side = side(of: frame, against: anchor) else { continue }
            let (start, length, anchorStart, anchorLength) = side.isBeside
                ? (frame.y, frame.height, anchor.y, anchor.height)
                : (frame.x, frame.width, anchor.x, anchor.width)
            let shared = overlap(start, length, anchorStart, anchorLength)
            guard shared > (best?.shared ?? 0) else { continue }
            let offset = start - anchorStart
            let alignment: DisplayPlacement.Alignment?
            if offset == 0 {
                alignment = .start
            } else if start + length == anchorStart + anchorLength {
                alignment = .end
            } else if abs(2 * start + length - 2 * anchorStart - anchorLength) <= 1 {
                alignment = .centre
            } else {
                alignment = nil
            }
            best = (shared, DisplayPlacement(anchor: other, side: side, offset: offset, alignment: alignment))
        }
        return best?.placement
    }

    private static func flush(_ frame: DisplayFrame, against anchor: DisplayFrame, on side: DisplaySide, snap: Int) -> DisplayFrame {
        var placed = frame
        switch side {
        case .right: placed.x = anchor.maxX
        case .left: placed.x = anchor.x - frame.width
        case .below: placed.y = anchor.maxY
        case .above: placed.y = anchor.y - frame.height
        }
        if side.isBeside {
            placed.y = along(frame.y, frame.height, anchor.y, anchor.height, snap: snap)
        } else {
            placed.x = along(frame.x, frame.width, anchor.x, anchor.width, snap: snap)
        }
        return placed
    }

    /// The position along the shared edge: where it was dropped, pulled onto the anchor's start,
    /// centre or end when within `snap`, and held to enough shared edge to stay joined.
    private static func along(_ start: Int, _ length: Int, _ anchorStart: Int, _ anchorLength: Int, snap: Int) -> Int {
        let shared = min(minimumShared, length, anchorLength)
        let lowest = anchorStart - length + shared
        let highest = anchorStart + anchorLength - shared
        let targets = [anchorStart, anchorStart + (anchorLength - length) / 2, anchorStart + anchorLength - length]
        let nearest = targets.min { abs($0 - start) < abs($1 - start) } ?? start
        let position = snap > 0 && abs(nearest - start) <= snap ? nearest : start
        return min(highest, max(lowest, position))
    }

    /// Which edge of `anchor` `frame` touches along a stretch longer than a corner.
    private static func side(of frame: DisplayFrame, against anchor: DisplayFrame) -> DisplaySide? {
        let sharesRows = overlap(frame.y, frame.height, anchor.y, anchor.height) > 0
        let sharesColumns = overlap(frame.x, frame.width, anchor.x, anchor.width) > 0
        if sharesRows, frame.x == anchor.maxX { return .right }
        if sharesRows, frame.maxX == anchor.x { return .left }
        if sharesColumns, frame.y == anchor.maxY { return .below }
        if sharesColumns, frame.maxY == anchor.y { return .above }
        return nil
    }

    /// True when every display can be reached from the first through touching edges.
    static func connected(_ frames: [DisplayFrame]) -> Bool {
        guard !frames.isEmpty else { return true }
        var reached: Set<Int> = [0]
        var queue = [0]
        while let index = queue.popLast() {
            for other in frames.indices where !reached.contains(other) && side(of: frames[other], against: frames[index]) != nil {
                reached.insert(other)
                queue.append(other)
            }
        }
        return reached.count == frames.count
    }

    private static func overlap(_ start: Int, _ length: Int, _ otherStart: Int, _ otherLength: Int) -> Int {
        min(start + length, otherStart + otherLength) - max(start, otherStart)
    }

    private static func intersects(_ a: DisplayFrame, _ b: DisplayFrame) -> Bool {
        a.x < b.maxX && b.x < a.maxX && a.y < b.maxY && b.y < a.maxY
    }
}

/// Reads and changes the display setup through Core Graphics, as System Settings > Displays does.
/// None of it needs admin rights.
public enum Displays {
    public static func list() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        let names = screenNames()
        let main = CGMainDisplayID()
        return ids.prefix(Int(count)).map { id in
            let builtin = CGDisplayIsBuiltin(id) != 0
            let mirror = CGDisplayMirrorsDisplay(id)
            let bounds = CGDisplayBounds(id)
            return DisplayInfo(
                id: id, name: names[id] ?? (builtin ? "Built-in display" : "External display"), isBuiltin: builtin,
                isMain: id == main, mirrorOf: mirror == kCGNullDirectDisplay ? nil : mirror,
                frame: DisplayFrame(x: Int(bounds.origin.x.rounded()), y: Int(bounds.origin.y.rounded()),
                                    width: Int(bounds.width.rounded()), height: Int(bounds.height.rounded())),
                current: CGDisplayCopyDisplayMode(id).map(option), modes: modes(id).map(option)
            )
        }.sorted { ($0.isBuiltin ? 0 : 1, $0.id) < ($1.isBuiltin ? 0 : 1, $1.id) }
    }

    /// `DELL U2723QE` by display ID. A display mirroring another isn't an `NSScreen`, so it has no name here.
    static func screenNames() -> [CGDirectDisplayID: String] {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[key] as? NSNumber { names[number.uint32Value] = screen.localizedName }
        }
        return names
    }

    static func modes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        return all.filter { $0.isUsableForDesktopGUI() }
    }

    static func option(_ mode: CGDisplayMode) -> DisplayModeOption {
        DisplayModeOption(id: mode.ioDisplayModeID, width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                          pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate)
    }

    public static func setMode(_ option: DisplayModeOption, on display: UInt32) throws {
        guard let mode = modes(display).first(where: { self.option($0) == option }) else { throw DisplayError.modeGone }
        try configure("change the resolution") { config in
            CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
        }
    }

    /// Moves the menu bar and Dock to `display` by putting it at the origin and shifting the others
    /// with it, so the arrangement stays the same.
    public static func makeMain(_ display: UInt32) throws {
        let origin = CGDisplayBounds(display).origin
        guard origin != .zero else { return }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        try configure("make it the main display") { config in
            for id in ids.prefix(Int(count)) {
                let bounds = CGDisplayBounds(id)
                let error = CGConfigureDisplayOrigin(config, id, Int32(bounds.origin.x - origin.x), Int32(bounds.origin.y - origin.y))
                if error != .success { return error }
            }
            return .success
        }
    }

    /// Moves each display's top-left corner to its frame's, shifted so `main` stays at the origin.
    public static func arrange(_ frames: [UInt32: DisplayFrame], main: UInt32) throws {
        let arranged = DisplayArrangement.normalized(frames, main: main)
        try configure("rearrange the displays") { config in
            for id in arranged.keys.sorted() {
                guard let frame = arranged[id] else { continue }
                let error = CGConfigureDisplayOrigin(config, id, Int32(clamping: frame.x), Int32(clamping: frame.y))
                if error != .success { return error }
            }
            return .success
        }
    }

    /// Shows `source` on `display` too, or stops when `source` is nil.
    public static func mirror(_ display: UInt32, of source: UInt32?) throws {
        try configure(source == nil ? "stop mirroring" : "mirror the display") { config in
            CGConfigureDisplayMirrorOfDisplay(config, display, source ?? kCGNullDirectDisplay)
        }
    }

    private static func configure(_ action: String, _ change: (CGDisplayConfigRef) -> CGError) throws {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else { throw DisplayError.failed(action, begin.rawValue) }
        let changed = change(config)
        guard changed == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError.failed(action, changed.rawValue)
        }
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        guard complete == .success else { throw DisplayError.failed(action, complete.rawValue) }
    }
}
