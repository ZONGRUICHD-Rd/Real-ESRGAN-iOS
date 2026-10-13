import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Metadata (EXIF, TIFF, GPS, IPTC, …) read from the original file.
struct ImageMetadata: @unchecked Sendable {
    let properties: [CFString: Any]

    private var exif: [CFString: Any]? { properties[kCGImagePropertyExifDictionary] as? [CFString: Any] }
    private var tiff: [CFString: Any]? { properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] }

    var hasLocation: Bool { properties[kCGImagePropertyGPSDictionary] != nil }

    /// Whether there is anything worth carrying over (camera, capture date, location…).
    var isEmpty: Bool { exif == nil && tiff == nil && !hasLocation }

    var camera: String? {
        let make = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        guard let model, !model.isEmpty else { return make }
        if let make, !make.isEmpty, !model.localizedCaseInsensitiveContains(make) { return "\(make) \(model)" }
        return model
    }

    /// Capture time as stored in EXIF (`yyyy:MM:dd HH:mm:ss`), shown as `yyyy-MM-dd HH:mm`.
    var captureDate: String? {
        guard let raw = exif?[kCGImagePropertyExifDateTimeOriginal] as? String, raw.count >= 16 else { return nil }
        let parts = raw.prefix(16).split(separator: " ")
        guard parts.count == 2 else { return nil }
        return parts[0].replacingOccurrences(of: ":", with: "-") + " " + parts[1]
    }

    /// Properties for the upscaled file: dimensions, orientation and colour info describe the
    /// new pixels, and GPS is dropped unless `includeLocation` is set.
    func forOutput(width: Int, height: Int, includeLocation: Bool) -> [CFString: Any] {
        var result = properties
        // Describe the source encoding rather than the photo itself.
        let sourceOnly: [CFString] = [
            kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
            kCGImagePropertyHasAlpha, kCGImagePropertyColorModel, kCGImagePropertyProfileName,
            kCGImagePropertyIsFloat, kCGImagePropertyIsIndexed, kCGImagePropertyOrientation,
            kCGImagePropertyJFIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyGIFDictionary,
            kCGImagePropertyHEIFDictionary,
            // Apple maker notes carry HDR gain-map parameters that no longer match the pixels.
            kCGImagePropertyMakerAppleDictionary,
        ]
        for key in sourceOnly { result.removeValue(forKey: key) }
        if !includeLocation { result.removeValue(forKey: kCGImagePropertyGPSDictionary) }

        // The decoder already applied the EXIF orientation to the pixels.
        result[kCGImagePropertyOrientation] = 1
        var tiff = tiff ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = 1
        tiff[kCGImagePropertyTIFFSoftware] = "Real-ESRGAN for iOS"
        result[kCGImagePropertyTIFFDictionary] = tiff

        if var exif {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            exif[kCGImagePropertyExifColorSpace] = 1  // sRGB
            result[kCGImagePropertyExifDictionary] = exif
        }
        return result
    }
}

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
    static func decode(data: Data) throws -> (image: CGImage, metadata: ImageMetadata) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw CodecError.unreadable }
        return try decode(source)
    }

    static func decode(url: URL) throws -> (image: CGImage, metadata: ImageMetadata) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CodecError.unreadable }
        return try decode(source)
    }

    private static func decode(_ source: CGImageSource) throws -> (image: CGImage, metadata: ImageMetadata) {
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
        return (image, ImageMetadata(properties: properties))
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
    static func encode(
        _ image: CGImage, as format: OutputFormat, metadata: [CFString: Any]? = nil
    ) throws -> (data: Data, format: OutputFormat) {
        let resolved: OutputFormat = (format == .jpeg && hasAlpha(image)) ? .png : format
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, resolved.utType.identifier as CFString, 1, nil)
        else { throw CodecError.encodeFailed }
        var properties = metadata ?? [:]
        if resolved != .png {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.95
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CodecError.encodeFailed }
        return (data as Data, resolved)
    }
}
