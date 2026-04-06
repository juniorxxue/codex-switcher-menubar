import AppKit
import Foundation

let outputDirectory: URL = {
    if let argument = CommandLine.arguments.dropFirst().first {
        return URL(fileURLWithPath: argument, isDirectory: true)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}()

let iconsetDirectory = outputDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let iconFile = outputDirectory.appendingPathComponent("AppIcon.icns")
let fileManager = FileManager.default

try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
if fileManager.fileExists(atPath: iconsetDirectory.path) {
    try fileManager.removeItem(at: iconsetDirectory)
}
try fileManager.createDirectory(at: iconsetDirectory, withIntermediateDirectories: true)
try? fileManager.removeItem(at: iconFile)

let sizes = [16, 32, 128, 256, 512]

for baseSize in sizes {
    try writePNG(sideLength: baseSize, to: iconsetDirectory.appendingPathComponent("icon_\(baseSize)x\(baseSize).png"))
    try writePNG(sideLength: baseSize * 2, to: iconsetDirectory.appendingPathComponent("icon_\(baseSize)x\(baseSize)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDirectory.path, "-o", iconFile.path]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    throw NSError(domain: "AppIcon", code: Int(iconutil.terminationStatus), userInfo: [
        NSLocalizedDescriptionKey: "iconutil failed while creating AppIcon.icns."
    ])
}

func writePNG(sideLength: Int, to url: URL) throws {
    let image = makeApplicationIcon(size: CGFloat(sideLength))
    guard let tiffData = image.tiffRepresentation,
          let representation = NSBitmapImageRep(data: tiffData),
          let pngData = representation.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "AppIcon", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Failed to render PNG icon at \(sideLength)x\(sideLength)."
        ])
    }

    try pngData.write(to: url)
}

func makeApplicationIcon(size: CGFloat) -> NSImage {
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
        (NSColor(srgbRed: 0.84, green: 0.88, blue: 0.95, alpha: 1.0), 1.0)
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

func drawArrow(
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
