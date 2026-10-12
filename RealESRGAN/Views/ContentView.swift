import PhotosUI
import SwiftUI

struct ContentView: View {
    @State private var viewModel = UpscaleViewModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var showsSettings = false
    @State private var showsFileImporter = false

    var body: some View {
        NavigationStack {
            canvas
                .navigationTitle("Real-ESRGAN")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .safeAreaInset(edge: .bottom) {
                    ControlBar(viewModel: viewModel, pickerItem: $pickerItem)
                }
                .overlay(alignment: .top) { toastView }
                .animation(.spring(duration: 0.35), value: viewModel.toast)
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView(viewModel: viewModel)
                .presentationDetents([.medium, .large])
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
        .alert(
            "出错了",
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

    // MARK: Canvas (content layer)

    @ViewBuilder
    private var canvas: some View {
        if let before = viewModel.sourcePreview {
            CompareView(before: before, after: viewModel.resultPreview)
                .background(Color.black)
        } else {
            EmptyStateView { showsFileImporter = true }
        }
    }

    // MARK: Toolbar (Liquid Glass functional layer)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Menu {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Label("从相册选择", systemImage: "photo.on.rectangle")
                }
                Button("从文件选择", systemImage: "folder") { showsFileImporter = true }
                if viewModel.hasSource {
                    Divider()
                    Button("移除图片", systemImage: "xmark.circle", role: .destructive) { viewModel.clear() }
                }
            } label: {
                Label("打开", systemImage: "plus")
            }
            .disabled(viewModel.isBusy)
        }

        if viewModel.hasResult {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let url = viewModel.resultFileURL {
                    ShareLink(item: url) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
                Button("保存到相册", systemImage: "square.and.arrow.down") {
                    Task { await viewModel.saveToPhotos() }
                }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button("设置", systemImage: "slider.horizontal.3") { showsSettings = true }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = viewModel.toast {
            Label(toast, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular.tint(.green.opacity(0.35)), in: .capsule)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

private struct EmptyStateView: View {
    var openFiles: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.indigo.opacity(0.55), Color.teal.opacity(0.45)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.white)
                    .frame(width: 112, height: 112)
                    .glassEffect(.clear, in: .circle)

                VStack(spacing: 8) {
                    Text("图片超分辨率")
                        .font(.largeTitle.bold())
                    Text("基于 Real-ESRGAN，在设备端用神经网络引擎\n将图片放大 2–4 倍并修复模糊与噪点。")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                Button("从文件选择", systemImage: "folder", action: openFiles)
                    .buttonStyle(.glass)
            }
            .padding(32)
        }
    }
}
