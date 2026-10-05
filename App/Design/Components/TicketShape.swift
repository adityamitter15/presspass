import SwiftUI

/// A rounded ticket with a semicircular notch cut into the left and right
/// edges at the perforation line.
struct TicketShape: Shape {
    var cornerRadius: CGFloat = Theme.cardRadius
    var notchRadius: CGFloat = 13
    /// Where the perforation sits, as a fraction of the height from the top.
    var perforation: CGFloat = 0.68

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, rect.width / 2, rect.height / 2)
        let n = notchRadius
        let py = rect.minY + rect.height * perforation

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
            startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: py - n))
        // The right notch bites into the card, towards the left.
        path.addArc(
            center: CGPoint(x: rect.maxX, y: py), radius: n,
            startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
            startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
            startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: py + n))
        // The left notch bites towards the right.
        path.addArc(
            center: CGPoint(x: rect.minX, y: py), radius: n,
            startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
            startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

/// The dashed line between the two notches.
struct PerforationLine: Shape {
    var notchRadius: CGFloat = 13
    var perforation: CGFloat = 0.68

    func path(in rect: CGRect) -> Path {
        let y = rect.minY + rect.height * perforation
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + notchRadius + 8, y: y))
        path.addLine(to: CGPoint(x: rect.maxX - notchRadius - 8, y: y))
        return path
    }
}
