import Accelerate
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import VideoToolbox

struct UpscaleOptions: Sendable {
    var model: SRModelKind
    var denoise: Double
    var outscale: Double
    var computeUnits: MLComputeUnits
    /// Context pixels kept around each tile (`--tile_pad` in the Python CLI).
    var tilePad: Int = 16
}

enum UpscaleProgress: Sendable {
    case loadingModel
    case tiles(completed: Int, total: Int)
}

struct UpscaleOutput: @unchecked Sendable {
    let image: CGImage
    let outscale: Double
    let tileCount: Int
}

enum UpscaleError: LocalizedError {
    case modelMissing(String)
    case invalidImage
    case inputTooLarge
    case allocationFailed
    case unexpectedOutput

    var errorDescription: String? {
        switch self {
        case .modelMissing(let name): "找不到模型 \(name)，安装包可能不完整。"
        case .invalidImage: "无法读取这张图片。"
        case .inputTooLarge: "图片尺寸过大，无法处理。"
        case .allocationFailed: "内存不足，请降低输出倍率后重试。"
        case .unexpectedOutput: "模型输出异常。"
        }
    }
}

private struct ModelBox: @unchecked Sendable {
    let model: MLModel
}

/// Runs a Real-ESRGAN Core ML model over an image tile by tile, mirroring
/// `RealESRGANer.tile_process` from the Python implementation.
actor Upscaler {
    static let shared = Upscaler()

    /// Upper bound for the result size (~480 MB of BGRA pixels).
    static let maxOutputPixels = 120_000_000

    private var loadedKey: String?
    private var loadedModel: MLModel?
    /// In-flight load, shared by `prepare` and `upscale` so a model is never compiled twice.
    private var pending: (key: String, task: Task<ModelBox, Error>)?

    /// The output scale actually used for an input, capped by `maxOutputPixels`.
    static func effectiveOutscale(width: Int, height: Int, requested: Double) -> Double {
        let limit = (Double(maxOutputPixels) / Double(max(1, width * height))).squareRoot()
        return min(requested, (limit * 100).rounded(.down) / 100)
    }

    func upscale(
        _ image: CGImage,
        options: UpscaleOptions,
        progress: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> UpscaleOutput {
        progress(.loadingModel)
        let modelName = options.model.resourceName(denoise: options.denoise)
        var units = options.computeUnits
        var mlModel = try await model(named: modelName, units: units)
        try Task.checkCancellation()

        guard let constraint = mlModel.modelDescription.inputDescriptionsByName["input"]?.imageConstraint else {
            throw UpscaleError.unexpectedOutput
        }
        let tile = constraint.pixelsWide
        let pad = min(options.tilePad, tile / 4)
        let core = tile - 2 * pad

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw UpscaleError.invalidImage }
        let outscale = Self.effectiveOutscale(width: width, height: height, requested: options.outscale)
        guard outscale >= 1 else { throw UpscaleError.inputTooLarge }
        let outWidth = max(1, Int((Double(width) * outscale).rounded()))
        let outHeight = max(1, Int((Double(height) * outscale).rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw UpscaleError.allocationFailed }
        let littleEndian = CGBitmapInfo.byteOrder32Little.rawValue

        // 1. Decode into an unpremultiplied BGRA buffer, at least one tile in each dimension.
        let srcWidth = max(width, tile)
        let srcHeight = max(height, tile)
        let srcRowBytes = srcWidth * 4
        let src = UnsafeMutableRawPointer.allocate(byteCount: srcRowBytes * srcHeight, alignment: 64)
        defer { src.deallocate() }
        src.initializeMemory(as: UInt8.self, repeating: 0, count: srcRowBytes * srcHeight)
        guard let srcContext = CGContext(
            data: src, width: width, height: height, bitsPerComponent: 8, bytesPerRow: srcRowBytes,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | littleEndian
        ) else { throw UpscaleError.allocationFailed }
        srcContext.interpolationQuality = .none
        srcContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 2. Split off the alpha channel; it is resampled separately like `--alpha_upsampler bicubic`.
        var alpha: UnsafeMutablePointer<UInt8>?
        defer { alpha?.deallocate() }
        if Self.hasAlpha(image) {
            var buffer = vImage_Buffer(
                data: src, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: srcRowBytes)
            // Alpha is the last byte in BGRA too, so the RGBA variant applies.
            vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
            let plane = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
            var minAlpha: UInt8 = 255
            for y in 0..<height {
                let row = src.advanced(by: y * srcRowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let a = row[x * 4 + 3]
                    plane[y * width + x] = a
                    minAlpha = min(minAlpha, a)
                    row[x * 4 + 3] = 255
                }
            }
            if minAlpha < 255 {
                alpha = plane
            } else {
                plane.deallocate()
            }
        }

        // 3. Replicate edges so images smaller than a tile can still be fed to the fixed-size model.
        if srcWidth > width {
            for y in 0..<height {
                let row = src.advanced(by: y * srcRowBytes)
                let edge = row.load(fromByteOffset: (width - 1) * 4, as: UInt32.self)
                for x in width..<srcWidth {
                    row.storeBytes(of: edge, toByteOffset: x * 4, as: UInt32.self)
                }
            }
        }
        if srcHeight > height {
            let last = src.advanced(by: (height - 1) * srcRowBytes)
            for y in height..<srcHeight {
                src.advanced(by: y * srcRowBytes).copyMemory(from: last, byteCount: srcRowBytes)
            }
        }

        // 4. Output canvas.
        let outRowBytes = outWidth * 4
        let outByteCount = outRowBytes * outHeight
        let out = UnsafeMutableRawPointer.allocate(byteCount: outByteCount, alignment: 64)
        var outOwned = true
        defer { if outOwned { out.deallocate() } }
        guard let outContext = CGContext(
            data: out, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: outRowBytes,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | littleEndian
        ) else { throw UpscaleError.allocationFailed }
        outContext.interpolationQuality = .high

        var inputBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, tile, tile, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &inputBuffer
        ) == kCVReturnSuccess, let inputBuffer else { throw UpscaleError.allocationFailed }

        // 5. Tile loop. Each tile owns a `core` x `core` region and sees `pad` pixels of context around it.
        let columns = (width + core - 1) / core
        let rows = (height + core - 1) / core
        let total = columns * rows
        let sx = Double(outWidth) / Double(width)
        let sy = Double(outHeight) / Double(height)
        var completed = 0
        progress(.tiles(completed: 0, total: total))

        for row in 0..<rows {
            for column in 0..<columns {
                try Task.checkCancellation()

                let cx0 = column * core, cx1 = min(cx0 + core, width)
                let cy0 = row * core, cy1 = min(cy0 + core, height)
                let wx = min(max(cx0 - pad, 0), srcWidth - tile)
                let wy = min(max(cy0 - pad, 0), srcHeight - tile)

                CVPixelBufferLockBaseAddress(inputBuffer, [])
                if let dst = CVPixelBufferGetBaseAddress(inputBuffer) {
                    let dstRowBytes = CVPixelBufferGetBytesPerRow(inputBuffer)
                    for r in 0..<tile {
                        dst.advanced(by: r * dstRowBytes).copyMemory(
                            from: src.advanced(by: (wy + r) * srcRowBytes + wx * 4), byteCount: tile * 4)
                    }
                }
                CVPixelBufferUnlockBaseAddress(inputBuffer, [])

                let features = try MLDictionaryFeatureProvider(
                    dictionary: ["input": MLFeatureValue(pixelBuffer: inputBuffer)])
                // iOS does not let a backgrounded app submit GPU work, so move the remaining tiles
                // to the Neural Engine once the app leaves the screen.
                if Self.usesGPU(units), AppActivity.shared.isInBackground {
                    units = .cpuAndNeuralEngine
                    mlModel = try await model(named: modelName, units: units)
                }
                let prediction: MLFeatureProvider
                do {
                    prediction = try await mlModel.prediction(from: features)
                } catch where Self.usesGPU(units) && !Task.isCancelled {
                    units = .cpuAndNeuralEngine
                    mlModel = try await model(named: modelName, units: units)
                    prediction = try await mlModel.prediction(from: features)
                }
                guard let outputBuffer = prediction.featureValue(for: "output")?.imageBufferValue,
                      let tileImage = Self.makeImage(from: outputBuffer, colorSpace: colorSpace)
                else { throw UpscaleError.unexpectedOutput }

                // Destination of the core region (integer pixels, so neighbouring tiles meet exactly).
                let dx0 = Int((Double(cx0) * sx).rounded(.down))
                let dx1 = cx1 == width ? outWidth : Int((Double(cx1) * sx).rounded(.down))
                let dy0 = Int((Double(cy0) * sy).rounded(.down))
                let dy1 = cy1 == height ? outHeight : Int((Double(cy1) * sy).rounded(.down))
                // Core Graphics has a bottom-left origin.
                let clip = CGRect(x: dx0, y: outHeight - dy1, width: dx1 - dx0, height: dy1 - dy0)
                let window = CGRect(
                    x: Double(wx) * sx, y: Double(outHeight) - Double(wy + tile) * sy,
                    width: Double(tile) * sx, height: Double(tile) * sy)
                outContext.saveGState()
                outContext.clip(to: clip)
                outContext.draw(tileImage, in: window)
                outContext.restoreGState()

                completed += 1
                progress(.tiles(completed: completed, total: total))
            }
        }

        // 6. Re-attach the alpha channel.
        if let alpha {
            let scaled = UnsafeMutablePointer<UInt8>.allocate(capacity: outWidth * outHeight)
            defer { scaled.deallocate() }
            var alphaSrc = vImage_Buffer(
                data: alpha, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
            var alphaDst = vImage_Buffer(
                data: scaled, height: vImagePixelCount(outHeight), width: vImagePixelCount(outWidth), rowBytes: outWidth)
            vImageScale_Planar8(&alphaSrc, &alphaDst, nil, vImage_Flags(kvImageHighQualityResampling))
            let bytes = out.assumingMemoryBound(to: UInt8.self)
            for i in 0..<(outWidth * outHeight) {
                bytes[i * 4 + 3] = scaled[i]
            }
        }

        let alphaInfo: CGImageAlphaInfo = alpha == nil ? .noneSkipFirst : .first
        guard let provider = CGDataProvider(
            dataInfo: nil, data: out, size: outByteCount,
            releaseData: { _, data, _ in UnsafeMutableRawPointer(mutating: data).deallocate() }
        ) else { throw UpscaleError.allocationFailed }
        outOwned = false
        guard let result = CGImage(
            width: outWidth, height: outHeight, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: outRowBytes,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue | littleEndian),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ) else { throw UpscaleError.allocationFailed }

        return UpscaleOutput(image: result, outscale: outscale, tileCount: total)
    }

    /// Loads (and, on first use, compiles for the chosen processor) a model ahead of time.
    /// Returns `true` when the model was already in memory.
    @discardableResult
    func prepare(_ kind: SRModelKind, denoise: Double, units: MLComputeUnits) async throws -> Bool {
        let name = kind.resourceName(denoise: denoise)
        let cached = Self.key(name, units) == loadedKey
        _ = try await model(named: name, units: units)
        return cached
    }

    /// Releases the cached model (e.g. on memory warnings).
    func unload() {
        pending?.task.cancel()
        pending = nil
        loadedModel = nil
        loadedKey = nil
    }

    private static func key(_ name: String, _ units: MLComputeUnits) -> String { "\(name)|\(units.rawValue)" }

    private func model(named name: String, units: MLComputeUnits) async throws -> MLModel {
        let key = Self.key(name, units)
        if key == loadedKey, let loadedModel { return loadedModel }
        if let pending, pending.key == key { return try await pending.task.value.model }

        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc", subdirectory: "Models") else {
            throw UpscaleError.modelMissing(name)
        }
        // Drop the previous model first so two large networks are never resident at once.
        loadedModel = nil
        loadedKey = nil
        let task = Task<ModelBox, Error> {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            configuration.allowLowPrecisionAccumulationOnGPU = true
            return ModelBox(model: try await MLModel.load(contentsOf: url, configuration: configuration))
        }
        pending = (key, task)
        do {
            let model = try await task.value.model
            if pending?.key == key {
                pending = nil
                loadedModel = model
                loadedKey = key
            }
            return model
        } catch {
            if pending?.key == key { pending = nil }
            throw error
        }
    }

    private static func usesGPU(_ units: MLComputeUnits) -> Bool {
        units == .all || units == .cpuAndGPU
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    private static func makeImage(from buffer: CVPixelBuffer, colorSpace: CGColorSpace) -> CGImage? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let bitmapInfo: UInt32
        switch format {
        case kCVPixelFormatType_32BGRA:
            bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        case kCVPixelFormatType_32ARGB:
            bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        default:
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            return image
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let data = CFDataCreate(nil, base.assumingMemoryBound(to: UInt8.self), rowBytes * height),
              let provider = CGDataProvider(data: data)
        else { return nil }
        return CGImage(
            width: CVPixelBufferGetWidth(buffer), height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: rowBytes, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
