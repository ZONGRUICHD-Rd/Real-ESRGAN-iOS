import PhotosUI
import SwiftUI

/// Floating Liquid Glass controls at the bottom of the screen. All glass shapes live in one
/// `GlassEffectContainer` so the action button can morph into the progress capsule.
struct ControlBar: View {
    @Bindable var viewModel: UpscaleViewModel
    @Binding var pickerItem: PhotosPickerItem?
    @Namespace private var glassNamespace

    private static let scales: [Double] = [1, 2, 3, 4]

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            VStack(spacing: 12) {
                if viewModel.hasSource {
                    statusPill
                        .glassEffectID("status", in: glassNamespace)
                }
                HStack(spacing: 10) {
                    if viewModel.hasSource {
                        modelMenu
                        scaleMenu
                        actionControl
                    } else {
                        PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                            Label("选择图片", systemImage: "photo.badge.plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.extraLarge)
                        .glassEffectID("action", in: glassNamespace)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.smooth(duration: 0.35), value: viewModel.phase)
        .animation(.smooth(duration: 0.35), value: viewModel.hasSource)
    }

    // MARK: Status

    private var statusPill: some View {
        HStack(spacing: 8) {
            if let sourceSize = viewModel.sourceSizeText {
                Text(sourceSize)
            }
            if let target = viewModel.targetSizeText {
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                Text(target)
                    .foregroundStyle(viewModel.isScaleCapped ? Color.orange : Color.primary)
            }
            if let elapsed = viewModel.elapsedText {
                Text("·").foregroundStyle(.secondary)
                Label(elapsed, systemImage: "timer")
            }
        }
        .font(.footnote.weight(.medium))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }

    // MARK: Controls

    private var modelMenu: some View {
        Menu {
            Picker("模型", selection: $viewModel.model) {
                ForEach(SRModelKind.allCases) { model in
                    Label(model.title, systemImage: model.symbol).tag(model)
                }
            }
        } label: {
            Label(viewModel.model.shortTitle, systemImage: viewModel.model.symbol)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.extraLarge)
        .disabled(viewModel.isBusy)
    }

    private var scaleMenu: some View {
        Menu {
            Picker("输出倍率", selection: $viewModel.outscale) {
                ForEach(Self.scales, id: \.self) { scale in
                    Text("\(Int(scale))×").tag(scale)
                }
            }
        } label: {
            Text("\(viewModel.outscale.formatted(.number.precision(.fractionLength(0...1))))×")
                .monospacedDigit()
                .frame(minWidth: 32)
        }
        .buttonStyle(.glass)
        .controlSize(.extraLarge)
        .disabled(viewModel.isBusy)
    }

    @ViewBuilder
    private var actionControl: some View {
        if viewModel.isBusy {
            HStack(spacing: 10) {
                switch viewModel.phase {
                case .processing(let completed, let total):
                    ProgressView(value: viewModel.progress)
                        .frame(width: 56)
                    Text("\(completed)/\(total)")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                case .encoding:
                    ProgressView()
                    Text("保存中").font(.footnote.weight(.semibold))
                default:
                    ProgressView()
                    Text("加载模型").font(.footnote.weight(.semibold))
                }
                Button {
                    viewModel.cancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .frame(width: 28, height: 28)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("取消")
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(minHeight: 52)
            .glassEffect(.regular.interactive(), in: .capsule)
            .glassEffectID("action", in: glassNamespace)
        } else {
            Button {
                viewModel.start()
            } label: {
                Label(viewModel.hasResult ? "重新超分" : "超分", systemImage: "wand.and.sparkles")
                    .font(.headline)
                    .lineLimit(1)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .glassEffectID("action", in: glassNamespace)
        }
    }
}
