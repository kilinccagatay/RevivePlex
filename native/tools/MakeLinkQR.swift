import CoreImage
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum QRError: Error { case usage, encode }
guard CommandLine.arguments.count == 2 else { throw QRError.usage }
let file = URL(fileURLWithPath: CommandLine.arguments[1])
let filter = CIFilter(name: "CIQRCodeGenerator", parameters: [
    "inputMessage": Data("https://plex.tv/link".utf8),
    "inputCorrectionLevel": "M"
])
let ci = CIContext()
guard let modules = filter?.outputImage,
      let image = ci.createCGImage(modules, from: modules.extent) else { throw QRError.encode }
let scale = 10
let margin = scale * 4
let pixels = image.width * scale + 2 * margin
guard let render = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
    bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw QRError.encode }
render.setFillColor(gray: 1, alpha: 1)
render.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
render.interpolationQuality = .none
render.draw(image, in: CGRect(x: margin, y: margin, width: image.width * scale, height: image.height * scale))
guard let result = render.makeImage(),
      let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
else { throw QRError.encode }
CGImageDestinationAddImage(dest, result, nil)
guard CGImageDestinationFinalize(dest) else { throw QRError.encode }
