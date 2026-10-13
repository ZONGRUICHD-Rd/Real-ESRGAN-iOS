import ActivityKit
import Foundation

/// Live Activity shown in the Dynamic Island and on the Lock Screen while an image is upscaled.
/// Compiled into both the app and the widget extension.
struct UpscaleActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Stage: String, Codable, Hashable {
            case preparing, upscaling, saving, finished, failed
        }

        var stage: Stage
        var completed: Int
        var total: Int
        /// Estimated finish time, so the countdown keeps ticking without app updates.
        var estimatedEnd: Date?

        var fraction: Double {
            switch stage {
            case .saving, .finished: 1
            default: total > 0 ? min(1, Double(completed) / Double(total)) : 0
            }
        }

        var stageText: String {
            switch stage {
            case .preparing: "正在准备模型"
            case .upscaling: "分块 \(completed)/\(total)"
            case .saving: "正在生成图片"
            case .finished: "已完成"
            case .failed: "已停止"
            }
        }

        var symbol: String {
            switch stage {
            case .finished: "checkmark.circle.fill"
            case .failed: "xmark.circle.fill"
            default: "wand.and.sparkles"
            }
        }
    }

    var modelTitle: String
    var sizeDescription: String
}
