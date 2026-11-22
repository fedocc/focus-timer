import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = base * scale
        let s = CGFloat(size)
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setAllowsAntialiasing(true)
        context.addPath(CGPath(roundedRect: CGRect(x: s * 0.08, y: s * 0.08, width: s * 0.84, height: s * 0.84),
            cornerWidth: s * 0.185, cornerHeight: s * 0.185, transform: nil))
        context.saveGState()
        context.clip()
        let colors = [CGColor(red: 0.05, green: 0.40, blue: 0.96, alpha: 1), CGColor(red: 0.13, green: 0.63, blue: 1, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: s), options: [])
        context.restoreGState()
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(s * 0.036)
        context.setLineCap(.round)
        context.strokeEllipse(in: CGRect(x: s * 0.275, y: s * 0.255, width: s * 0.45, height: s * 0.45))
        context.move(to: CGPoint(x: s * 0.5, y: s * 0.48))
        context.addLine(to: CGPoint(x: s * 0.5, y: s * 0.63))
        context.move(to: CGPoint(x: s * 0.5, y: s * 0.725))
        context.addLine(to: CGPoint(x: s * 0.5, y: s * 0.79))
        context.move(to: CGPoint(x: s * 0.435, y: s * 0.79))
        context.addLine(to: CGPoint(x: s * 0.565, y: s * 0.79))
        context.move(to: CGPoint(x: s * 0.69, y: s * 0.67))
        context.addLine(to: CGPoint(x: s * 0.735, y: s * 0.715))
        context.strokePath()
        let image = NSBitmapImageRep(cgImage: context.makeImage()!)
        let suffix = scale == 2 ? "@2x" : ""
        try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
