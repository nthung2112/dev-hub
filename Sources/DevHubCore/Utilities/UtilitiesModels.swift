import Foundation

/// Mac tab settings, kept under `utilities.*` in the app's defaults.
public enum UtilitiesSettings {
    /// The Keep Awake checkboxes last used, as `CaffeinateOptions.rawValue`.
    public static let caffeinateOptionsKey = "utilities.caffeinate.options"
    /// The Keep Awake duration last used, as `CaffeinateDuration.rawValue`.
    public static let caffeinateDurationKey = "utilities.caffeinate.duration"
    /// The last port looked up.
    public static let portKey = "utilities.port"
}

/// `82%; charging; 1:05 remaining` from `pmset -g batt`.
public struct BatteryStatus: Sendable, Codable, Equatable {
    public let percent: Int
    /// `charging`, `discharging`, `charged`, `AC attached`, `finishing charge`
    public let state: String
    public let onAC: Bool
    /// `1:05`; nil while macOS has no estimate.
    public let remaining: String?

    public init(percent: Int, state: String, onAC: Bool, remaining: String?) {
        self.percent = percent
        self.state = state
        self.onAC = onAC
        self.remaining = remaining
    }

    public var isCharging: Bool { state == "charging" || state == "finishing charge" }

    /// `82% · charging · 1:05 to full`, `54% · on battery · 3:10 left`.
    public var line: String {
        var parts = ["\(percent)%"]
        if isCharging {
            parts.append("charging")
            if let remaining { parts.append("\(remaining) to full") }
        } else if onAC {
            parts.append(state == "charged" ? "charged" : "on power")
        } else {
            parts.append("on battery")
            if let remaining { parts.append("\(remaining) left") }
        }
        return parts.joined(separator: " · ")
    }
}

/// The Mac's state the Mac tab shows: power, disk, network and the settings its switches change.
public struct MachineStatus: MonitorDetail, Equatable {
    /// Nil on a Mac without a battery.
    public var battery: BatteryStatus?
    public var freeDisk: Int64?
    public var totalDisk: Int64?
    public var localIP: String?
    /// Nil when not on Wi-Fi or macOS hides the network name.
    public var wifiName: String?
    public var showHiddenFiles: Bool
    public var hideDesktopIcons: Bool
    public var showAllExtensions: Bool
    /// The folder screenshots go to; nil means the Desktop.
    public var screenshotLocation: String?
    /// `png`, `jpg`, `pdf`, …
    public var screenshotType: String
    /// True when screenshots go to the clipboard instead of a file.
    public var screenshotToClipboard: Bool
    /// Window screenshots keep their drop shadow.
    public var windowShadow: Bool
    /// The preview that floats in the corner after a capture.
    public var showThumbnail: Bool
    /// Seconds the Screenshot tool waits before capturing.
    public var captureDelay: Int
    public var darkMode: Bool
    public var fetchedAt: Date

    public init(battery: BatteryStatus? = nil, freeDisk: Int64? = nil, totalDisk: Int64? = nil, localIP: String? = nil,
                wifiName: String? = nil, showHiddenFiles: Bool = false, hideDesktopIcons: Bool = false,
                showAllExtensions: Bool = false, screenshotLocation: String? = nil, screenshotType: String = "png",
                screenshotToClipboard: Bool = false, windowShadow: Bool = true, showThumbnail: Bool = true,
                captureDelay: Int = 0, darkMode: Bool = false, fetchedAt: Date) {
        self.battery = battery
        self.freeDisk = freeDisk
        self.totalDisk = totalDisk
        self.localIP = localIP
        self.wifiName = wifiName
        self.showHiddenFiles = showHiddenFiles
        self.hideDesktopIcons = hideDesktopIcons
        self.showAllExtensions = showAllExtensions
        self.screenshotLocation = screenshotLocation
        self.screenshotType = screenshotType
        self.screenshotToClipboard = screenshotToClipboard
        self.windowShadow = windowShadow
        self.showThumbnail = showThumbnail
        self.captureDelay = captureDelay
        self.darkMode = darkMode
        self.fetchedAt = fetchedAt
    }

    /// `120 GB free of 494 GB`
    public var diskLine: String? {
        guard let freeDisk else { return nil }
        let free = Format.bytes(freeDisk)
        return totalDisk.map { "\(free) free of \(Format.bytes($0))" } ?? "\(free) free"
    }
}

extension Format {
    /// `1.2 GB`, `340 MB`, as Finder shows sizes.
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
