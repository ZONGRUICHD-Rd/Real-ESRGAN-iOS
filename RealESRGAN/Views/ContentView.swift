import PhotosUI
import SwiftUI

/// Main screen, laid out like Apple's own utility apps: a grouped form with the image on top,
/// option rows below and a single primary action pinned to the bottom edge.
struct ContentView: View {
    @State private var viewModel = UpscaleViewModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var showsFileImporter = false
    @State private var showsViewer = false

    var body: some View {
        NavigationStack {
            Form {
                ImageSection(
                    viewModel: viewModel, pickerItem: $pickerItem,
                    openFiles: { showsFileImporter = true },
                    openViewer: { showsViewer = true })

                if viewModel.isBusy || viewModel.hasResult {
                    StatusSection(viewModel: viewModel)
                }

                if let diagnostics = viewModel.backgroundDiagnostics {
                    DiagnosticsSection(diagnostics: diagnostics)
                }

                OptionsSections(viewModel: viewModel)
            }
            .navigationTitle("超分辨率")
            .toolbar { toolbarContent }
            .safeAreaBar(edge: .bottom) {
                BottomBar(viewModel: viewModel, pickerItem: $pickerItem, openViewer: { showsViewer = true })
            }
            .overlay(alignment: .top) { toastView }
            .animation(.default, value: viewModel.phase)
            .animation(.spring(duration: 0.35), value: viewModel.toast)
        }
        .fullScreenCover(isPresented: $showsViewer) {
            ResultViewer(viewModel: viewModel)
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                Task { await viewModel.load(url: url) }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                await viewModel.load(item)
                pickerItem = nil
            }
        }
        .task {
            viewModel.prepareModel()
            #if DEBUG
            LiveActivityDemo.startIfRequested()
            #endif
        }
        .alert(
            "无法完成操作",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } })
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sensoryFeedback(.success, trigger: viewModel.completedCount)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // A PhotosPicker nested in a Menu often fails to present, so it is its own button.
        ToolbarItemGroup(placement: .topBarTrailing) {
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Label("从“照片”中选取", systemImage: "photo.badge.plus")
            }
            .disabled(viewModel.isBusy)
            Menu {
                Button("从“文件”中选取", systemImage: "folder") { showsFileImporter = true }
                if viewModel.hasSource {
                    Divider()
                    Button("移除图片", systemImage: "trash", role: .destructive) { viewModel.clear() }
                }
            } label: {
                Label("更多", systemImage: "ellipsis")
            }
            .disabled(viewModel.isBusy)
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = viewModel.toast {
            Label(toast, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.multicolor)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Image

private struct ImageSection: View {
    let viewModel: UpscaleViewModel
    @Binding var pickerItem: PhotosPickerItem?
    var openFiles: () -> Void
    var openViewer: () -> Void

    @State private var showsOriginal = false

    var body: some View {
        if let source = viewModel.sourcePreview {
            Section {
                Group {
                    if viewModel.hasResult {
                        Button(action: openViewer) { preview(source) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("全屏查看对比")
                    } else {
                        preview(source)
                    }
                }
                .listRowInsets(EdgeInsets())

                if !viewModel.isBusy {
                    PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                        Label("选择其他照片", systemImage: "photo.badge.plus")
                    }
                }

                if viewModel.hasResult {
                    Picker("显示", selection: $showsOriginal) {
                        Text("超分结果").tag(false)
                        Text("原图").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            } footer: {
                sizeFooter
            }
            .onChange(of: viewModel.hasResult) { _, _ in showsOriginal = false }
        } else {
            Section {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)
                        Text("选择照片")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("在本机用 Real-ESRGAN 放大图片，并修复模糊和噪点")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
                .buttonStyle(.plain)

                Button("从“文件”中选取", systemImage: "folder", action: openFiles)
            }
        }
    }

    private func preview(_ source: UIImage) -> some View {
        let image = (!showsOriginal ? viewModel.resultPreview : nil) ?? source
        return Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 360)
            .background(Color(.secondarySystemGroupedBackground))
            .overlay(alignment: .bottomLeading) { badge }
    }

    @ViewBuilder
    private var badge: some View {
        if viewModel.hasResult {
            Label(showsOriginal ? "原图" : "轻点以对比", systemImage: showsOriginal ? "photo" : "rectangle.split.2x1")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .padding(10)
        }
    }

    @ViewBuilder
    private var sizeFooter: some View {
        if let source = viewModel.sourceSizeText {
            VStack(alignment: .leading, spacing: 4) {
                if let target = viewModel.targetSizeText {
                    Text("\(source) 像素 → \(target) 像素")
                } else {
                    Text("\(source) 像素")
                }
                if viewModel.isScaleCapped, let scale = viewModel.effectiveOutscale, !viewModel.hasResult {
                    Text("输出过大，已按内存上限自动调整为 \(scale.formatted(.number.precision(.fractionLength(2))))×。")
                        .foregroundStyle(.orange)
                }
            }
            .monospacedDigit()
        }
    }
}

// MARK: - Status

private struct StatusSection: View {
    let viewModel: UpscaleViewModel

    var body: some View {
        Section {
            switch viewModel.phase {
            case .loadingModel:
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在准备模型…")
                        Text("首次在该处理器上使用这个模型时需要编译，之后会快很多。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            case .processing(let completed, let total):
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("正在超分")
                        Spacer()
                        Text(viewModel.progress, format: .percent.precision(.fractionLength(0)))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: viewModel.progress)
                    HStack {
                        Text("分块 \(completed)/\(total)")
                        Spacer()
                        if let remaining = viewModel.remaining {
                            Text("剩余约 \(Self.format(remaining))")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Label(
                        viewModel.runsInBackground
                            ? "可以切到后台，进度会显示在灵动岛和锁定屏幕上。"
                            : "进度会显示在灵动岛上；系统未允许长时间后台运行，切到后台约 30 秒后可能暂停。",
                        systemImage: viewModel.runsInBackground ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .padding(.vertical, 4)
            case .encoding:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在生成图片…")
                }
            default:
                if let size = viewModel.targetSizeText {
                    LabeledContent("输出尺寸", value: size)
                }
                if let elapsed = viewModel.elapsed {
                    LabeledContent("用时", value: Self.format(elapsed))
                }
                if let bytes = viewModel.resultByteCount {
                    LabeledContent("文件大小", value: Int64(bytes).formatted(.byteCount(style: .file)))
                }
            }
        } header: {
            Text(viewModel.isBusy ? "进度" : "结果")
        }
        .monospacedDigit()
    }

    static func format(_ seconds: TimeInterval) -> String {
        UpscaleViewModel.format(seconds)
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSection: View {
    let diagnostics: BackgroundDiagnostics

    var body: some View {
        Section {
            row("实时活动", diagnostics.liveActivity, ok: diagnostics.liveActivityOK)
            row("灵动岛扩展", diagnostics.extensionInstalled ? "已安装" : "缺失（签名工具可能移除了扩展）",
                ok: diagnostics.extensionInstalled)
            row("后台继续运行", diagnostics.backgroundTask, ok: diagnostics.backgroundOK)
        } header: {
            Text("灵动岛与后台")
        } footer: {
            Text("如果三项都正常但灵动岛仍是空白，通常是重新签名时没有正确签名 Widget 扩展。")
        }
    }

    private func row(_ title: String, _ value: String, ok: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(value)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Options

private struct OptionsSections: View {
    @Bindable var viewModel: UpscaleViewModel

    var body: some View {
        Section {
            NavigationLink {
                ModelList(selection: $viewModel.model)
            } label: {
                LabeledContent {
                    Text(viewModel.model.title)
                } label: {
                    Label("模型", systemImage: "cube")
                }
            }

            if viewModel.model.supportsDenoise {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent {
                        Text(viewModel.denoise.formatted(.number.precision(.fractionLength(2))))
                            .monospacedDigit()
                    } label: {
                        Label("降噪强度", systemImage: "camera.filters")
                    }
                    Slider(value: $viewModel.denoise, in: 0...1, step: 0.25)
                }
            }

            Picker(selection: $viewModel.outscale) {
                ForEach([1.0, 2.0, 3.0, 4.0], id: \.self) { scale in
                    Text("\(Int(scale))×").tag(scale)
                }
            } label: {
                Label("放大倍率", systemImage: "arrow.up.left.and.arrow.down.right")
            }

            Picker(selection: $viewModel.outputFormat) {
                ForEach(OutputFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            } label: {
                Label("存储格式", systemImage: "doc")
            }
        } header: {
            Text("选项")
        } footer: {
            Text("模型原生放大 \(viewModel.model.netScale)×，其他倍率会在推理后重新采样。透明通道会被保留。")
        }
        .disabled(viewModel.isBusy)

        Section {
            Toggle(isOn: $viewModel.keepMetadata) {
                Label("保留原图 EXIF", systemImage: "info.circle")
            }
            if viewModel.keepMetadata {
                Toggle(isOn: $viewModel.keepLocation) {
                    Label("包含位置信息", systemImage: "location")
                }
            }
            if let metadata = viewModel.sourceMetadata {
                if let camera = metadata.camera {
                    LabeledContent("相机", value: camera)
                }
                if let date = metadata.captureDate {
                    LabeledContent("拍摄时间", value: date)
                        .monospacedDigit()
                }
                LabeledContent("位置", value: metadata.hasLocation ? "有" : "无")
            }
        } header: {
            Text("元数据")
        } footer: {
            Text(metadataFooter)
        }
        .disabled(viewModel.isBusy)

        Section {
            Toggle(isOn: $viewModel.showsLiveActivity) {
                Label("在灵动岛显示进度", systemImage: "capsule.inset.filled")
            }
        } header: {
            Text("灵动岛")
        } footer: {
            Text("如果灵动岛里只有一块空白，说明重新签名时 Widget 扩展没有被正确签名，可以关闭此项。")
        }
        .disabled(viewModel.isBusy)

        Section {
            Picker("处理器", selection: $viewModel.compute) {
                ForEach(ComputeChoice.allCases) { choice in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.title)
                            Text(choice.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: choice.symbol)
                    }
                    .tag(choice)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            LabeledContent("模型状态") {
                modelStatus
            }
        } header: {
            Text("处理器")
        } footer: {
            Text("本机可用：\(ComputeChoice.availableDevicesDescription)。iPhone 的 NPU 就是神经网络引擎。")
        }
        .disabled(viewModel.isBusy)

        Section {
            Link(destination: URL(string: "https://github.com/xinntao/Real-ESRGAN")!) {
                Label("Real-ESRGAN", systemImage: "link")
            }
            Link(destination: URL(string: "https://github.com/Ikaros-521/Real-ESRGAN")!) {
                Label("Ikaros-521/Real-ESRGAN", systemImage: "link")
            }
        } header: {
            Text("关于")
        } footer: {
            Text("模型与算法来自 Real-ESRGAN（BSD-3-Clause），所有处理都在本机完成，不会上传图片。")
        }
    }

    private var metadataFooter: String {
        if viewModel.hasSource && viewModel.sourceMetadata == nil {
            return "这张图片没有 EXIF 信息。"
        }
        if !viewModel.keepMetadata {
            return "关闭后，超分结果不含任何拍摄信息。"
        }
        return "相机、镜头、拍摄参数和拍摄时间会写入超分结果，存入“照片”后会按原拍摄时间排列。"
            + (viewModel.keepLocation ? "分享前请留意，图片中含有拍摄地点。" : "")
    }

    @ViewBuilder
    private var modelStatus: some View {
        switch viewModel.modelState {
        case .idle:
            Text("未加载")
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在加载…")
            }
        case .ready(let loadTime):
            if let loadTime {
                Text("已就绪（\(loadTime.formatted(.number.precision(.fractionLength(1)))) 秒）")
            } else {
                Text("已就绪")
            }
        case .failed:
            Text("加载失败").foregroundStyle(.red)
        }
    }
}

private struct ModelList: View {
    @Binding var selection: SRModelKind
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(SRModelKind.allCases) { model in
                    Button {
                        selection = model
                        dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: model.symbol)
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.title)
                                    .foregroundStyle(.primary)
                                Text(model.subtitle)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model == selection {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("照片建议用“通用照片”，插画和动漫截图用“动漫插画”，大图或追求速度用“通用轻量”。")
            }
        }
        .navigationTitle("模型")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Bottom bar

private struct BottomBar: View {
    let viewModel: UpscaleViewModel
    @Binding var pickerItem: PhotosPickerItem?
    var openViewer: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if !viewModel.hasSource {
                    PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                        Text("选择照片").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                } else if viewModel.isBusy {
                    Button(role: .cancel) {
                        viewModel.cancel()
                    } label: {
                        Text("取消").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                } else if viewModel.hasResult {
                    if let url = viewModel.resultFileURL {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                                .frame(width: 24)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("分享")
                    }
                    Button {
                        Task { await viewModel.saveToPhotos() }
                    } label: {
                        Text("存储到“照片”").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                } else {
                    Button {
                        viewModel.start()
                    } label: {
                        Text("开始超分").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .font(.headline)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}
