import Combine
import Darwin
import Foundation

/// Bytes an interface has received and sent since it came up. macOS keeps these as 32-bit
/// counters, so they wrap every 4 GB.
public struct ByteCounters: Sendable, Equatable {
    public let received: UInt32
    public let sent: UInt32

    public init(received: UInt32, sent: UInt32) {
        self.received = received
        self.sent = sent
    }
}

/// Download and upload speed in bits per second.
public struct NetworkRate: Sendable, Equatable {
    public let download: Double
    public let upload: Double

    public init(download: Double, upload: Double) {
        self.download = download
        self.upload = upload
    }

    public static let zero = NetworkRate(download: 0, upload: 0)
}

public enum NetworkCounters {
    /// The counters of every Ethernet and Wi-Fi interface that's up, by name. VPN tunnels are left
    /// out: their traffic already passes through one of these, so it would count twice.
    public static func read() -> [String: ByteCounters] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [:] }
        defer { freeifaddrs(first) }
        var counters: [String: ByteCounters] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let data = entry.ifa_data
            else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            counters[name] = ByteCounters(received: stats.ifi_ibytes, sent: stats.ifi_obytes)
        }
        return counters
    }

    /// The speed between two readings `interval` seconds apart. Only interfaces in both count, so
    /// one that comes up in between doesn't read as a burst; a counter that wrapped still gives
    /// the right difference.
    public static func rate(from previous: [String: ByteCounters], to current: [String: ByteCounters],
                            interval: TimeInterval) -> NetworkRate {
        guard interval > 0 else { return .zero }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, now) in current {
            guard let before = previous[name] else { continue }
            received += UInt64(now.received &- before.received)
            sent += UInt64(now.sent &- before.sent)
        }
        return NetworkRate(download: Double(received) * 8 / interval, upload: Double(sent) * 8 / interval)
    }
}

/// Samples the interface counters once a second while any view is watching.
public final class NetworkMeter: ObservableObject {
    public static let shared = NetworkMeter()

    @Published public private(set) var rate: NetworkRate?

    private var watchers = 0
    private var timer: Timer?
    private var last: (counters: [String: ByteCounters], at: Date)?

    public init() {}

    /// Call on the main thread; each `start()` needs a matching `stop()`.
    public func start() {
        watchers += 1
        guard timer == nil else { return }
        last = (NetworkCounters.read(), Date())
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
        last = nil
        rate = nil
    }

    private func sample() {
        let counters = NetworkCounters.read()
        let now = Date()
        if let last {
            rate = NetworkCounters.rate(from: last.counters, to: counters, interval: now.timeIntervalSince(last.at))
        }
        last = (counters, now)
    }
}

/// What macOS's `networkQuality` measured.
public struct SpeedTestResult: Sendable, Equatable, Decodable {
    /// Bits per second.
    public let download: Double
    public let upload: Double
    /// Round trips per minute while the line is busy; higher is better.
    public let responsiveness: Double?
    /// Milliseconds while the line is idle.
    public let idleLatency: Double?
    /// `en0`, or `utun4` on the VPN.
    public let interface: String?
    public let finishedAt: Date

    public init(download: Double, upload: Double, responsiveness: Double?, idleLatency: Double?, interface: String?, finishedAt: Date) {
        self.download = download
        self.upload = upload
        self.responsiveness = responsiveness
        self.idleLatency = idleLatency
        self.interface = interface
        self.finishedAt = finishedAt
    }

    private enum CodingKeys: String, CodingKey {
        case download = "dl_throughput", upload = "ul_throughput", responsiveness, idleLatency = "base_rtt"
        case interface = "interface_name"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        download = try c.decode(Double.self, forKey: .download)
        upload = try c.decode(Double.self, forKey: .upload)
        responsiveness = try c.decodeIfPresent(Double.self, forKey: .responsiveness)
        idleLatency = try c.decodeIfPresent(Double.self, forKey: .idleLatency)
        interface = try c.decodeIfPresent(String.self, forKey: .interface)
        finishedAt = Date()
    }

    /// Milliseconds per round trip while the line is busy, from the responsiveness.
    public var loadedLatency: Double? {
        guard let responsiveness, responsiveness > 0 else { return nil }
        return 60_000 / responsiveness
    }
}

public enum SpeedTestError: Error, LocalizedError, Equatable {
    case unavailable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "This Mac has no networkQuality tool."
        case .failed(let message): return "The speed test didn't finish: \(message)"
        }
    }
}

/// Runs macOS's `networkQuality`, which measures against Apple's servers. Needs no admin rights.
public enum SpeedTest {
    static let executable = URL(fileURLWithPath: "/usr/bin/networkQuality")
    /// How long each test may run, in seconds.
    static let maxRuntime = 20

    public static func run() async throws -> SpeedTestResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw SpeedTestError.unavailable }
        let result = try await Shell.run(executable, ["-c", "-M", String(maxRuntime)], timeout: TimeInterval(maxRuntime + 20))
        guard result.succeeded else { throw SpeedTestError.failed(result.message) }
        return try parse(result.stdout)
    }

    static func parse(_ output: String) throws -> SpeedTestResult {
        do {
            return try JSONDecoder().decode(SpeedTestResult.self, from: Data(output.utf8))
        } catch {
            let reason = (try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])?["error_description"] as? String
            throw SpeedTestError.failed(reason ?? "its output couldn't be read")
        }
    }
}

/// The latest speed test, shared so one keeps running while you switch tabs.
@MainActor
public final class SpeedTestRunner: ObservableObject {
    public static let shared = SpeedTestRunner()

    @Published public private(set) var result: SpeedTestResult?
    @Published public private(set) var running = false
    @Published public private(set) var message: String?

    public init() {}

    public func run() {
        guard !running else { return }
        running = true
        message = nil
        Task {
            do {
                result = try await SpeedTest.run()
            } catch {
                message = error.localizedDescription
            }
            running = false
        }
    }
}

extension Format {
    /// `28.0 Mbps`, `850 Kbps`, `1.2 Gbps`.
    public static func bitRate(_ bitsPerSecond: Double) -> String {
        switch bitsPerSecond {
        case 1_000_000_000...: return String(format: "%.1f Gbps", bitsPerSecond / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
        case 1_000...: return String(format: "%.0f Kbps", bitsPerSecond / 1_000)
        default: return String(format: "%.0f bps", bitsPerSecond)
        }
    }
}
