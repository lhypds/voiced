import AppKit
import Foundation

let arguments = CommandLine.arguments
let isIOS = arguments.contains("--ios")
guard arguments.count == (isIOS ? 3 : 2) else {
    fatalError("Usage: swift generate-icon.swift <output.png> [--ios]")
}

let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Unable to create icon bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
(isIOS ? NSColor.white : NSColor.clear).setFill()
canvas.fill()

let tileRect = isIOS ? canvas : canvas.insetBy(dx: 72, dy: 72)
let tile = isIOS ? NSBezierPath(rect: tileRect) : NSBezierPath(roundedRect: tileRect, xRadius: 218, yRadius: 218)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
shadow.shadowBlurRadius = 36
shadow.shadowOffset = NSSize(width: 0, height: -20)
if !isIOS { shadow.set() }
NSColor.white.setFill()
tile.fill()

NSGraphicsContext.current?.saveGraphicsState()
tile.addClip()

let accent = NSColor(calibratedRed: 0.96, green: 0.64, blue: 0.38, alpha: 1)
let accentDeep = NSColor(calibratedRed: 0.93, green: 0.54, blue: 0.26, alpha: 1)

let capsuleWidths: [CGFloat] = [38, 46, 54, 62, 54, 46, 38]
let heights: [CGFloat] = [178, 318, 460, 610, 460, 318, 178]
let spacing: CGFloat = 40
let totalWidth = capsuleWidths.reduce(0, +) + spacing * CGFloat(capsuleWidths.count - 1)
var x = (CGFloat(size) - totalWidth) / 2

for (index, height) in heights.enumerated() {
    let width = capsuleWidths[index]
    let barRect = NSRect(x: x, y: (CGFloat(size) - height) / 2, width: width, height: height)
    let bar = NSBezierPath(roundedRect: barRect, xRadius: width / 2, yRadius: width / 2)
    (index == heights.count / 2 ? accentDeep : accent).setFill()
    bar.fill()
    x += width + spacing
}

let centerDot = NSBezierPath(ovalIn: NSRect(x: 469, y: 469, width: 86, height: 86))
NSColor(calibratedWhite: 1, alpha: 0.95).setFill()
centerDot.fill()

NSGraphicsContext.current?.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode icon PNG")
}
try png.write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
