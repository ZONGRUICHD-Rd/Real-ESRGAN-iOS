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

    enum ModelState: Equatable {
        case idle
        case preparing
        case ready(loadTime: TimeInterval?)
        case failed(String)
    }

    // MARK: Image state

    private(set) var phase: Phase = .empty
    private(set) var modelState: ModelState = .idle
    private(set) var source: CGImage?
    private(set) var sourcePreview: UIImage?
    private(set) var resultPreview: UIImage?
    private(set) var resultFileURL: URL?
    private(set) var resultSize: CGSize?
    private(set) var resultByteCount: Int?
    private(set) var elapsed: TimeInterval?
    private(set) var remaining: TimeInterval?
    private(set) var completedCount = 0
    private(set) var sourceMetadata: ImageMetadata?
    private var resultData: Data?
    private var resultImage: CGImage?
    private var resultBaseName = "image"
    private var sourceName = "image"
    private var task: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var tilesStartedAt: Date?
    private var session: ProcessingSession?
    /// Whether the current run may keep going for long in the background (BGContinuedProcessingTask).
    private(set) var runsInBackground = false
    /// Live Activity / background-task status of the latest run, for the diagnostics section.
    private(set) var backgroundDiagnostics: BackgroundDiagnostics?

    var errorMessage: String?
    var toast: String?

    // MARK: Settings (persisted)

    var model: SRModelKind {
        didSet { settingChanged(model.rawValue, "model", reloadsModel: true) }
    }
    var outscale: Double {
        didSet { settingChanged(outscale, "outscale", reloadsModel: false) }
    }
    var denoise: Double {
        didSet { settingChanged(denoise, "denoise", reloadsModel: true) }
    }
    var outputFormat: OutputFormat {
        didSet {
            UserDefaults.standard.set(outputFormat.rawValue, forKey: "format")
            reencodeResult()
        }
    }
    /// Copy the original photo's EXIF/TIFF/IPTC metadata into the upscaled file.
    var keepMetadata: Bool {
        didSet {
            UserDefaults.standard.set(keepMetadata, forKey: "keepMetadata")
            reencodeResult()
        }
    }
    /// Show our own Live Activity (Dynamic Island / Lock Screen) while upscaling.
    var showsLiveActivity: Bool {
        didSet { UserDefaults.standard.set(showsLiveActivity, forKey: "showsLiveActivity") }
    }
    /// Include GPS location when copying metadata.
    var keepLocation: Bool {
        didSet {
            UserDefaults.standard.set(keepLocation, forKey: "keepLocation")
            if keepMetadata { reencodeResult() }
        }
    }
    var compute: ComputeChoice {
        didSet { settingChanged(compute.rawValue, "compute", reloadsModel: true) }
    }

    init() {
        let defaults = UserDefaults.standard
        model = SRModelKind(rawValue: defaults.string(forKey: "model") ?? "") ?? .x4plus
        outscale = defaults.object(forKey: "outscale") as? Double ?? 2
        denoise = defaults.object(forKey: "denoise") as? Double ?? 0.5
        outputFormat = OutputFormat(rawValue: defaults.string(forKey: "format") ?? "") ?? .png
        compute = ComputeChoice(rawValue: defaults.string(forKey: "compute") ?? "") ?? .all
        keepMetadata = defaults.object(forKey: "keepMetadata") as? Bool ?? true
        showsLiveActivity = defaults.object(forKey: "showsLiveActivity") as? Bool ?? true
        keepLocation = defaults.object(forKey: "keepLocation") as? Bool ?? true
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

    var effectiveOutscale: Double? {
        guard let source else { return nil }
        return Upscaler.effectiveOutscale(width: source.width, height: source.height, requested: outscale)
    }

    var targetSizeText: String? {
        if let resultSize { return "\(Int(resultSize.width)) × \(Int(resultSize.height))" }
        guard let source, let scale = effectiveOutscale, scale >= 1 else { return nil }
        return "\(Int((Double(source.width) * scale).rounded())) × \(Int((Double(source.height) * scale).rounded()))"
    }

    /// True when the requested scale had to be reduced to stay within the memory budget.
    var isScaleCapped: Bool {
        guard let scale = effectiveOutscale else { return false }
        return scale < outscale
    }

    // MARK: Loading

    func load(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ImageCodec.CodecError.unreadable
            }
            let decoded = try await Task.detached(priority: .userInitiated) { try ImageCodec.decode(data: data) }.value
            setSource(decoded.image, metadata: decoded.metadata, name: "photo")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func load(url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let decoded = try await Task.detached(priority: .userInitiated) { try ImageCodec.decode(url: url) }.value
            setSource(decoded.image, metadata: decoded.metadata, name: url.deletingPathExtension().lastPathComponent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setSource(_ image: CGImage, metadata: ImageMetadata, name: String) {
        cancel()
        source = image
        sourceMetadata = metadata.isEmpty ? nil : metadata
        sourceName = name
        sourcePreview = UIImage(cgImage: ImageCodec.downsample(image, maxPixel: 2048))
        clearResult()
        phase = .ready
        prepareModel()
    }

    func clear() {
        cancel()
        source = nil
        sourcePreview = nil
        sourceMetadata = nil
        clearResult()
        phase = .empty
    }

    // MARK: Model preparation

    /// Loads the selected model in the background so tapping 「开始」 starts immediately.
    func prepareModel() {
        prepareTask?.cancel()
        let kind = model, denoise = denoise, units = compute.units
        modelState = .preparing
        prepareTask = Task {
            // Debounce quick successive changes (e.g. dragging the denoise slider).
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let began = Date()
            do {
                let wasCached = try await Upscaler.shared.prepare(kind, denoise: denoise, units: units)
                guard !Task.isCancelled else { return }
                modelState = .ready(loadTime: wasCached ? nil : Date().timeIntervalSince(began))
            } catch {
                guard !Task.isCancelled else { return }
                modelState = .failed(error.localizedDescription)
            }
        }
    }

    private func settingChanged(_ value: Any, _ key: String, reloadsModel: Bool) {
        UserDefaults.standard.set(value, forKey: key)
        if phase == .done {
            clearResult()
            phase = .ready
        }
        if reloadsModel { prepareModel() }
    }

    // MARK: Processing

    func start() {
        guard let source, !isBusy else { return }
        clearResult()
        phase = .loadingModel
        tilesStartedAt = nil

        let options = UpscaleOptions(
            model: model, denoise: denoise, outscale: outscale, computeUnits: compute.units)
        let format = outputFormat
        let metadata = keepMetadata ? sourceMetadata : nil
        let includeLocation = keepLocation
        let baseName = "\(sourceName)_\(model.rawValue)_x\(outscale.formatted(.number.precision(.fractionLength(0...2))))"
        let began = Date()

        let session = ProcessingSession(
            modelTitle: model.title,
            sizeDescription: [sourceSizeText, targetSizeText].compactMap { $0 }.joined(separator: " → "),
            showsLiveActivity: showsLiveActivity,
            onExpire: { [self] in Task { @MainActor in self.cancel() } })
        self.session = session
        runsInBackground = session.runsInBackground
        backgroundDiagnostics = session.diagnostics

        task = Task {
            let application = UIApplication.shared
            application.isIdleTimerDisabled = true
            var succeeded = false
            let (updates, continuation) = AsyncStream.makeStream(
                of: UpscaleProgress.self, bufferingPolicy: .bufferingNewest(1))
            let progressTask = Task {
                for await update in updates { apply(update) }
            }
            defer {
                continuation.finish()
                progressTask.cancel()
                application.isIdleTimerDisabled = false
                session.finish(success: succeeded)
                if self.session === session { self.session = nil }
            }

            do {
                let output = try await Upscaler.shared.upscale(source, options: options) { update in
                    continuation.yield(update)
                }
                try Task.checkCancellation()
                modelState = .ready(loadTime: nil)
                phase = .encoding
                session.update(stage: .saving, completed: 1, total: 1, remaining: nil)

                let rendered = try await Task.detached(priority: .userInitiated) {
                    let preview = ImageCodec.downsample(output.image, maxPixel: 4096)
                    let file = try Self.writeFile(
                        output.image, format: format, metadata: metadata,
                        includeLocation: includeLocation, baseName: baseName)
                    return (preview: UIImage(cgImage: preview), file: file)
                }.value
                try Task.checkCancellation()

                resultImage = output.image
                resultBaseName = baseName
                resultPreview = rendered.preview
                setResultFile(rendered.file)
                resultSize = CGSize(width: output.image.width, height: output.image.height)
                elapsed = Date().timeIntervalSince(began)
                completedCount += 1
                phase = .done
                succeeded = true
            } catch {
                // `cancel()` has already reset the phase for cancelled runs.
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                phase = .ready
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Re-encodes the finished result after the format or metadata options change,
    /// without running the model again.
    private func reencodeResult() {
        guard phase == .done, let image = resultImage else { return }
        let format = outputFormat
        let metadata = keepMetadata ? sourceMetadata : nil
        let includeLocation = keepLocation
        let baseName = resultBaseName
        let previousURL = resultFileURL
        phase = .encoding
        task = Task {
            do {
                let file = try await Task.detached(priority: .userInitiated) {
                    try Self.writeFile(
                        image, format: format, metadata: metadata, includeLocation: includeLocation, baseName: baseName)
                }.value
                try Task.checkCancellation()
                if let previousURL, previousURL != file.url {
                    try? FileManager.default.removeItem(at: previousURL)
                }
                setResultFile(file)
                phase = .done
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                phase = .done
                errorMessage = error.localizedDescription
            }
        }
    }

    private func setResultFile(_ file: (data: Data, url: URL)) {
        resultData = file.data
        resultByteCount = file.data.count
        resultFileURL = file.url
    }

    nonisolated private static func writeFile(
        _ image: CGImage, format: OutputFormat, metadata: ImageMetadata?, includeLocation: Bool, baseName: String
    ) throws -> (data: Data, url: URL) {
        let properties = metadata?.forOutput(
            width: image.width, height: image.height, includeLocation: includeLocation)
        let encoded = try ImageCodec.encode(image, as: format, metadata: properties)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(baseName)
            .appendingPathExtension(encoded.format.fileExtension)
        try encoded.data.write(to: url, options: .atomic)
        return (encoded.data, url)
    }

    func cancel() {
        task?.cancel()
        task = nil
        remaining = nil
        if isBusy { phase = .ready }
    }

    private func apply(_ update: UpscaleProgress) {
        guard isBusy, phase != .encoding else { return }
        switch update {
        case .loadingModel:
            phase = .loadingModel
        case .tiles(let completed, let total):
            if completed == 0 {
                tilesStartedAt = Date()
                remaining = nil
            } else if let tilesStartedAt {
                let perTile = Date().timeIntervalSince(tilesStartedAt) / Double(completed)
                remaining = perTile * Double(total - completed)
            }
            phase = .processing(completed: completed, total: total)
            session?.update(stage: .upscaling, completed: completed, total: total, remaining: remaining)
            if let diagnostics = session?.diagnostics, diagnostics != backgroundDiagnostics {
                backgroundDiagnostics = diagnostics
            }
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(1, seconds.rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }

    private func clearResult() {
        if let resultFileURL { try? FileManager.default.removeItem(at: resultFileURL) }
        resultPreview = nil
        resultImage = nil
        resultData = nil
        resultByteCount = nil
        resultFileURL = nil
        resultSize = nil
        elapsed = nil
        remaining = nil
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
            showToast("已存储到“照片”")
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
