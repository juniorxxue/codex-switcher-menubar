import AppKit

enum AppIcon {
    static func makeApplicationIcon(size: CGFloat = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let canvas = NSRect(origin: .zero, size: image.size)
        let outerRect = canvas.insetBy(dx: size * 0.06, dy: size * 0.06)
        let outerPath = NSBezierPath(
            roundedRect: outerRect,
            xRadius: size * 0.23,
            yRadius: size * 0.23
        )

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = size * 0.06
        shadow.shadowOffset = NSSize(width: 0, height: -(size * 0.02))

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        let outerGradient = NSGradient(colorsAndLocations:
            (NSColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1), 0.0),
            (NSColor(srgbRed: 0.84, green: 0.88, blue: 0.95, alpha: 1), 1.0)
        )
        outerGradient?.draw(in: outerPath, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.22).setStroke()
        outerPath.lineWidth = max(2, size * 0.01)
        outerPath.stroke()

        let panelRect = outerRect.insetBy(dx: size * 0.16, dy: size * 0.16)
        let panelPath = NSBezierPath(
            roundedRect: panelRect,
            xRadius: size * 0.16,
            yRadius: size * 0.16
        )
        NSColor.white.withAlphaComponent(0.78).setFill()
        panelPath.fill()

        let switchColor = NSColor(srgbRed: 0.10, green: 0.14, blue: 0.20, alpha: 0.92)
        let accentColor = NSColor(srgbRed: 0.22, green: 0.51, blue: 0.95, alpha: 1.0)
        let lineWidth = size * 0.07

        drawArrow(
            from: NSPoint(x: panelRect.minX + panelRect.width * 0.24, y: panelRect.midY + panelRect.height * 0.17),
            to: NSPoint(x: panelRect.maxX - panelRect.width * 0.20, y: panelRect.midY + panelRect.height * 0.17),
            color: switchColor,
            accentColor: accentColor,
            lineWidth: lineWidth
        )

        drawArrow(
            from: NSPoint(x: panelRect.maxX - panelRect.width * 0.24, y: panelRect.midY - panelRect.height * 0.17),
            to: NSPoint(x: panelRect.minX + panelRect.width * 0.20, y: panelRect.midY - panelRect.height * 0.17),
            color: switchColor,
            accentColor: accentColor,
            lineWidth: lineWidth
        )

        image.unlockFocus()
        return image
    }

    private static func drawArrow(
        from startPoint: NSPoint,
        to endPoint: NSPoint,
        color: NSColor,
        accentColor: NSColor,
        lineWidth: CGFloat
    ) {
        let body = NSBezierPath()
        body.move(to: startPoint)
        body.line(to: endPoint)
        body.lineWidth = lineWidth
        body.lineCapStyle = .round
        color.setStroke()
        body.stroke()

        let arrowLength = lineWidth * 1.15
        let direction: CGFloat = endPoint.x >= startPoint.x ? 1 : -1

        let arrowHead = NSBezierPath()
        arrowHead.lineWidth = lineWidth
        arrowHead.lineCapStyle = .round
        arrowHead.lineJoinStyle = .round
        arrowHead.move(to: NSPoint(x: endPoint.x - direction * arrowLength, y: endPoint.y + arrowLength * 0.7))
        arrowHead.line(to: endPoint)
        arrowHead.line(to: NSPoint(x: endPoint.x - direction * arrowLength, y: endPoint.y - arrowLength * 0.7))
        accentColor.setStroke()
        arrowHead.stroke()
    }
}
