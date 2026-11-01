import Foundation

/// `--dump` output: each tab's snapshot as JSON. Snapshots hold no secrets, so nothing private
/// can reach stdout.
public enum HubDump {
    public static func encode(_ snapshots: [String: MonitorSnapshot]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshots)
    }

    /// The stderr line for a failed tab.
    public static func errorLine(_ tabID: String, _ error: Error) -> String {
        "devhub: \(tabID): \(error.localizedDescription)"
    }
}
