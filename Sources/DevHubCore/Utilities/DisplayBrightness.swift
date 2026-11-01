import CoreGraphics
import Darwin
import Foundation
import IOKit

/// DDC/CI packets: how a Mac asks a monitor for, or sets, one of its controls over the cable.
public enum DDCPacket {
    /// The brightness control (VCP code 0x10).
    public static let brightness: UInt8 = 0x10

    static let displayAddress: UInt8 = 0x6E
    static let hostAddress: UInt8 = 0x51

    static func checksum(_ seed: UInt8, _ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(seed, ^)
    }

    /// `84 03 <vcp> <hi> <lo> <checksum>`: set `vcp` to `value`.
    public static func set(_ vcp: UInt8, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)]
        return body + [checksum(displayAddress ^ hostAddress, body)]
    }

    /// `82 01 <vcp> <checksum>`: ask for `vcp`'s current and maximum value.
    public static func get(_ vcp: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, vcp]
        return body + [checksum(displayAddress ^ hostAddress, body)]
    }

    /// Finds the `02 <result> <vcp> <type> <maxHi> <maxLo> <curHi> <curLo>` reply wherever it starts
    /// in what was read, since some monitors echo an address byte first.
    public static func parseReply(_ bytes: [UInt8], vcp: UInt8) -> (current: Int, max: Int)? {
        guard bytes.count >= 8 else { return nil }
        for start in 0...(bytes.count - 8) where bytes[start] == 0x02 && bytes[start + 1] == 0x00 && bytes[start + 2] == vcp {
            let maximum = Int(bytes[start + 4]) << 8 | Int(bytes[start + 5])
            let current = Int(bytes[start + 6]) << 8 | Int(bytes[start + 7])
            if maximum > 0, current <= maximum { return (current, maximum) }
        }
        return nil
    }
}

/// Sets an external monitor's brightness over DDC on Apple silicon, through IOKit's IOAVService
/// functions. They aren't public API, so they're looked up at run time and the feature simply
/// reports itself unavailable when they're missing. Many monitors and the built-in HDMI port on
/// some Macs don't take DDC at all.
public final class DDCBrightness: @unchecked Sendable {
    public static let shared = DDCBrightness()

    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private let create: Create?
    private let write: Transfer?
    private let read: Transfer?
    private let queue = DispatchQueue(label: "local.devhub.ddc")

    private static let i2cAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51

    init() {
        let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        create = dlsym(iokit, "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: Create.self) }
        write = dlsym(iokit, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: Transfer.self) }
        read = dlsym(iokit, "IOAVServiceReadI2C").map { unsafeBitCast($0, to: Transfer.self) }
    }

    /// The AV services of every external display.
    private func externalServices() -> [CFTypeRef] {
        guard let create else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var services: [CFTypeRef] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if location == "External", let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                services.append(service)
            }
        }
        return services
    }

    /// The first external monitor's brightness as 0-100, nil when no monitor answers.
    public func readBrightness() async -> Int? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.externalServices().lazy.compactMap(self.readBrightness).first)
            }
        }
    }

    private func readBrightness(_ service: CFTypeRef) -> Int? {
        guard let write, let read else { return nil }
        for _ in 0..<3 {
            var request = DDCPacket.get(DDCPacket.brightness)
            guard write(service, Self.i2cAddress, Self.dataAddress, &request, UInt32(request.count)) == kIOReturnSuccess else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            guard read(service, Self.i2cAddress, 0, &reply, UInt32(reply.count)) == kIOReturnSuccess else { continue }
            if let value = DDCPacket.parseReply(reply, vcp: DDCPacket.brightness) {
                return Int((Double(value.current) / Double(value.max) * 100).rounded())
            }
        }
        return nil
    }

    /// Sets every external monitor to `percent`. True when at least one took the command.
    public func setBrightness(_ percent: Int) async -> Bool {
        let value = UInt16(min(100, max(0, percent)))
        return await withCheckedContinuation { continuation in
            queue.async {
                guard let write = self.write else { return continuation.resume(returning: false) }
                var accepted = false
                for service in self.externalServices() {
                    var packet = DDCPacket.set(DDCPacket.brightness, value: value)
                    for attempt in 0..<2 {
                        if write(service, Self.i2cAddress, Self.dataAddress, &packet, UInt32(packet.count)) == kIOReturnSuccess {
                            accepted = true
                            break
                        }
                        if attempt == 0 { usleep(20_000) }
                    }
                }
                continuation.resume(returning: accepted)
            }
        }
    }
}

/// The built-in screen's backlight, through the private DisplayServices framework that the
/// brightness keys use. Missing functions just make it unavailable.
public enum BuiltinBrightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) }
    private static let setter = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) }

    /// 0-1, nil when it can't be read.
    public static func get(_ display: UInt32) -> Float? {
        var value: Float = 0
        guard let getter, getter(display, &value) == 0 else { return nil }
        return value
    }

    @discardableResult
    public static func set(_ display: UInt32, _ value: Float) -> Bool {
        guard let setter else { return false }
        return setter(display, min(1, max(0, value))) == 0
    }
}

/// Dims a display by scaling its colour output, for monitors that don't take DDC. macOS puts the
/// colours back when Dev Hub quits, even if it crashes.
public enum SoftwareDimming {
    /// `level` is 0-1: 1 is normal, 0 is black.
    @discardableResult
    public static func set(_ display: UInt32, level: Double) -> Bool {
        let level = Float(min(1, max(0, level)))
        return CGSetDisplayTransferByFormula(display, 0, level, 1, 0, level, 1, 0, level, 1) == .success
    }

    /// Every display back to its ColorSync profile.
    public static func restoreAll() {
        CGDisplayRestoreColorSyncSettings()
    }
}
