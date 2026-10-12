import SwiftUI

/// Full-screen before/after comparison, presented like the Photos viewer.
struct ResultViewer: View {
    let viewModel: UpscaleViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let before = viewModel.sourcePreview {
                    CompareView(before: before, after: viewModel.resultPreview)
                } else {
                    Color.clear
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("对比")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let url = viewModel.resultFileURL {
                        ShareLink(item: url) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Text("拖移分割线对比 · 双指缩放 · 轻点两下复原")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
