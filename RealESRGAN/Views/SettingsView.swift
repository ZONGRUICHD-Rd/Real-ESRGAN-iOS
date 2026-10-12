import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: UpscaleViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("模型", selection: $viewModel.model) {
                        ForEach(SRModelKind.allCases) { model in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.title)
                                    Text(model.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: model.symbol)
                            }
                            .tag(model)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("模型")
                }

                if viewModel.model.supportsDenoise {
                    Section {
                        VStack(alignment: .leading) {
                            HStack {
                                Text("降噪强度")
                                Spacer()
                                Text(viewModel.denoise.formatted(.number.precision(.fractionLength(2))))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $viewModel.denoise, in: 0...1, step: 0.25) {
                                Text("降噪强度")
                            } minimumValueLabel: {
                                Image(systemName: "circle.dotted")
                            } maximumValueLabel: {
                                Image(systemName: "circle")
                            }
                        }
                    } footer: {
                        Text("0 保留更多噪点与细节，1 降噪最强（对应 Python 版的 -dn 参数）。")
                    }
                }

                Section {
                    Picker("输出倍率", selection: $viewModel.outscale) {
                        ForEach([1.0, 2.0, 3.0, 4.0], id: \.self) { scale in
                            Text("\(Int(scale))×").tag(scale)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("保存格式", selection: $viewModel.outputFormat) {
                        ForEach(OutputFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                } header: {
                    Text("输出")
                } footer: {
                    Text("模型以 \(viewModel.model.netScale)× 推理，其他倍率会在推理后重新采样（对应 --outscale）。带透明通道的图片会保留 Alpha。")
                }

                Section {
                    Picker("计算单元", selection: $viewModel.compute) {
                        ForEach(ComputeChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                } header: {
                    Text("性能")
                } footer: {
                    Text("图片以 256×256 分块处理。首次使用某个模型时系统需要为神经网络引擎编译，可能需要多等一会儿。")
                }

                Section("关于") {
                    LabeledContent("版本", value: Bundle.main.appVersion)
                    Link(destination: URL(string: "https://github.com/xinntao/Real-ESRGAN")!) {
                        Label("Real-ESRGAN（BSD-3-Clause）", systemImage: "link")
                    }
                    Link(destination: URL(string: "https://github.com/Ikaros-521/Real-ESRGAN")!) {
                        Label("Ikaros-521/Real-ESRGAN", systemImage: "link")
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }
}

private extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
