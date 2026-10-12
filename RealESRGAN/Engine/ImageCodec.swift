import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageCodec {
    enum CodecError: LocalizedError {
        case unreadable
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: "无法读取这张图片。"
            case .encodeFailed: "图片编码失败。"
            }
        }
    }

    /// Decodes an image at full resolution with its EXIF orientation applied.
    static func decode(data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw CodecError.unreadable }
        return try decode(source)
    }

    static func decode(url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CodecError.unreadable }
        return try decode(source)
    }

    private static func decode(_ source: CGImageSource) throws -> CGImage {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw CodecError.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CodecError.unreadable
        }
        return image
    }

    /// Returns a copy no larger than `maxPixel` on its longest side (for on-screen previews).
    static func downsample(_ image: CGImage, maxPixel: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixel, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        let scale = Double(maxPixel) / Double(longest)
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Encodes the image. JPEG cannot carry transparency, so transparent images fall back to PNG.
    static func encode(_ image: CGImage, as format: OutputFormat) throws -> (data: Data, format: OutputFormat) {
        let resolved: OutputFormat = (format == .jpeg && hasAlpha(image)) ? .png : format
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, resolved.utType.identifier as CFString, 1, nil)
        else { throw CodecError.encodeFailed }
        var properties: [CFString: Any] = [:]
        if resolved != .png {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.95
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CodecError.encodeFailed }
        return (data as Data, resolved)
    }
}
