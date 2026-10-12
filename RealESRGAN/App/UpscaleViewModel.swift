import Observation
import Photos
import PhotosUI
import SwiftUI
import UIKit

@MainActor
@Observable
final class UpscaleViewModel {
    enum Phase: Equatable {
        case empty
        case ready
        case loadingModel
        case processing(completed: Int, total: Int)
        case encoding
        case done
    }

    // MARK: Image state

    private(set) var phase: Phase = .empty
    private(set) var source: CGImage?
    private(set) var sourcePreview: UIImage?
    private(set) var resultPreview: UIImage?
    private(set) var resultFileURL: URL?
    private(set) var resultSize: CGSize?
    private(set) var elapsed: TimeInterval?
    private(set) var completedCount = 0
    private var resultData: Data?
    private var sourceName = "image"
    private var task: Task<Void, Never>?

    var errorMessage: String?
    var toast: String?

    // MARK: Settings (persisted)

    var model: SRModelKind {
        didSet { defaults.set(model.rawValue, forKey: "model"); invalidateResult() }
    }
    var outscale: Double {
        didSet { defaults.set(outscale, forKey: "outscale"); invalidateResult() }
    }
    var denoise: Double {
        didSet { defaults.set(denoise, forKey: "denoise"); invalidateResult() }
    }
    var outputFormat: OutputFormat {
        didSet { defaults.set(outputFormat.rawValue, forKey: "format") }
    }
    var compute: ComputeChoice {
        didSet {
            defaults.set(compute.rawValue, forKey: "compute")
            Task { await Upscaler.shared.unload() }
        }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        let defaults = UserDefaults.standard
        model = SRModelKind(rawValue: defaults.string(forKey: "model") ?? "") ?? .x4plus
        outscale = defaults.object(forKey: "outscale") as? Double ?? 4
        denoise = defaults.object(forKey: "denoise") as? Double ?? 0.5
        outputFormat = OutputFormat(rawValue: defaults.string(forKey: "format") ?? "") ?? .png
        compute = ComputeChoice(rawValue: defaults.string(forKey: "compute") ?? "") ?? .all
    }

    // MARK: Derived

    var hasSource: Bool { source != nil }
    var hasResult: Bool { phase == .done && resultPreview != nil }

    var isBusy: Bool {
        switch phase {
        case .loadingModel, .processing, .encoding: true
        default: false
        }
    }

    var progress: Double {
        if case .processing(let completed, let total) = phase, total > 0 {
            return Double(completed) / Double(total)
        }
        return 0
    }

    var sourceSizeText: String? {
        guard let source else { return nil }
        return "\(source.width) × \(source.height)"
    }

    var targetSizeText: String? {
        if let resultSize { return "\(Int(resultSize.width)) × \(Int(resultSize.height))" }
        guard let source else { return nil }
        let scale = Upscaler.effectiveOutscale(width: source.width, height: source.height, requested: outscale)
        guard scale >= 1 else { return nil }
        return "\(Int((Double(source.width) * scale).rounded())) × \(Int((Double(source.height) * scale).rounded()))"
    }

    /// True when the requested scale had to be reduced to stay within the memory budget.
    var isScaleCapped: Bool {
        guard let source else { return false }
        return Upscaler.effectiveOutscale(width: source.width, height: source.height, requested: outscale) < outscale
    }

    var elapsedText: String? {
        guard let elapsed, phase == .done else { return nil }
        return elapsed.formatted(.number.precision(.fractionLength(1))) + " 秒"
    }

    // MARK: Loading

    func load(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ImageCodec.CodecError.unreadable
            }
            let image = try await Task.detached(priority: .userInitiated) { try ImageCodec.decode(data: data) }.value
            setSource(image, name: "photo")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func load(url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let image = try await Task.detached(priority: .userInitiated) { try ImageCodec.decode(url: url) }.value
            setSource(image, name: url.deletingPathExtension().lastPathComponent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setSource(_ image: CGImage, name: String) {
        cancel()
        source = image
        sourceName = name
        sourcePreview = UIImage(cgImage: ImageCodec.downsample(image, maxPixel: 2048))
        clearResult()
        phase = .ready
    }

    func clear() {
        cancel()
        source = nil
        sourcePreview = nil
        clearResult()
        phase = .empty
    }

    // MARK: Processing

    func start() {
        guard let source, !isBusy else { return }
        clearResult()
        phase = .loadingModel

        let options = UpscaleOptions(
            model: model, denoise: denoise, outscale: outscale, computeUnits: compute.units)
        let format = outputFormat
        let baseName = "\(sourceName)_\(model.rawValue)_x\(outscale.formatted(.number.precision(.fractionLength(0...2))))"
        let began = Date()

        task = Task {
            let application = UIApplication.shared
            let backgroundTask = application.beginBackgroundTask(withName: "upscale")
            application.isIdleTimerDisabled = true
            let (updates, continuation) = AsyncStream.makeStream(
                of: UpscaleProgress.self, bufferingPolicy: .bufferingNewest(1))
            let progressTask = Task {
                for await update in updates { apply(update) }
            }
            defer {
                continuation.finish()
                progressTask.cancel()
                application.isIdleTimerDisabled = false
                application.endBackgroundTask(backgroundTask)
            }

            do {
                let output = try await Upscaler.shared.upscale(source, options: options) { update in
                    continuation.yield(update)
                }
                try Task.checkCancellation()
                phase = .encoding

                let rendered = try await Task.detached(priority: .userInitiated) {
                    let preview = ImageCodec.downsample(output.image, maxPixel: 4096)
                    let encoded = try ImageCodec.encode(output.image, as: format)
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent(baseName)
                        .appendingPathExtension(encoded.format.fileExtension)
                    try encoded.data.write(to: url, options: .atomic)
                    return (preview: UIImage(cgImage: preview), data: encoded.data, url: url)
                }.value
                try Task.checkCancellation()

                resultPreview = rendered.preview
                resultData = rendered.data
                resultFileURL = rendered.url
                resultSize = CGSize(width: output.image.width, height: output.image.height)
                elapsed = Date().timeIntervalSince(began)
                completedCount += 1
                phase = .done
            } catch {
                // `cancel()` has already reset the phase for cancelled runs.
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                phase = .ready
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isBusy { phase = .ready }
    }

    private func apply(_ update: UpscaleProgress) {
        guard isBusy, phase != .encoding else { return }
        switch update {
        case .loadingModel:
            phase = .loadingModel
        case .tiles(let completed, let total):
            phase = .processing(completed: completed, total: total)
        }
    }

    private func invalidateResult() {
        guard phase == .done else { return }
        clearResult()
        phase = .ready
    }

    private func clearResult() {
        if let resultFileURL { try? FileManager.default.removeItem(at: resultFileURL) }
        resultPreview = nil
        resultData = nil
        resultFileURL = nil
        resultSize = nil
        elapsed = nil
    }

    // MARK: Export

    func saveToPhotos() async {
        guard let resultData else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            errorMessage = "没有相册写入权限，请在“设置”中允许访问照片。"
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: resultData, options: nil)
            }
            showToast("已保存到相册")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toast == message { toast = nil }
        }
    }
}
