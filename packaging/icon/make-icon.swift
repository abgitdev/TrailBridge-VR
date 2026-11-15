import AppKit
import CoreGraphics
import Foundation

let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let source = directory.appendingPathComponent("source/trailbridge-icon-red.webp")
guard let image = NSImage(contentsOf: source),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Could not load icon source")
}
let width = cgImage.width, height = cgImage.height
let colorSpace = CGColorSpaceCreateDeviceRGB()
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let bounds: CGRect = pixels.withUnsafeMutableBytes { bytes in
    guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("Could not create source bitmap") }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            if max(bytes[i], bytes[i + 1], bytes[i + 2]) > 20 && bytes[i + 3] > 0 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
    }
    guard maxX >= minX, maxY >= minY else { fatalError("No artwork found") }
    // Bitmap rows run in the opposite direction to CGImage crop coordinates.
    return CGRect(x: minX, y: height - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
}
guard let artwork = cgImage.cropping(to: bounds),
      let canvas = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                             bytesPerRow: 0, space: colorSpace,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Could not create icon canvas")
}
let frame = CGRect(x: 100, y: 100, width: 824, height: 824)
canvas.addPath(CGPath(roundedRect: frame, cornerWidth: 185, cornerHeight: 185, transform: nil))
canvas.clip()
canvas.interpolationQuality = .high
canvas.draw(artwork, in: frame)
guard let output = canvas.makeImage(),
      let png = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon")
}
try png.write(to: directory.appendingPathComponent("AppIcon-1024.png"))
print("Artwork bounds: \(bounds); wrote 1024 × 1024 PNG")
