import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let s = rect.width

        // dark rounded background
        let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.22, yRadius: s * 0.22)
        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.11, alpha: 1).setFill()
        bg.fill()

        // background ring
        let inset = s * 0.20
        let ring = rect.insetBy(dx: inset, dy: inset)
        let track = NSBezierPath(ovalIn: ring)
        track.lineWidth = s * 0.10
        NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
        track.stroke()

        // green arc — sector as consumption indicator
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = ring.width / 2
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 340, clockwise: true)
        arc.lineWidth = s * 0.10
        arc.lineCapStyle = .round
        NSColor(calibratedRed: 0.19, green: 0.82, blue: 0.35, alpha: 1).setStroke()
        arc.stroke()

        // heartbeat in the middle
        let pulse = NSBezierPath()
        let w = ring.width * 0.62, h = s * 0.13
        let x0 = center.x - w / 2, y0 = center.y
        pulse.move(to: NSPoint(x: x0, y: y0))
        pulse.line(to: NSPoint(x: x0 + w * 0.28, y: y0))
        pulse.line(to: NSPoint(x: x0 + w * 0.42, y: y0 + h))
        pulse.line(to: NSPoint(x: x0 + w * 0.58, y: y0 - h))
        pulse.line(to: NSPoint(x: x0 + w * 0.72, y: y0))
        pulse.line(to: NSPoint(x: x0 + w, y: y0))
        pulse.lineWidth = s * 0.055
        pulse.lineCapStyle = .round
        pulse.lineJoinStyle = .round
        NSColor.white.setStroke()
        pulse.stroke()
        return true
    }
    return image
}

func save(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

func run() {
    let sizes: [(Int, String)] = [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),
        (128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")]
    let dir = "/tmp/icongen/AIPulse.iconset"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (px, name) in sizes {
        save(drawIcon(size: CGFloat(px)), to: "\(dir)/icon_\(name).png")
    }
    save(drawIcon(size: 512), to: "/tmp/icongen/preview.png")
    print("  rendered \(sizes.count) sizes")
}
run()
