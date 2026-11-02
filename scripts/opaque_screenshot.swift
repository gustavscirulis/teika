import CoreGraphics
import Foundation
import ImageIO

struct CaptureError: Error, CustomStringConvertible {
    let description: String
}

func load(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw CaptureError(description: "Cannot decode screenshot PNG")
    }
    return image
}

func raster(_ image: CGImage, space: CGColorSpace, alpha: CGImageAlphaInfo) throws -> CGContext {
    guard let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: space, bitmapInfo: alpha.rawValue) else {
        throw CaptureError(description: "Cannot allocate screenshot raster")
    }
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw CaptureError(description: "Expected input PNG and output PNG paths")
    }
    let input = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    let image = try load(input)
    guard image.bitsPerComponent == 8, let space = image.colorSpace, space.model == .rgb else {
        throw CaptureError(description: "Expected an 8-bit RGB screenshot")
    }
    let source = try raster(image, space: space, alpha: .premultipliedLast)
    let bytes = source.data!.assumingMemoryBound(to: UInt8.self)
    for pixel in 0..<(image.width * image.height) where bytes[pixel * 4 + 3] != 255 {
        throw CaptureError(description: "Screenshot contains transparent pixels; refusing to change its appearance")
    }
    let opaque = try raster(image, space: space, alpha: .noneSkipLast)
    guard let opaqueImage = opaque.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
        throw CaptureError(description: "Cannot create opaque screenshot PNG")
    }
    CGImageDestinationAddImage(destination, opaqueImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CaptureError(description: "Cannot write opaque screenshot PNG")
    }
    let saved = try load(output)
    guard saved.width == image.width, saved.height == image.height,
          saved.alphaInfo == .none || saved.alphaInfo == .noneSkipFirst || saved.alphaInfo == .noneSkipLast else {
        throw CaptureError(description: "Opaque screenshot dimensions or alpha format changed unexpectedly")
    }
    let roundTrip = try raster(saved, space: space, alpha: .premultipliedLast)
    let length = image.width * image.height * 4
    guard Data(bytes: source.data!, count: length) == Data(bytes: roundTrip.data!, count: length) else {
        throw CaptureError(description: "Opaque screenshot pixels changed; refusing converted file")
    }
    print("Exported opaque RGB PNG with identical pixels: \(output.lastPathComponent)")
} catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}
