// Render the vector logo for review and package the existing Router artwork as ICNS.
// Usage: swift ios/Tools/app-icons/render.swift <repo-root> <output-folder>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("Expected repository root and output folder") }
let root = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func png(_ image: NSImage, size: Int, background: Bool) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    if background {
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSGradient(starting: NSColor(srgbRed: 0.1, green: 0.1, blue: 0.11, alpha: 1),
                   ending: .black)!.draw(in: rect, angle: -90)
    }
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

guard let listen = NSImage(contentsOf: root.appending(path: "ios/AppIcon.icon/Assets/wave.svg")),
      let router = NSImage(contentsOf: root.appending(path: "backend/crates/router-app/icons/router.svg")) else {
    fatalError("The source artwork could not be read")
}
for size in [16, 32, 64, 128, 256, 512, 1024] {
    try png(listen, size: size, background: true).write(to: output.appending(path: "listen-\(size).png"))
    try png(router, size: size, background: false).write(to: output.appending(path: "router-\(size).png"))
}
let iconset = output.appending(path: "Router.iconset", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try png(router, size: points * scale, background: false)
            .write(to: iconset.appending(path: "icon_\(points)x\(points)\(suffix).png"))
    }
}

// A separate monochrome template keeps the menu-bar glyph legible in both themes.
if let tray = NSImage(contentsOf: root.appending(path: "backend/crates/router-app/icons/tray.svg")) {
    for size in [32, 64] {
        try png(tray, size: size, background: false).write(to: output.appending(path: "tray-\(size).png"))
    }
}
