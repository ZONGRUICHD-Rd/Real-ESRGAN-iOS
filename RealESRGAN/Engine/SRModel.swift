import CoreML
import Metal
import UniformTypeIdentifiers

/// Real-ESRGAN networks bundled with the app (converted by `tools/convert_models.py`).
enum SRModelKind: String, CaseIterable, Identifiable, Codable {
    case x4plus = "RealESRGAN_x4plus"
    case anime6B = "RealESRGAN_x4plus_anime_6B"
    case generalV3 = "realesr-general-x4v3"
    case x2plus = "RealESRGAN_x2plus"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .x4plus: "通用照片 x4"
        case .anime6B: "动漫插画 x4"
        case .generalV3: "通用轻量 x4"
        case .x2plus: "通用照片 x2"
        }
    }

    var shortTitle: String {
        switch self {
        case .x4plus: "照片"
        case .anime6B: "动漫"
        case .generalV3: "轻量"
        case .x2plus: "照片 x2"
        }
    }

    var subtitle: String {
        switch self {
        case .x4plus: "RealESRGAN_x4plus · 效果最好，速度较慢"
        case .anime6B: "RealESRGAN_x4plus_anime_6B · 针对二次元图像优化"
        case .generalV3: "realesr-general-x4v3 · 速度最快，可调降噪"
        case .x2plus: "RealESRGAN_x2plus · 2 倍放大"
        }
    }

    var symbol: String {
        switch self {
        case .x4plus: "camera.macro"
        case .anime6B: "paintbrush.pointed"
        case .generalV3: "hare"
        case .x2plus: "square.resize.up"
        }
    }

    /// Native upscale factor of the network.
    var netScale: Int { self == .x2plus ? 2 : 4 }

    /// Only realesr-general-x4v3 supports DNI denoise strength (`-dn` in the Python CLI).
    var supportsDenoise: Bool { self == .generalV3 }

    static let denoiseLevels: [Double] = [0, 0.25, 0.5, 0.75, 1]

    /// Name of the compiled model inside `Models/` in the app bundle.
    func resourceName(denoise: Double) -> String {
        guard supportsDenoise else { return rawValue }
        let level = Self.denoiseLevels.min { abs($0 - denoise) < abs($1 - denoise) } ?? 0.5
        return String(format: "%@_dn%03d", rawValue, Int((level * 100).rounded()))
    }
}

enum OutputFormat: String, CaseIterable, Identifiable {
    case png, jpeg, heic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: "PNG（无损）"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        }
    }

    var utType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }

    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

enum ComputeChoice: String, CaseIterable, Identifiable {
    case all, neuralEngine, gpu, cpu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "自动"
        case .neuralEngine: "神经网络引擎（NPU）"
        case .gpu: "GPU"
        case .cpu: "CPU"
        }
    }

    var detail: String {
        switch self {
        case .all: "由 Core ML 在 CPU、GPU 和 NPU 之间自动分配"
        case .neuralEngine: "速度快、功耗低；首次使用需要编译模型"
        case .gpu: "加载最快，适合偶尔处理几张图片"
        case .cpu: "最慢，但兼容性最好"
        }
    }

    var symbol: String {
        switch self {
        case .all: "wand.and.sparkles"
        case .neuralEngine: "brain"
        case .gpu: "square.stack.3d.up"
        case .cpu: "cpu"
        }
    }

    var units: MLComputeUnits {
        switch self {
        case .all: .all
        case .neuralEngine: .cpuAndNeuralEngine
        case .gpu: .cpuAndGPU
        case .cpu: .cpuOnly
        }
    }

    /// Human-readable list of the compute devices Core ML can use on this device.
    static var availableDevicesDescription: String {
        MLComputeDevice.allComputeDevices.map { device -> String in
            switch device {
            case .cpu: return "CPU"
            case .gpu(let gpu): return "GPU（\(gpu.metalDevice.name)）"
            case .neuralEngine(let engine): return "神经网络引擎（\(engine.totalCoreCount) 核）"
            @unknown default: return device.description
            }
        }
        .joined(separator: "、")
    }
}
