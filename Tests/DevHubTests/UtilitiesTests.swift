import Foundation
import Testing
@testable import DevHubCore

@Suite struct CaffeinateTests {
    @Test func standardOptionsForAnHour() {
        #expect(Caffeinate.arguments(options: .standard, duration: .hour1, pid: 42) == ["-d", "-i", "-t", "3600", "-w", "42"])
    }

    @Test func everyOptionUntilStopped() {
        let all: CaffeinateOptions = [.display, .idle, .system, .disk]
        #expect(Caffeinate.arguments(options: all, duration: .untilStopped, pid: 7) == ["-d", "-i", "-m", "-s", "-w", "7"])
    }

    @Test func noOptionFallsBackToIdle() {
        #expect(Caffeinate.arguments(options: [], duration: .minutes15, pid: 1) == ["-i", "-t", "900", "-w", "1"])
    }

    @Test func displayOnly() {
        #expect(Caffeinate.arguments(options: .display, duration: .hours4, pid: 9) == ["-d", "-t", "14400", "-w", "9"])
    }

    @Test func everyDurationHasALabelAndOnlyUntilStoppedHasNoTimer() {
        for duration in CaffeinateDuration.allCases {
            #expect(!duration.label.isEmpty)
            #expect((duration.seconds == nil) == (duration == .untilStopped))
        }
    }

    @Test func stateLine() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(KeepAwakeState(startedAt: start, endsAt: nil).line == "Awake until stopped")
        #expect(KeepAwakeState(startedAt: start, endsAt: start.addingTimeInterval(60)).line.hasPrefix("Awake until "))
    }
}

@Suite struct PortLookupTests {
    @Test func parsesSeveralProcesses() {
        let output = """
        p1692
        cfigma_agent
        LP010813
        f3
        n127.0.0.1:3000
        f16
        n[::1]:3000
        p20871
        cMicrosoft Edge
        LP010813
        f58
        n*:3000
        """
        let processes = PortLookup.parse(output)
        #expect(processes == [
            ListeningProcess(pid: 1692, command: "figma_agent", user: "P010813", addresses: ["127.0.0.1:3000", "[::1]:3000"]),
            ListeningProcess(pid: 20871, command: "Microsoft Edge", user: "P010813", addresses: ["*:3000"]),
        ])
    }

    @Test func emptyOutputIsNothing() {
        #expect(PortLookup.parse("").isEmpty)
    }

    @Test func repeatedAddressIsListedOnce() {
        let processes = PortLookup.parse("p5\ncnode\nf1\nn*:8080\nf2\nn*:8080\n")
        #expect(processes.first?.addresses == ["*:8080"])
        #expect(processes.first?.user == "")
    }

    @Test func validatesPorts() {
        #expect(PortLookup.port("3000") == 3000)
        #expect(PortLookup.port(" 8080 ") == 8080)
        #expect(PortLookup.port("1") == 1)
        #expect(PortLookup.port("65535") == 65535)
        #expect(PortLookup.port("0") == nil)
        #expect(PortLookup.port("65536") == nil)
        #expect(PortLookup.port("-1") == nil)
        #expect(PortLookup.port("http") == nil)
        #expect(PortLookup.port("") == nil)
    }

    @Test func refusesAnInvalidPort() async {
        await #expect(throws: PortLookupError.invalidPort) { try await PortLookup.listening(on: 0) }
    }

    @Test func stoppingAMissingProcessSaysItExited() {
        #expect(throws: PortLookupError.alreadyExited(pid: 999_999)) { try PortLookup.stop(pid: 999_999) }
    }
}

@Suite struct BatteryParsingTests {
    @Test func chargedOnPower() throws {
        let output = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=35913827)\t100%; charged; 0:00 remaining present: true\n"
        let battery = try #require(MachineInfo.parseBattery(output))
        #expect(battery == BatteryStatus(percent: 100, state: "charged", onAC: true, remaining: nil))
        #expect(battery.line == "100% · charged")
    }

    @Test func charging() throws {
        let output = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t82%; charging; 1:05 remaining present: true\n"
        let battery = try #require(MachineInfo.parseBattery(output))
        #expect(battery.isCharging)
        #expect(battery.line == "82% · charging · 1:05 to full")
    }

    @Test func discharging() throws {
        let output = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t54%; discharging; 3:10 remaining present: true\n"
        let battery = try #require(MachineInfo.parseBattery(output))
        #expect(battery == BatteryStatus(percent: 54, state: "discharging", onAC: false, remaining: "3:10"))
        #expect(battery.line == "54% · on battery · 3:10 left")
    }

    @Test func noEstimateYet() throws {
        let output = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t97%; discharging; (no estimate) present: true\n"
        let battery = try #require(MachineInfo.parseBattery(output))
        #expect(battery.remaining == nil)
        #expect(battery.line == "97% · on battery")
    }

    @Test func noBattery() {
        #expect(MachineInfo.parseBattery("Now drawing from 'AC Power'\n") == nil)
    }
}

@Suite struct NetworkParsingTests {
    @Test func routeInterface() {
        let output = "   route to: default\ndestination: default\n    gateway: 10.0.0.1\n  interface: en0\n      flags: <UP,GATEWAY>\n"
        #expect(MachineInfo.parseRouteInterface(output) == "en0")
        #expect(MachineInfo.parseRouteInterface("route: writing to routing socket: not in table") == nil)
    }

    @Test func wifiDevice() {
        let output = """

        Hardware Port: Ethernet Adapter (en4)
        Device: en4
        Ethernet Address: a2:25:35:ce:a4:5e

        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: 3c:06:30:00:00:00
        """
        #expect(MachineInfo.parseWifiDevice(output) == "en0")
        #expect(MachineInfo.parseWifiDevice("Hardware Port: Thunderbolt Bridge\nDevice: bridge0\n") == nil)
    }

    @Test func wifiName() {
        #expect(MachineInfo.parseWifiName("Current Wi-Fi Network: Office 5G\n") == "Office 5G")
        #expect(MachineInfo.parseWifiName("You are not associated with an AirPort network.\n") == nil)
        #expect(MachineInfo.parseWifiName("Current Wi-Fi Network: <redacted>\n") == nil)
    }
}

@Suite struct MacDefaultsTests {
    @Test func boolValues() {
        #expect(MacDefaults.parseBool(ShellResult(status: 0, stdout: "1\n")) == true)
        #expect(MacDefaults.parseBool(ShellResult(status: 0, stdout: "TRUE\n")) == true)
        #expect(MacDefaults.parseBool(ShellResult(status: 0, stdout: "YES")) == true)
        #expect(MacDefaults.parseBool(ShellResult(status: 0, stdout: "0\n")) == false)
        #expect(MacDefaults.parseBool(ShellResult(status: 0, stdout: "no")) == false)
        #expect(MacDefaults.parseBool(ShellResult(status: 0, stdout: "maybe")) == nil)
    }

    @Test func missingKeyIsNil() {
        let missing = ShellResult(status: 1, stdout: "", stderr: "The domain/default pair of (com.apple.finder, AppleShowAllFiles) does not exist")
        #expect(MacDefaults.parseBool(missing) == nil)
        #expect(MacDefaults.parseString(missing) == nil)
    }

    @Test func stringValues() {
        #expect(MacDefaults.parseString(ShellResult(status: 0, stdout: "~/Documents/\n")) == "~/Documents/")
        #expect(MacDefaults.parseString(ShellResult(status: 0, stdout: "  \n")) == nil)
    }

    @Test func expandsTheHomeFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(MacDefaults.expand("~/Documents/").hasPrefix(home))
        #expect(MacDefaults.expand("/tmp/shots") == "/tmp/shots")
    }

    @Test func shellResultMessagePrefersStderr() {
        #expect(ShellResult(status: 1, stdout: "out", stderr: "\nNo matching processes\n").message == "No matching processes")
        #expect(ShellResult(status: 3, stdout: "", stderr: "").message == "exit status 3")
    }
}

@Suite struct DevCleanupTests {
    @Test func yarnCacheDirIsTheLastAbsolutePath() {
        #expect(DevCleanup.yarnCacheDir("/Users/me/Library/Caches/Yarn/v6\n") == "/Users/me/Library/Caches/Yarn/v6")
        #expect(DevCleanup.yarnCacheDir("Usage Error: Couldn't find a script named \"cache\".\n") == nil)
    }

    @Test func nestedFoldersAreCountedOnce() {
        let urls = ["/a/Yarn", "/a/Yarn/v6", "/b/cache", "/a/Yarn"].map { URL(fileURLWithPath: $0) }
        #expect(DevCleanup.outermost(urls).map(\.path) == ["/a/Yarn", "/b/cache"])
    }

    @Test func sizesAndCleansAFolder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("devhub-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10_000).write(to: dir.appendingPathComponent("sub/file"))
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await DevCleanup.size(of: [dir]) >= 10_000)
    }
}

@Suite struct NetworkSpeedTests {
    @Test func rateIsBitsPerSecondAcrossInterfaces() {
        let before = ["en0": ByteCounters(received: 1_000, sent: 500), "en8": ByteCounters(received: 0, sent: 0)]
        let after = ["en0": ByteCounters(received: 251_000, sent: 1_500), "en8": ByteCounters(received: 250_000, sent: 0)]
        #expect(NetworkCounters.rate(from: before, to: after, interval: 2) == NetworkRate(download: 2_000_000, upload: 4_000))
    }

    @Test func aWrappedCounterStillGivesTheDifference() {
        let before = ["en0": ByteCounters(received: UInt32.max - 99, sent: 0)]
        let after = ["en0": ByteCounters(received: 900, sent: 0)]
        #expect(NetworkCounters.rate(from: before, to: after, interval: 1).download == 1_000 * 8)
    }

    @Test func anInterfaceThatJustCameUpIsSkipped() {
        let after = ["en0": ByteCounters(received: 10, sent: 10), "en5": ByteCounters(received: 4_000_000_000, sent: 1)]
        let rate = NetworkCounters.rate(from: ["en0": ByteCounters(received: 0, sent: 0)], to: after, interval: 1)
        #expect(rate == NetworkRate(download: 80, upload: 80))
        #expect(NetworkCounters.rate(from: [:], to: after, interval: 0) == .zero)
    }

    @Test func readsThisMacsInterfaces() {
        #expect(NetworkCounters.read().keys.allSatisfy { $0.hasPrefix("en") })
    }

    @Test func parsesNetworkQualityOutput() throws {
        let output = """
        {
          "base_rtt" : 141.00749206542969,
          "dl_throughput" : 27991994,
          "interface_name" : "utun4",
          "responsiveness" : 57.249042510986328,
          "ul_throughput" : 61614356,
          "other" : { "protocols_seen" : { "http/1.1" : 47 } }
        }
        """
        let result = try SpeedTest.parse(output)
        #expect(result.download == 27_991_994)
        #expect(result.upload == 61_614_356)
        #expect(result.interface == "utun4")
        #expect(result.idleLatency.map { Int($0.rounded()) } == 141)
        #expect(result.loadedLatency.map { Int($0.rounded()) } == 1048)
    }

    @Test func unreadableOutputExplainsWhy() {
        #expect(throws: SpeedTestError.failed("no network")) {
            try SpeedTest.parse(#"{"error_code": 1, "error_description": "no network"}"#)
        }
        #expect(throws: SpeedTestError.failed("its output couldn't be read")) { try SpeedTest.parse("garbage") }
    }

    @Test func bitRates() {
        #expect(Format.bitRate(27_991_994) == "28.0 Mbps")
        #expect(Format.bitRate(1_260_000_000) == "1.3 Gbps")
        #expect(Format.bitRate(850_000) == "850 Kbps")
        #expect(Format.bitRate(0) == "0 bps")
    }
}

@Suite struct DisplayTests {
    private func mode(_ id: Int32, _ width: Int, _ height: Int, scale: Int = 1, hz: Double) -> DisplayModeOption {
        DisplayModeOption(id: id, width: width, height: height, pixelWidth: width * scale, pixelHeight: height * scale, refreshRate: hz)
    }

    private var modes: [DisplayModeOption] {
        [mode(1, 1920, 1080, scale: 2, hz: 60), mode(2, 1920, 1080, scale: 2, hz: 30), mode(3, 2560, 1440, hz: 60),
         mode(4, 1920, 1080, hz: 60), mode(5, 3840, 2160, hz: 60), mode(6, 3840, 2160, hz: 59.94), mode(7, 3840, 2160, hz: 60)]
    }

    @Test func sizesAreListedOnceLargestFirst() {
        #expect(DisplayModes.sizes(modes).map(\.label) == ["3840 × 2160", "2560 × 1440", "1920 × 1080 (HiDPI)", "1920 × 1080"])
    }

    @Test func refreshRatesForASizeFastestFirstWithoutRepeats() {
        let size = DisplaySize(width: 3840, height: 2160, hiDPI: false)
        #expect(DisplayModes.refreshOptions(modes, size: size).map(\.refreshLabel) == ["60 Hz", "59.94 Hz"])
    }

    @Test func changingSizeKeepsTheRefreshRateWhenItCan() {
        let hiDPI = DisplaySize(width: 1920, height: 1080, hiDPI: true)
        #expect(DisplayModes.best(modes, size: hiDPI, refreshRate: 30)?.id == 2)
        #expect(DisplayModes.best(modes, size: hiDPI, refreshRate: 120)?.id == 1)
        #expect(DisplayModes.best(modes, size: hiDPI, refreshRate: nil)?.id == 1)
        #expect(DisplayModes.best(modes, size: DisplaySize(width: 800, height: 600, hiDPI: false), refreshRate: 60) == nil)
    }

    @Test func summaryAndLabels() {
        let info = DisplayInfo(id: 2, name: "DELL", isBuiltin: false, isMain: false, mirrorOf: nil,
                               frame: DisplayFrame(x: 0, y: 0, width: 1920, height: 1080),
                               current: mode(1, 1920, 1080, scale: 2, hz: 60), modes: modes)
        #expect(info.summary == "1920 × 1080 · 60 Hz · HiDPI")
        #expect(mode(9, 800, 600, hz: 0).refreshLabel == "Default")
    }

    @Test func listsThisMacsDisplays() {
        let displays = Displays.list()
        #expect(!displays.isEmpty)
        #expect(displays.contains { $0.isMain && $0.frame.x == 0 && $0.frame.y == 0 })
        for display in displays {
            #expect(display.current != nil)
            #expect(!display.modes.isEmpty)
            #expect(display.frame.width > 0)
            #expect(display.frame.height > 0)
        }
    }

    @Test func aDropKeepsItsPositionAlongTheEdge() {
        let placed = DisplayArrangement.snapped(2, x: 1530, y: 300, frames: Self.desk, snap: 0)
        #expect(placed == DisplayFrame(x: 1512, y: 300, width: 1920, height: 1080))
    }

    @Test func aDropNearAnEdgeLinesUpWithIt() {
        #expect(DisplayArrangement.snapped(2, x: 1560, y: 5, frames: Self.desk, snap: 8)?.y == 0)
        #expect(DisplayArrangement.snapped(2, x: 1560, y: -45, frames: Self.desk, snap: 8)?.y == -49)
        #expect(DisplayArrangement.snapped(2, x: 1560, y: -94, frames: Self.desk, snap: 8)?.y == -98)
        #expect(DisplayArrangement.snapped(2, x: 1560, y: 5, frames: Self.desk, snap: 0)?.y == 5)
    }

    @Test func aDropFarAlongTheEdgeKeepsEnoughEdgeShared() {
        #expect(DisplayArrangement.snapped(2, x: 3000, y: 1500, frames: Self.desk, snap: 0) == DisplayFrame(x: 1512, y: 942, width: 1920, height: 1080))
        #expect(DisplayArrangement.snapped(2, x: 3000, y: -1500, frames: Self.desk, snap: 0) == DisplayFrame(x: 1512, y: -1040, width: 1920, height: 1080))
    }

    @Test func aDropOnTopOfAnotherDisplayMovesToItsNearestEdge() {
        let placed = DisplayArrangement.snapped(2, x: 100, y: 900, frames: Self.desk, snap: 0)
        #expect(placed == DisplayFrame(x: 100, y: 982, width: 1920, height: 1080))
    }

    @Test func aDropNeverCoversAThirdDisplay() {
        let frames: [UInt32: DisplayFrame] = [
            1: DisplayFrame(x: 0, y: 0, width: 1000, height: 800),
            2: DisplayFrame(x: 0, y: 800, width: 1000, height: 500),
            3: DisplayFrame(x: 1000, y: 0, width: 800, height: 600),
        ]
        let placed = DisplayArrangement.snapped(2, x: 1000, y: 100, frames: frames, snap: 0)
        #expect(placed == DisplayFrame(x: 1000, y: 600, width: 1000, height: 500))
    }

    @Test func aDropThatWouldStrandADisplayStaysJoined() {
        let frames: [UInt32: DisplayFrame] = [
            1: DisplayFrame(x: 0, y: 0, width: 1000, height: 800),
            2: DisplayFrame(x: 1000, y: 0, width: 1000, height: 800),
            3: DisplayFrame(x: 2000, y: 0, width: 1000, height: 800),
        ]
        let placed = DisplayArrangement.snapped(2, x: 0, y: 820, frames: frames, snap: 0)
        #expect(placed == DisplayFrame(x: 1000, y: 760, width: 1000, height: 800))
    }

    @Test func theOnlyDisplayHasNowhereToGo() {
        let frames = [UInt32(1): DisplayFrame(x: 0, y: 0, width: 1512, height: 982)]
        #expect(DisplayArrangement.snapped(1, x: 50, y: 50, frames: frames, snap: 0) == nil)
        #expect(DisplayArrangement.snapped(9, x: 50, y: 50, frames: Self.desk, snap: 0) == nil)
    }

    @Test func normalizingKeepsTheMainDisplayAtTheOrigin() {
        var frames = Self.desk
        frames[1] = DisplayFrame(x: 3432, y: 0, width: 1512, height: 982)
        let normalized = DisplayArrangement.normalized(frames, main: 1)
        #expect(normalized[1] == DisplayFrame(x: 0, y: 0, width: 1512, height: 982))
        #expect(normalized[2] == DisplayFrame(x: -1920, y: 0, width: 1920, height: 1080))
        #expect(DisplayArrangement.normalized(Self.desk, main: 1) == Self.desk)
    }

    @Test func placementDescribesTheEdgeAndAlignment() throws {
        var frames = Self.desk
        let beside = try #require(DisplayArrangement.placement(of: 2, in: frames))
        #expect(beside.anchor == 1)
        #expect(beside.side == .right)
        #expect(beside.detail == "tops aligned")
        frames[2] = DisplayFrame(x: 1512, y: 120, width: 1920, height: 1080)
        #expect(DisplayArrangement.placement(of: 2, in: frames)?.detail == "120 pt lower")
        frames[2] = DisplayFrame(x: 1512, y: -49, width: 1920, height: 1080)
        #expect(DisplayArrangement.placement(of: 2, in: frames)?.detail == "centred")
        frames[2] = DisplayFrame(x: -204, y: -1080, width: 1920, height: 1080)
        let above = try #require(DisplayArrangement.placement(of: 2, in: frames))
        #expect(above.side == .above)
        #expect(above.detail == "centred")
        frames[2] = DisplayFrame(x: -408, y: -1080, width: 1920, height: 1080)
        #expect(DisplayArrangement.placement(of: 2, in: frames)?.detail == "right edges aligned")
        frames[2] = DisplayFrame(x: 4000, y: 0, width: 1920, height: 1080)
        #expect(DisplayArrangement.placement(of: 2, in: frames) == nil)
    }

    /// A built-in screen with one external display to its right, tops aligned.
    private static let desk: [UInt32: DisplayFrame] = [
        1: DisplayFrame(x: 0, y: 0, width: 1512, height: 982),
        2: DisplayFrame(x: 1512, y: 0, width: 1920, height: 1080),
    ]

    @Test func ddcPackets() {
        #expect(DDCPacket.set(DDCPacket.brightness, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        #expect(DDCPacket.get(DDCPacket.brightness) == [0x82, 0x01, 0x10, 0xAC])
    }

    @Test func ddcReplyIsFoundWhereverItStarts() throws {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x2D, 0x00, 0x00]
        let value = try #require(DDCPacket.parseReply(reply, vcp: 0x10))
        #expect(value.current == 45)
        #expect(value.max == 100)
        #expect(DDCPacket.parseReply(Array(reply.dropFirst(2)), vcp: 0x10)?.current == 45)
    }

    @Test func badDDCRepliesAreRejected() {
        #expect(DDCPacket.parseReply([UInt8](repeating: 0, count: 12), vcp: 0x10) == nil)
        #expect(DDCPacket.parseReply([0x02, 0x01, 0x10, 0x00, 0x00, 0x64, 0x00, 0x2D], vcp: 0x10) == nil)
        #expect(DDCPacket.parseReply([0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0xFF], vcp: 0x10) == nil)
        #expect(DDCPacket.parseReply([0x02, 0x00], vcp: 0x10) == nil)
    }

    @Test func readsTheBuiltinBrightness() throws {
        guard let builtin = Displays.list().first(where: \.isBuiltin) else { return }
        let value = try #require(BuiltinBrightness.get(builtin.id))
        #expect((0...1).contains(value))
    }
}

@Suite struct ScreenshotToolTests {
    @Test func timerMatchesTheToolbarsChoices() {
        #expect(ScreenshotTool.delays == [0, 5, 10])
        #expect(MachineStatus(fetchedAt: Date()).captureDelay == 0)
    }

    @Test func anUnsupportedTimerIsIgnored() async throws {
        try await MacDefaults.setCaptureDelay(7)
    }
}

@Suite struct UtilitiesMonitorTests {
    private func status() -> MachineStatus {
        MachineStatus(battery: BatteryStatus(percent: 82, state: "charging", onAC: true, remaining: "1:05"),
                      freeDisk: 120_000_000_000, totalDisk: 494_000_000_000, fetchedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func snapshotIsAlwaysClean() async throws {
        let monitor = UtilitiesMonitor(read: { _ in status() })
        let snapshot = try await monitor.refresh()
        #expect(snapshot.status == .clean)
        #expect(snapshot.items.isEmpty)
        #expect(snapshot.detail as? MachineStatus == status())
        #expect(monitor.id == "utilities")
        #expect(monitor.title == "Mac")
    }

    @Test func summaryNamesBatteryAndDisk() {
        let summary = UtilitiesRules.summary(status())
        #expect(summary.hasPrefix("Mac: 82% · charging · 1:05 to full · "))
        #expect(summary.contains("free of"))
        #expect(UtilitiesRules.summary(MachineStatus(fetchedAt: Date())) == "Mac: utilities")
    }

    @Test func dumpEncodesTheStatus() throws {
        let text = String(decoding: try HubDump.encode(["utilities": UtilitiesRules.monitorSnapshot(status())]), as: UTF8.self)
        #expect(text.contains("\"percent\""))
        #expect(text.contains("\"clean\""))
    }
}
