import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 512
        let transform = NSAffineTransform()
        transform.scale(by: factor)
        transform.concat()
        NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.91, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: 464, height: 464), xRadius: 108, yRadius: 108).fill()
        NSColor(calibratedRed: 0.19, green: 0.37, blue: 0.29, alpha: 1).setFill()
        let heights: [CGFloat] = [68, 136, 228, 302, 200, 126, 60]
        for (index, height) in heights.enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 110 + CGFloat(index) * 43, y: 256 - height / 2, width: 26, height: height), xRadius: 13, yRadius: 13).fill()
        }
        image.unlockFocus()
        let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try representation.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
