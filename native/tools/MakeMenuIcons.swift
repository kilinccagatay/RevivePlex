import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum IconError: Error { case input, output }

let args = CommandLine.arguments
guard args.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let logo = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw IconError.input }
let output = URL(fileURLWithPath: args[2], isDirectory: true)

for (height, width, pixels) in [(720, 188, 106), (1080, 282, 159)] {
    guard let context = CGContext(data: nil, width: width, height: pixels,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw IconError.output }
    let tile = CGRect(x: 0, y: 0, width: width, height: pixels)
    let radius = Double(pixels) * 0.085
    context.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    context.setFillColor(red: 0.035, green: 0.035, blue: 0.039, alpha: 1)
    context.fill(tile)
    let factor = min(Double(width) * 0.66 / Double(logo.width), Double(pixels) * 0.64 / Double(logo.height))
    let w = Double(logo.width) * factor
    let h = Double(logo.height) * factor
    context.interpolationQuality = .high
    context.draw(logo, in: CGRect(x: (Double(width) - w) / 2, y: (Double(pixels) - h) / 2, width: w, height: h))
    let path = output.appendingPathComponent("RevivePlex@\(height).png")
    guard let frame = context.makeImage(),
          let dest = CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw IconError.output }
    CGImageDestinationAddImage(dest, frame, nil)
    guard CGImageDestinationFinalize(dest) else { throw IconError.output }
}
