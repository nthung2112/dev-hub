import CoreGraphics
import DevHubCore
import SwiftUI

/// The closed notch with the alert area below it, from `NotchAlertLayout`, centred at the top of the rect.
/// With `rounded` off, the area's corners are square, so the outline matches `NotchAlertLayout.contains`.
struct NotchAlertShape: Shape {
    /// The size of the notch, at the top of the shape.
    let notch: CGSize
    /// Whether the alert area's corners are rounded (the drawn outline) or square (the hit target).
    var rounded: Bool

    init(notch: CGSize, rounded: Bool = true) {
        self.notch = notch
        self.rounded = rounded
    }

    func path(in rect: CGRect) -> Path {
        let area = CGSize(width: rect.width, height: max(0, rect.height - notch.height))
        let layout = NotchAlertLayout(notch: notch, area: area)
        let dx = rect.midX - layout.size.width / 2
        let neck = layout.neck.offsetBy(dx: dx, dy: rect.minY)
        let body = layout.body.offsetBy(dx: dx, dy: rect.minY)
        let top = rounded ? min(NotchMetrics.alertCornerRadius, body.height / 2) : 0
        let bottom = rounded ? min(NotchMetrics.alertBottomRadius, body.height / 2) : 0
        let join = NotchMetrics.alertJoinRadius

        var path = Path()
        func corner(_ at: CGPoint, toward next: CGPoint, radius: CGFloat) {
            if radius > 0 {
                path.addArc(tangent1End: at, tangent2End: next, radius: radius)
            } else {
                path.addLine(to: at)
            }
        }
        path.move(to: CGPoint(x: neck.minX, y: neck.minY))
        corner(CGPoint(x: neck.minX, y: body.minY), toward: CGPoint(x: body.minX, y: body.minY), radius: join)
        corner(CGPoint(x: body.minX, y: body.minY), toward: CGPoint(x: body.minX, y: body.maxY), radius: top)
        corner(CGPoint(x: body.minX, y: body.maxY), toward: CGPoint(x: body.maxX, y: body.maxY), radius: bottom)
        corner(CGPoint(x: body.maxX, y: body.maxY), toward: CGPoint(x: body.maxX, y: body.minY), radius: bottom)
        corner(CGPoint(x: body.maxX, y: body.minY), toward: CGPoint(x: neck.maxX, y: body.minY), radius: top)
        corner(CGPoint(x: neck.maxX, y: body.minY), toward: CGPoint(x: neck.maxX, y: neck.minY), radius: join)
        path.addLine(to: CGPoint(x: neck.maxX, y: neck.minY))
        path.closeSubpath()
        return path
    }
}
