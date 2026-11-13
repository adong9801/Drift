// Draws the app icon and writes Support/Drift.icns. Run with:
//   swift Support/make-icon.swift
// The icon is the Drift D on a dark plate: the sidebar as an ivory bar, and
// beside it the page, square on the sidebar's side and a half-circle on the
// other, in a sunset gradient. Drawn, not stored, so there are no image
// assets to keep in sync. Chosen from https://claude.ai/artifact/Mi5VvPQMpMepCNUKgShsGA.
// Coordinates are on a 1024 grid with y running down, the same as the design.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconset = root.appendingPathComponent("Drift.iconset")
let icns = root.appendingPathComponent("Drift.icns")

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

/// The page: square against the sidebar with small round corners, and a
/// full half-circle on the other side, which is what makes the pair a D.
func page() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 476, y: 290))
    path.addLine(to: CGPoint(x: 552, y: 290))
    // Top, round the right-hand side, to the bottom. With y running down,
    // increasing angles go that way.
    path.addArc(center: CGPoint(x: 552, y: 512), radius: 222, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
    path.addLine(to: CGPoint(x: 476, y: 734))
    path.addArc(tangent1End: CGPoint(x: 440, y: 734), tangent2End: CGPoint(x: 440, y: 698), radius: 36)
    path.addLine(to: CGPoint(x: 440, y: 326))
    path.addArc(tangent1End: CGPoint(x: 440, y: 290), tangent2End: CGPoint(x: 476, y: 290), radius: 36)
    path.closeSubpath()
    return path
}

/// The sidebar: a bar 80 wide, the same gap from the page as before.
let sidebar = CGPath(roundedRect: CGRect(x: 312, y: 290, width: 80, height: 444), cornerWidth: 40, cornerHeight: 40, transform: nil)

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let s = CGFloat(pixels) / 1024

    // Flip to y-down and scale to the 1024 grid.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: s, y: -s)

    // macOS squircle: inset from the canvas, big continuous corners.
    let plate = CGPath(
        roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
        cornerWidth: 186, cornerHeight: 186, transform: nil
    )

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func gradient(_ stops: [(CGFloat, UInt32)]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: stops.map { color($0.1) } as CFArray, locations: stops.map(\.0))!
    }

    // The plate, which casts the icon's shadow. Shadow offsets ignore the
    // transform, so down is negative here. Dark, a shade lighter at the top.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 32 * s, color: CGColor(gray: 0, alpha: 0.32))
    ctx.setFillColor(color(0x1B1A1F))
    ctx.addPath(plate)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, 0x26242C), (1, 0x17161B)]), start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()

    // The sidebar, ivory, warming a little toward the bottom.
    ctx.saveGState()
    ctx.addPath(sidebar)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, 0xFFFDF8), (1, 0xE4DDCF)]), start: CGPoint(x: 312, y: 290), end: CGPoint(x: 392, y: 734), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // The page: sunset, purple to rose to coral, from its top-left corner
    // to the bottom-right of its curve.
    ctx.saveGState()
    ctx.addPath(page())
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, 0x7B5CE0), (0.5, 0xE0679A), (1, 0xFF9A5B)]), start: CGPoint(x: 440, y: 290), end: CGPoint(x: 774, y: 734), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try! png(pixels: points * scale).write(to: iconset.appendingPathComponent(name))
    }
}
// A loose copy at full size, for looking at. In .build, so it is never
// mistaken for a source file.
try? png(pixels: 1024).write(to: root.deletingLastPathComponent().appendingPathComponent(".build/Drift-icon-preview.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "wrote \(icns.path)" : "iconutil failed")
