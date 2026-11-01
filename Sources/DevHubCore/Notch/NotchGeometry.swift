import CoreGraphics
import Foundation

/// Sizes shared by the closed notch and the alert that hangs under it.
public enum NotchMetrics {
    /// Width of the alert area below the closed notch.
    public static let alertAreaWidth: CGFloat = 370
    /// Radius of the alert area's top corners.
    public static let alertCornerRadius: CGFloat = 12
    /// Radius of the alert area's bottom corners.
    public static let alertBottomRadius: CGFloat = 18
    /// Radius of the two concave corners where the notch joins the alert area.
    public static let alertJoinRadius: CGFloat = 6
}

/// The closed notch with an alert area below it. The neck is the notch, the body is the
/// alert area, centred under it. Coordinates have a top-left origin inside `size`.
public struct NotchAlertLayout: Equatable {
    /// The notch, at the top.
    public let neck: CGRect
    /// The alert area, directly below the neck.
    public let body: CGRect

    public init(notch: CGSize, area: CGSize) {
        let width = max(notch.width, area.width)
        neck = CGRect(x: (width - notch.width) / 2, y: 0, width: notch.width, height: notch.height)
        body = CGRect(x: (width - area.width) / 2, y: notch.height, width: area.width, height: area.height)
    }

    /// The bounding box of the neck and the body.
    public var size: CGSize {
        CGSize(width: max(neck.width, body.width), height: neck.height + body.height)
    }

    /// Whether `point` is on the shape: in the neck, in the body, or in one of the two
    /// concave corners where they join. The band beside the neck is outside.
    public func contains(_ point: CGPoint) -> Bool {
        if neck.contains(point) || body.contains(point) { return true }
        let r = NotchMetrics.alertJoinRadius
        guard point.y >= body.minY - r, point.y <= body.minY else { return false }
        let centreX: CGFloat
        if point.x >= neck.minX - r, point.x <= neck.minX {
            centreX = neck.minX - r
        } else if point.x >= neck.maxX, point.x <= neck.maxX + r {
            centreX = neck.maxX + r
        } else {
            return false
        }
        return hypot(point.x - centreX, point.y - (body.minY - r)) >= r
    }
}

/// How big the notch panel is, closed and open.
public enum NotchSizing {
    public static let fallbackWidth: CGFloat = 185
    public static let fallbackHeight: CGFloat = 32
    /// Room below the open panel so its shadow is not clipped.
    public static let shadowMargin: CGFloat = 20
    /// `HubView`'s width. The open notch adds padding around it.
    public static let contentWidth: CGFloat = 520
    /// Side padding of the open notch: the corner radius plus a margin.
    public static let openHorizontalInset: CGFloat = 31
    public static let openBottomInset: CGFloat = 12

    /// The closed notch. With both auxiliary widths, the hardware cutout is the screen minus those
    /// two menu-bar bands, plus a little overlap. Without them, a pill `fallbackWidth` wide.
    public static func closedSize(screenWidth: CGFloat, leftAuxiliary: CGFloat?, rightAuxiliary: CGFloat?,
                                  menuBarHeight: CGFloat, topSafeInset: CGFloat) -> CGSize {
        var width = fallbackWidth
        if let leftAuxiliary, let rightAuxiliary {
            width = screenWidth - leftAuxiliary - rightAuxiliary + 4
        }
        let height = topSafeInset > 0 ? topSafeInset : menuBarHeight
        return CGSize(width: width, height: height > 0 ? height : fallbackHeight)
    }

    /// `requested`, shrunk so it fits `available` and still leaves `shadowMargin` below.
    public static func resolve(_ requested: CGSize, within available: CGSize) -> CGSize {
        CGSize(width: min(requested.width, max(0, available.width)),
               height: min(requested.height, max(0, available.height - shadowMargin)))
    }

    /// The open notch: the 520-point panel, the side padding, the neck and the bottom padding.
    public static func openSize(bodyHeight: CGFloat, neckHeight: CGFloat, within available: CGSize) -> CGSize {
        resolve(CGSize(width: contentWidth + 2 * openHorizontalInset,
                       height: neckHeight + bodyHeight + openBottomInset),
                within: available)
    }

    /// The window that holds the largest open notch, plus the shadow margin. Wide enough for the alert too.
    public static func panelSize(within available: CGSize, neckHeight: CGFloat) -> CGSize {
        let open = openSize(bodyHeight: available.height, neckHeight: neckHeight, within: available)
        return CGSize(width: max(open.width, NotchMetrics.alertAreaWidth),
                      height: open.height + shadowMargin)
    }
}

/// Which part of the panel accepts the pointer. The panel is a rectangle; the notch is not.
public enum NotchHit {
    /// `point` is in the panel, top-left origin, y down. `visible` is the drawn notch, centred on the top edge.
    /// With `showsAlert`, the band of `visible` beside the neck is outside, so the menu-bar icons there stay usable.
    public static func contains(_ point: CGPoint, panel: CGSize, visible: CGSize, closed: CGSize, showsAlert: Bool) -> Bool {
        guard point.x >= 0, point.y >= 0, point.x <= panel.width, point.y <= panel.height,
              visible.width > 0, visible.height > 0 else { return false }
        let local = CGPoint(x: point.x - (panel.width - visible.width) / 2, y: point.y)
        guard local.x >= 0, local.y >= 0, local.x <= visible.width, local.y <= visible.height else { return false }
        guard showsAlert else { return true }
        let notch = CGSize(width: max(0, closed.width - 4), height: closed.height)
        let layout = NotchAlertLayout(notch: notch, area: CGSize(width: visible.width,
                                                                  height: max(0, visible.height - notch.height)))
        return layout.contains(local)
    }
}

/// How long the pointer must rest on the notch before it opens.
public enum HoverDelay: String, Codable, CaseIterable, Sendable {
    case instant, short, medium, long

    public var seconds: Double {
        switch self {
        case .instant: return 0
        case .short: return 0.15
        case .medium: return 0.4
        case .long: return 0.8
        }
    }

    public var title: String {
        switch self {
        case .instant: return "None"
        case .short: return "Short"
        case .medium: return "Medium"
        case .long: return "Long"
        }
    }
}

/// A connected display: `id` is its UUID, `name` what the picker shows.
public struct NotchDisplay: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Which displays show the notch. A chosen display is identified by `id`; `name` is what the picker shows.
public enum NotchDisplayChoice: Codable, Hashable, Sendable {
    case main
    case display(id: String, name: String)
    case all
}

public extension NotchDisplayChoice {
    /// The displays that show the notch. `displays[0]` is the main display; a chosen display that is
    /// not connected falls back to it.
    func resolve(among displays: [NotchDisplay]) -> [NotchDisplay] {
        guard let main = displays.first else { return [] }
        switch self {
        case .main:
            return [main]
        case let .display(id, _):
            return [displays.first { $0.id == id } ?? main]
        case .all:
            return displays
        }
    }
}
