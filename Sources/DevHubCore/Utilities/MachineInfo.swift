import Foundation

/// Reads the Mac's state for the Mac tab, and runs its quick actions.
public enum MachineInfo {
    static let pmset = URL(fileURLWithPath: "/usr/bin/pmset")
    static let ipconfig = URL(fileURLWithPath: "/usr/sbin/ipconfig")
    static let route = URL(fileURLWithPath: "/sbin/route")
    static let networksetup = URL(fileURLWithPath: "/usr/sbin/networksetup")
    static let open = URL(fileURLWithPath: "/usr/bin/open")
    static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")

    public static func read(now: Date = Date()) async -> MachineStatus {
        async let battery = readBattery()
        async let ip = readLocalIP()
        async let wifi = readWifiName()
        async let hidden = MacDefaults.readBool(MacDefaults.finder, "AppleShowAllFiles")
        async let desktop = MacDefaults.readBool(MacDefaults.finder, "CreateDesktop")
        async let extensions = MacDefaults.readBool(MacDefaults.global, "AppleShowAllExtensions")
        async let location = MacDefaults.readString(MacDefaults.screencapture, "location")
        async let type = MacDefaults.readString(MacDefaults.screencapture, "type")
        async let target = MacDefaults.readString(MacDefaults.screencapture, "target")
        async let style = MacDefaults.readString(MacDefaults.global, "AppleInterfaceStyle")
        async let noShadow = MacDefaults.readBool(MacDefaults.screencapture, "disable-shadow")
        async let thumbnail = MacDefaults.readBool(MacDefaults.screencapture, "show-thumbnail")
        async let delay = MacDefaults.readString(MacDefaults.screencapture, "captureDelay")
        let disk = readDisk()
        return await MachineStatus(
            battery: battery, freeDisk: disk.free, totalDisk: disk.total, localIP: ip, wifiName: wifi,
            showHiddenFiles: hidden ?? false, hideDesktopIcons: !(desktop ?? true), showAllExtensions: extensions ?? false,
            screenshotLocation: location.map(MacDefaults.expand), screenshotType: type ?? "png",
            screenshotToClipboard: target == "clipboard", windowShadow: !(noShadow ?? false), showThumbnail: thumbnail ?? true,
            captureDelay: delay.flatMap { Int($0) } ?? 0, darkMode: style?.lowercased() == "dark", fetchedAt: now
        )
    }

    // MARK: Battery

    static func readBattery() async -> BatteryStatus? {
        guard let result = try? await Shell.run(pmset, ["-g", "batt"]), result.succeeded else { return nil }
        return parseBattery(result.stdout)
    }

    /// `Now drawing from 'AC Power'` then ` -InternalBattery-0 (id=…)\t100%; charged; 0:00 remaining present: true`.
    /// Nil when there's no battery line, as on a Mac mini.
    static func parseBattery(_ output: String) -> BatteryStatus? {
        let onAC = output.contains("'AC Power'")
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.contains("%;") }) else { return nil }
        let fields = line.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = fields.first, let percentField = first.split(whereSeparator: \.isWhitespace).last,
              percentField.hasSuffix("%"), let percent = Int(percentField.dropLast())
        else { return nil }
        let state = fields.count > 1 ? fields[1] : ""
        var remaining: String?
        if fields.count > 2, let time = fields[2].split(separator: " ").first, time.contains(":"), time != "0:00" {
            remaining = String(time)
        }
        return BatteryStatus(percent: percent, state: state, onAC: onAC, remaining: remaining)
    }

    // MARK: Disk

    static func readDisk() -> (free: Int64?, total: Int64?) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ])
        return (values?.volumeAvailableCapacityForImportantUsage, values?.volumeTotalCapacity.map(Int64.init))
    }

    // MARK: Network

    /// The address on the interface the default route uses, else on en0 or en1.
    static func readLocalIP() async -> String? {
        var interfaces = ["en0", "en1"]
        if let result = try? await Shell.run(route, ["-n", "get", "default"], timeout: 5), let primary = parseRouteInterface(result.stdout) {
            interfaces.insert(primary, at: 0)
        }
        for interface in interfaces {
            if let result = try? await Shell.run(ipconfig, ["getifaddr", interface], timeout: 5), result.succeeded {
                let address = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !address.isEmpty { return address }
            }
        }
        return nil
    }

    /// `interface: en0` from `route -n get default`.
    static func parseRouteInterface(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "interface", !parts[1].isEmpty { return parts[1] }
        }
        return nil
    }

    static func readWifiName() async -> String? {
        guard let ports = try? await Shell.run(networksetup, ["-listallhardwareports"], timeout: 5),
              let device = parseWifiDevice(ports.stdout),
              let result = try? await Shell.run(networksetup, ["-getairportnetwork", device], timeout: 5)
        else { return nil }
        return parseWifiName(result.stdout)
    }

    /// The `Device:` line after `Hardware Port: Wi-Fi`.
    static func parseWifiDevice(_ output: String) -> String? {
        var inWifi = false
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("Hardware Port:") {
                inWifi = line.contains("Wi-Fi") || line.contains("AirPort")
            } else if inWifi, line.hasPrefix("Device:") {
                let device = line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
                return device.isEmpty ? nil : device
            }
        }
        return nil
    }

    /// `Current Wi-Fi Network: Office`; nil when not associated or the name is hidden.
    static func parseWifiName(_ output: String) -> String? {
        let prefix = "Current Wi-Fi Network:"
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let name = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == "<redacted>" ? nil : name
    }

    // MARK: Quick actions

    public static func sleepDisplay() async throws {
        try await Shell.check(pmset, ["displaysleepnow"])
    }

    public static func startScreenSaver() async throws {
        try await Shell.check(open, ["-a", "ScreenSaverEngine"])
    }

    /// Asks System Events, which needs Automation permission: macOS asks the first time, so this
    /// waits for an answer.
    public static func toggleDarkMode() async throws {
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
        let result = try await Shell.run(osascript, ["-e", script], timeout: 120)
        guard result.succeeded else {
            if result.stderr.contains("-1743") {
                throw ShellError.failed(command: "Dark mode",
                                        message: "Dev Hub isn't allowed to control System Events. Allow it in System Settings > Privacy & Security > Automation.")
            }
            throw ShellError.failed(command: "Dark mode", message: result.message)
        }
    }
}

/// The public halves of the SSH keys in `~/.ssh`. Private keys are never opened.
public enum SSHKeys {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    }

    public static func publicKeys(in directory: URL = directory) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "pub" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func read(_ file: URL) throws -> String {
        guard file.pathExtension == "pub" else { throw CocoaError(.fileReadNoPermission) }
        return try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
