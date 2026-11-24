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

// The same SF Symbol as the voiced service's menu bar icon, in black on the white tile.
let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 480, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
guard let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
    .withSymbolConfiguration(symbolConfiguration) else {
    fatalError("Unable to load the waveform symbol")
}
// Fit the symbol into the middle of the tile, keeping its proportions.
let box = tileRect.width * (isIOS ? 0.58 : 0.62)
let scale = min(box / symbol.size.width, box / symbol.size.height)
let symbolSize = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
let symbolRect = NSRect(
    x: tileRect.midX - symbolSize.width / 2,
    y: tileRect.midY - symbolSize.height / 2,
    width: symbolSize.width,
    height: symbolSize.height
)
// The tile's drop shadow is still set; the symbol should not cast one.
NSShadow().set()
symbol.draw(in: symbolRect)

NSGraphicsContext.current?.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode icon PNG")
}
try png.write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
