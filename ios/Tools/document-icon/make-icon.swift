// Draws the icon of a .listen file: a page with Listen's winged light and LISTEN below it, at
// every size an .icns holds. Two looks: `dark` (the light glowing on a dark page) and `light`
// (the light in white on a white page, held by a cool glow).
//
// The light is the app's own orb (FluidOrb), rendered by the test `OrbPicture`:
//   TEST_RUNNER_ORB_OUT=<folder> TEST_RUNNER_LISTEN_ORB_FORM=sphere TEST_RUNNER_LISTEN_ORB_TIME=12 \
//     xcodebuild … -only-testing:ListenTests/OrbPicture test
// Then:
//   swift ios/Tools/document-icon/make-icon.swift <folder>/orb-dark.png <out>.iconset dark   (the shipped look)
//   iconutil -c icns <out>.iconset -o ios/DocumentIcon/ListenDocument.icns
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let orb = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("usage: make-icon.swift <orb png> <out.iconset> [dark|light]")
    exit(1)
}
let out = URL(fileURLWithPath: arguments[2])
let light = arguments.count > 3 && arguments[3] == "light"
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// The figure sits a little right of and above the centre of the render; a square around it.
let side = Double(orb.width) * 0.52
let crop = orb.cropping(to: CGRect(x: Double(orb.width) * 0.545 - side / 2, y: Double(orb.height) * 0.49 - side / 2,
                                   width: side, height: side))!

/// The render's brightness as a mask: where the light is, the mask is open.
let mask: CGImage = {
    let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
    let image = context.makeImage()!
    return CGImage(maskWidth: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 8,
                   bytesPerRow: image.bytesPerRow, provider: image.dataProvider!, decode: [1, 0], shouldInterpolate: true)!
}()

func page(in canvas: Double) -> CGPath {
    let left = 0.155 * canvas, right = 0.845 * canvas, bottom = 0.06 * canvas, top = 0.94 * canvas
    let radius = 0.045 * canvas, fold = 0.19 * canvas
    let path = CGMutablePath()
    path.move(to: CGPoint(x: left + radius, y: bottom))
    path.addLine(to: CGPoint(x: right - radius, y: bottom))
    path.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right, y: bottom + radius), radius: radius)
    path.addLine(to: CGPoint(x: right, y: top - fold))
    path.addLine(to: CGPoint(x: right - fold, y: top))
    path.addLine(to: CGPoint(x: left + radius, y: top))
    path.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left, y: top - radius), radius: radius)
    path.addLine(to: CGPoint(x: left, y: bottom + radius))
    path.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left + radius, y: bottom), radius: radius)
    path.closeSubpath()
    return path
}

func color(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func draw(size: Int) -> CGImage {
    let canvas = Double(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    let shape = page(in: canvas)

    // The page, with a soft shadow under it.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -0.01 * canvas), blur: 0.03 * canvas,
                      color: CGColor(gray: 0, alpha: light ? 0.25 : 0.45))
    context.addPath(shape)
    context.setFillColor(light ? color(1, 1, 1) : color(0.06, 0.06, 0.075))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let paper = light ? [color(1, 1, 1), color(0.94, 0.95, 0.97)] : [color(0.17, 0.17, 0.20), color(0.02, 0.02, 0.03)]
    let gradient = CGGradient(colorsSpace: space, colors: paper as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas), end: CGPoint(x: 0, y: 0), options: [])
    let figure = 0.64 * canvas
    let place = CGRect(x: (canvas - figure) / 2, y: size >= 128 ? 0.255 * canvas : 0.17 * canvas, width: figure, height: figure)
    if light {
        // A cool glow behind the body, then the light itself in white through the render's
        // brightness, with a blue shadow around it so its white wings show on white paper.
        let body = CGPoint(x: place.minX + 0.40 * figure, y: place.minY + 0.454 * figure)
        let glow = CGGradient(colorsSpace: space, colors: [color(0.62, 0.72, 0.95, 0.85), color(0.80, 0.86, 0.98, 0.35),
                                                            color(0.90, 0.93, 1, 0)] as CFArray, locations: [0, 0.45, 1])!
        context.drawRadialGradient(glow, startCenter: body, startRadius: 0, endCenter: body, endRadius: 0.42 * figure, options: [])
        // Twice: a wide shadow for the glow, a tight one for the edges of the wings.
        for (blur, alpha) in [(0.030, 0.75), (0.008, 0.9)] {
            context.setShadow(offset: .zero, blur: blur * canvas, color: color(0.20, 0.30, 0.62, alpha))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.clip(to: place, mask: mask)
            context.setFillColor(color(1, 1, 1))
            context.fill(place)
            context.endTransparencyLayer()
        }
    } else {
        // Black in the render, so it is laid on with screen and only its glow shows.
        context.setBlendMode(.screen)
        context.draw(crop, in: place)
    }
    context.restoreGState()

    // The folded corner.
    let right = 0.845 * canvas, top = 0.94 * canvas, fold = 0.19 * canvas
    let corner = CGMutablePath()
    corner.move(to: CGPoint(x: right - fold, y: top))
    corner.addLine(to: CGPoint(x: right - fold, y: top - fold + 0.03 * canvas))
    corner.addQuadCurve(to: CGPoint(x: right - fold + 0.03 * canvas, y: top - fold), control: CGPoint(x: right - fold, y: top - fold))
    corner.addLine(to: CGPoint(x: right, y: top - fold))
    corner.closeSubpath()
    context.addPath(corner)
    context.setFillColor(light ? color(0.84, 0.86, 0.90) : color(0.30, 0.30, 0.34))
    context.fillPath()

    // A fine edge, so the page stands out on any Finder background.
    context.addPath(shape)
    context.setStrokeColor(CGColor(gray: light ? 0 : 1, alpha: light ? 0.12 : 0.14))
    context.setLineWidth(max(1, 0.004 * canvas))
    context.strokePath()

    // The name, where it can be read.
    if size >= 128 {
        let font = NSFont.systemFont(ofSize: 0.075 * canvas, weight: .semibold)
        let text = NSAttributedString(string: "LISTEN", attributes: [
            .font: font, .kern: 0.012 * canvas,
            .foregroundColor: light ? NSColor(srgbRed: 0.22, green: 0.25, blue: 0.33, alpha: 0.9) : NSColor(white: 1, alpha: 0.78),
        ])
        let line = CTLineCreateWithAttributedString(text)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: (canvas - width) / 2 + 0.006 * canvas, y: 0.13 * canvas)
        CTLineDraw(line, context)
    }
    return context.makeImage()!
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    let destination = CGImageDestinationCreateWithURL(out.appending(path: name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, draw(size: points * scale), nil)
    CGImageDestinationFinalize(destination)
}
print("wrote \(out.path)")
