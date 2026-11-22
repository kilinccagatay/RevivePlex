import AVFoundation
import CoreVideo
import Foundation

enum FixtureError: Error {
    case usage, writer, buffer
}

guard CommandLine.arguments.count == 2 else { throw FixtureError.usage }
let file = URL(fileURLWithPath: CommandLine.arguments[1])
let width = 320
let height = 180
let frames = 72
let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
        AVVideoProfileLevelKey: AVVideoProfileLevelH264Baseline30,
        AVVideoAverageBitRateKey: 256_000
    ]
])
let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
    ])
guard writer.canAdd(input) else { throw FixtureError.writer }
writer.add(input)
guard writer.startWriting() else { throw writer.error ?? FixtureError.writer }
writer.startSession(atSourceTime: .zero)
guard let pool = adapter.pixelBufferPool else { throw FixtureError.buffer }

for frame in 0..<frames {
    let deadline = Date().addingTimeInterval(5)
    while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    guard input.isReadyForMoreMediaData else { throw writer.error ?? FixtureError.writer }
    var pixelBuffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
          let pixelBuffer else { throw FixtureError.buffer }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    for row in 0..<height {
        for column in 0..<width {
            let pixel = base.advanced(by: row * stride + column * 4)
            let bar = column >= frame * 4 && column < frame * 4 + 28
            pixel[0] = bar ? 32 : 72
            pixel[1] = bar ? 166 : 44
            pixel[2] = bar ? 245 : 24
            pixel[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    guard adapter.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 24))
    else { throw writer.error ?? FixtureError.writer }
}
input.markAsFinished()
writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 24))
await writer.finishWriting()
guard writer.status == .completed else { throw writer.error ?? FixtureError.writer }

let asset = AVURLAsset(url: file)
guard let track = try await asset.loadTracks(withMediaType: .video).first,
      let format = try await track.load(.formatDescriptions).first,
      CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264
else { throw FixtureError.writer }
let duration = try await asset.load(.duration)
print("Verified local H.264 fixture, \(width)×\(height), \(duration.seconds) seconds")
