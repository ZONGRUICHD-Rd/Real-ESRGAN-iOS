import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RealESRGANWidgets: WidgetBundle {
    var body: some Widget {
        UpscaleLiveActivity()
    }
}

struct UpscaleLiveActivity: Widget {
    private static let tint = Color.indigo

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UpscaleActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .padding(16)
                .activitySystemActionForegroundColor(Self.tint)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("超分")
                    } icon: {
                        Image(systemName: state.symbol)
                    }
                    .font(.headline)
                    .foregroundStyle(Self.tint)
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(context.attributes.modelTitle) · \(context.attributes.sizeDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        ProgressView(value: state.fraction)
                            .tint(Self.tint)
                        HStack {
                            Text(state.stageText)
                            Spacer()
                            RemainingTime(state: state)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: state.symbol)
                    .foregroundStyle(Self.tint)
            } compactTrailing: {
                Text(state.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Self.tint)
            } minimal: {
                Gauge(value: state.fraction) {
                    Image(systemName: "wand.and.sparkles")
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(Self.tint)
            }
            .keylineTint(Self.tint)
        }
    }
}

private struct LockScreenView: View {
    let attributes: UpscaleActivityAttributes
    let state: UpscaleActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: state.symbol)
                .font(.title2)
                .foregroundStyle(.indigo)
                .frame(width: 44, height: 44)
                .background(.indigo.opacity(0.15), in: .circle)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(state.stage == .finished ? "超分完成" : "正在超分")
                        .font(.headline)
                    Spacer()
                    Text(state.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.headline)
                        .monospacedDigit()
                }
                Text("\(attributes.modelTitle) · \(attributes.sizeDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: state.fraction)
                    .tint(.indigo)
                HStack {
                    Text(state.stageText)
                    Spacer()
                    RemainingTime(state: state)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
    }
}

/// Counts down to the estimated finish without needing further updates from the app.
private struct RemainingTime: View {
    let state: UpscaleActivityAttributes.ContentState

    var body: some View {
        if state.stage == .upscaling, let end = state.estimatedEnd, end > .now {
            HStack(spacing: 2) {
                Text("剩余")
                Text(timerInterval: Date.now...end, countsDown: true)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 56, alignment: .trailing)
            }
        }
    }
}
