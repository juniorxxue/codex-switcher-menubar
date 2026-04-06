import AppKit

private let usageLabelWidth: CGFloat = 14
private let usageBarWidth: CGFloat = 24
private let usageBarHeight: CGFloat = 5
private let usageRowGap: CGFloat = 3
private let usageLabelGap: CGFloat = 2
private let usageCornerRadius: CGFloat = 2
private let usageLogoSize: CGFloat = 12
private let usageLogoGap: CGFloat = 2
private let usageBarsWidth: CGFloat = usageLabelWidth + usageLabelGap + usageBarWidth + 2
private let usageIconWidth: CGFloat = usageLogoSize + usageLogoGap + usageBarsWidth
private let usageIconHeight: CGFloat = 18
private let usageFontSize: CGFloat = 8

private struct CachedUsageLabel {
    let attributedString: NSAttributedString
    let size: NSSize
}

@MainActor
private let cachedUsageLabels: [String: CachedUsageLabel] = {
    let font = NSFont.monospacedSystemFont(ofSize: usageFontSize, weight: .medium)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.black
    ]

    return Dictionary(uniqueKeysWithValues: ["5h", "7d"].map { label in
        let attributedString = NSAttributedString(string: label, attributes: attributes)
        return (
            label,
            CachedUsageLabel(attributedString: attributedString, size: attributedString.size())
        )
    })
}()

@MainActor
private let menuBarSwitcherLogo: NSImage? = {
    let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
    return NSImage(
        systemSymbolName: "arrow.triangle.2.circlepath.circle.fill",
        accessibilityDescription: nil
    )?.withSymbolConfiguration(configuration)
}()

@MainActor
func renderUsageMenuBarIcon(primaryFraction: Double?, secondaryFraction: Double?) -> NSImage {
    let image = NSImage(size: NSSize(width: usageIconWidth, height: usageIconHeight), flipped: true) { _ in
        let leftOffset = usageLogoSize + usageLogoGap
        let barX = leftOffset + usageLabelWidth + usageLabelGap
        let topY = (usageIconHeight - usageBarHeight * 2 - usageRowGap) / 2
        let bottomY = topY + usageBarHeight + usageRowGap

        drawSwitcherLogo(x: 0, y: (usageIconHeight - usageLogoSize) / 2, size: usageLogoSize)

        drawUsageRow(label: "5h", barX: barX, barY: topY, labelX: leftOffset) {
            drawUsageBar(
                x: barX,
                y: topY,
                width: usageBarWidth,
                height: usageBarHeight,
                cornerRadius: usageCornerRadius,
                fraction: primaryFraction
            )
        }

        drawUsageRow(label: "7d", barX: barX, barY: bottomY, labelX: leftOffset) {
            drawUsageBar(
                x: barX,
                y: bottomY,
                width: usageBarWidth,
                height: usageBarHeight,
                cornerRadius: usageCornerRadius,
                fraction: secondaryFraction
            )
        }

        return true
    }

    image.isTemplate = true
    return image
}

@MainActor
private func drawUsageRow(
    label: String,
    barX: CGFloat,
    barY: CGFloat,
    labelX: CGFloat,
    drawBar: () -> Void
) {
    if let cachedLabel = cachedUsageLabels[label] {
        let labelY = barY + (usageBarHeight - cachedLabel.size.height) / 2
        cachedLabel.attributedString.draw(at: NSPoint(x: labelX + usageLabelWidth - cachedLabel.size.width, y: labelY))
    }

    drawBar()
}

@MainActor
private func drawUsageBar(
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    cornerRadius: CGFloat,
    fraction: Double?
) {
    guard let fraction else {
        drawDashedUsageBar(x: x, y: y, width: width, height: height, cornerRadius: cornerRadius)
        return
    }

    let backgroundRect = NSRect(x: x, y: y, width: width, height: height)
    let backgroundPath = NSBezierPath(roundedRect: backgroundRect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor.black.withAlphaComponent(0.25).setFill()
    backgroundPath.fill()

    let clampedFraction = max(0, min(1, fraction))
    guard clampedFraction > 0 else {
        return
    }

    let fillRect = NSRect(x: x, y: y, width: width * clampedFraction, height: height)
    let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor.black.setFill()
    fillPath.fill()
}

@MainActor
private func drawDashedUsageBar(
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    cornerRadius: CGFloat
) {
    let rect = NSRect(x: x, y: y, width: width, height: height)
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor.black.withAlphaComponent(0.25).setStroke()
    path.lineWidth = 1
    path.setLineDash([2, 2], count: 2, phase: 0)
    path.stroke()
}

@MainActor
private func drawSwitcherLogo(x: CGFloat, y: CGFloat, size: CGFloat) {
    guard let logo = menuBarSwitcherLogo else {
        return
    }

    logo.draw(in: NSRect(x: x, y: y, width: size, height: size))
}
