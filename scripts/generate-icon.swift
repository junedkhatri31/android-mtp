import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = output.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawIcon(size: Int) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    let rect = NSRect(x: 90, y: 90, width: 844, height: 844)
    let background = NSBezierPath(roundedRect: rect, xRadius: 188, yRadius: 188)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -15)
    shadow.set()
    NSGradient(starting: NSColor(red: 0.23, green: 0.72, blue: 0.61, alpha: 1),
               ending: NSColor(red: 0.06, green: 0.38, blue: 0.34, alpha: 1))!.draw(in: background, angle: -90)
    NSShadow().set()
    NSColor.white.withAlphaComponent(0.2).setStroke()
    background.lineWidth = 3
    background.stroke()
    let phone = NSBezierPath(roundedRect: NSRect(x: 563, y: 292, width: 175, height: 438), xRadius: 35, yRadius: 35)
    NSColor.white.withAlphaComponent(0.92).setStroke()
    phone.lineWidth = 17
    phone.stroke()
    let speaker = NSBezierPath(roundedRect: NSRect(x: 623, y: 684, width: 55, height: 10), xRadius: 5, yRadius: 5)
    NSColor.white.withAlphaComponent(0.9).setFill(); speaker.fill()
    let folder = NSBezierPath()
    folder.move(to: NSPoint(x: 259, y: 622))
    folder.line(to: NSPoint(x: 347, y: 622))
    folder.line(to: NSPoint(x: 375, y: 590))
    folder.line(to: NSPoint(x: 514, y: 590))
    folder.line(to: NSPoint(x: 514, y: 415))
    folder.line(to: NSPoint(x: 259, y: 415)); folder.close()
    NSColor.white.withAlphaComponent(0.94).setFill(); folder.fill()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 330, y: 353)); arrow.line(to: NSPoint(x: 515, y: 353))
    arrow.move(to: NSPoint(x: 475, y: 389)); arrow.line(to: NSPoint(x: 515, y: 353)); arrow.line(to: NSPoint(x: 475, y: 317))
    arrow.move(to: NSPoint(x: 515, y: 681)); arrow.line(to: NSPoint(x: 330, y: 681))
    arrow.move(to: NSPoint(x: 370, y: 717)); arrow.line(to: NSPoint(x: 330, y: 681)); arrow.line(to: NSPoint(x: 370, y: 645))
    arrow.lineWidth = 20; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.9).setStroke(); arrow.stroke()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    // Render at precisely the requested pixel dimensions, independent of the display scale.
    let result = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: result)
    NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: size, height: size)).draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return result.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try drawIcon(size: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try drawIcon(size: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try task.run(); task.waitUntilExit()
guard task.terminationStatus == 0 else { exit(task.terminationStatus) }
try FileManager.default.removeItem(at: iconset)
