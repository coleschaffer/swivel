// Draws Swivel's app icon: a row of windows on a curved track, the center one lit up.
// Usage: make-icon <output.iconset> [preview.png]
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Apple's icon shape is close to a superellipse; this traces one inside `rect`.
func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for step in 0...720 {
        let t = CGFloat(step) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = a * copysign(pow(abs(c), 2 / exponent), c)
        let y = b * copysign(pow(abs(s), 2 / exponent), s)
        let point = CGPoint(x: rect.midX + x, y: rect.midY + y)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// A window seen at an angle: `inner` is the edge nearer the center, taller than the far edge.
func panel(innerX: CGFloat, outerX: CGFloat, centerY: CGFloat, innerHeight: CGFloat, outerHeight: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: innerX, y: centerY - innerHeight / 2))
    path.addLine(to: CGPoint(x: innerX, y: centerY + innerHeight / 2))
    path.addLine(to: CGPoint(x: outerX, y: centerY + outerHeight / 2))
    path.addLine(to: CGPoint(x: outerX, y: centerY - outerHeight / 2))
    path.closeSubpath()
    return path
}

func drawIcon(_ context: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)

    // Shadow under the icon, as on every macOS icon.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    context.addPath(shape)
    context.setFillColor(color(0x161A3A))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()

    // Deep blue-violet background, lighter toward the top.
    let background = CGGradient(colorsSpace: nil, colors: [color(0x3A3F9E), color(0x1E2163), color(0x0E0F2E)] as CFArray,
                                locations: [0, 0.55, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // The spotlight behind the center window.
    let glow = CGGradient(colorsSpace: nil, colors: [color(0x5CC8FF, 0.55), color(0x5CC8FF, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 520), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 520), endRadius: 360, options: [])

    // The track the windows ride on, with a pool of light where the focused window stands.
    context.setStrokeColor(color(0xFFFFFF, 0.18))
    context.setLineWidth(5)
    context.addEllipse(in: CGRect(x: 150, y: 250, width: 724, height: 120))
    context.strokePath()
    context.saveGState()
    context.translateBy(x: 512, y: 318)
    context.scaleBy(x: 1, y: 0.22)
    let pool = CGGradient(colorsSpace: nil, colors: [color(0x6FD3FF, 0.5), color(0x6FD3FF, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(pool, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 260, options: [])
    context.restoreGState()

    let midY: CGFloat = 540
    // Far windows, mostly turned away.
    for (inner, outer) in [(CGFloat(252), CGFloat(188)), (CGFloat(772), CGFloat(836))] {
        let path = panel(innerX: inner, outerX: outer, centerY: midY, innerHeight: 250, outerHeight: 196)
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.setFillColor(color(0xFFFFFF, 0.2))
        context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        context.setFillColor(color(0xFFFFFF, 0.16))
        context.fill(CGRect(x: 0, y: midY + 100, width: canvas, height: 40))
        context.restoreGState()
    }
    // Near side windows, angled toward the middle.
    for (inner, outer) in [(CGFloat(346), CGFloat(262)), (CGFloat(678), CGFloat(762))] {
        let path = panel(innerX: inner, outerX: outer, centerY: midY, innerHeight: 340, outerHeight: 268)
        context.saveGState()
        context.addPath(path)
        context.clip()
        let sheen = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF, 0.62), color(0xD8E2FF, 0.40)] as CFArray,
                               locations: [0, 1])!
        context.drawLinearGradient(sheen, start: CGPoint(x: 0, y: midY + 170), end: CGPoint(x: 0, y: midY - 170), options: [])
        context.setFillColor(color(0xFFFFFF, 0.28))
        context.fill(CGRect(x: 0, y: midY + 128, width: canvas, height: 50))
        context.restoreGState()
    }

    // The focused window, front and center.
    let window = CGRect(x: 357, y: midY - 192, width: 310, height: 384)
    let windowPath = CGPath(roundedRect: window, cornerWidth: 34, cornerHeight: 34, transform: nil)
    context.saveGState()
    context.setShadow(offset: .zero, blur: 46, color: color(0x6FD3FF, 0.95))
    context.addPath(windowPath)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(windowPath)
    context.clip()
    let face = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF), color(0xE6ECFA)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(face, start: CGPoint(x: 0, y: window.maxY), end: CGPoint(x: 0, y: window.minY), options: [])
    // Title bar with the three buttons.
    context.setFillColor(color(0xDDE4F4))
    context.fill(CGRect(x: window.minX, y: window.maxY - 62, width: window.width, height: 62))
    for (i, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
        context.setFillColor(color(hex))
        context.fillEllipse(in: CGRect(x: window.minX + 30 + CGFloat(i) * 34, y: window.maxY - 42, width: 22, height: 22))
    }
    // Lines of "content".
    for (i, width) in [CGFloat(206), 160, 228, 130, 186].enumerated() {
        let path = CGPath(roundedRect: CGRect(x: window.minX + 34, y: window.maxY - 108 - CGFloat(i) * 50, width: width, height: 20),
                          cornerWidth: 10, cornerHeight: 10, transform: nil)
        context.addPath(path)
        context.setFillColor(color(0x9AA8C8, i == 0 ? 0.95 : 0.55))
        context.fillPath()
    }
    context.restoreGState()

    // Glowing outline around the focused window.
    let ring = CGPath(roundedRect: window.insetBy(dx: -14, dy: -14), cornerWidth: 46, cornerHeight: 46, transform: nil)
    context.saveGState()
    context.setShadow(offset: .zero, blur: 18, color: color(0x6FD3FF, 1))
    context.addPath(ring)
    context.setStrokeColor(color(0x8FE0FF))
    context.setLineWidth(7)
    context.strokePath()
    context.restoreGState()

    // A soft highlight along the top edge of the icon.
    let shine = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 760), options: [])
    context.restoreGState()
}

func render(size: Int) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(context)
    return context.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: make-icon <output.iconset> [preview.png]")
    exit(1)
}
let iconset = arguments[1]
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    write(render(size: points), to: "\(iconset)/icon_\(points)x\(points).png")
    write(render(size: points * 2), to: "\(iconset)/icon_\(points)x\(points)@2x.png")
}
if arguments.count >= 3 { write(render(size: 1024), to: arguments[2]) }
