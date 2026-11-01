import CoreGraphics
import Foundation

/// Decides whether the frontmost app has a full-screen window, from the window list.
/// The notch alert then draws on one line, so it doesn't cover that app.
public enum FullScreenCheck {
    /// One on-screen window, as the window list reports it.
    public struct Window: Equatable {
        public let pid: Int32
        public let layer: Int
        /// In global coordinates with a top-left origin.
        public let bounds: CGRect

        public init(pid: Int32, layer: Int, bounds: CGRect) {
            self.pid = pid
            self.layer = layer
            self.bounds = bounds
        }
    }

    /// The windows in `list` (from `CGWindowListCopyWindowInfo`), skipping any entry
    /// without an owner, a layer or bounds.
    public static func windows(from list: [[String: Any]]) -> [Window] {
        list.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = entry[kCGWindowLayer as String] as? NSNumber,
                  let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary)
            else { return nil }
            return Window(pid: pid.int32Value, layer: layer.intValue, bounds: bounds)
        }
    }

    /// True when `systemSaysFullScreen` and a normal (layer 0) window of `frontmostPID` covers
    /// `screen`, or `screen` without its top `topInset` points, within 1 pt. On a Mac with a
    /// notch, macOS lays a full-screen window out below the notch.
    ///
    /// `screen` is in global coordinates with a top-left origin, like the window bounds.
    public static func isFullScreen(_ windows: [Window], screen: CGRect, topInset: CGFloat,
                                    frontmostPID: Int32, systemSaysFullScreen: Bool) -> Bool {
        guard systemSaysFullScreen else { return false }
        let belowNotch = CGRect(x: screen.minX, y: screen.minY + topInset,
                                width: screen.width, height: screen.height - topInset)
        return windows.contains { window in
            window.pid == frontmostPID && window.layer == 0
                && (matches(window.bounds, screen) || matches(window.bounds, belowNotch))
        }
    }

    private static func matches(_ bounds: CGRect, _ target: CGRect) -> Bool {
        abs(bounds.minX - target.minX) <= 1
            && abs(bounds.minY - target.minY) <= 1
            && abs(bounds.width - target.width) <= 1
            && abs(bounds.height - target.height) <= 1
    }
}
