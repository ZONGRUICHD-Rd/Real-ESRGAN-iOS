# Real-ESRGAN for iOS

把 [Real-ESRGAN](https://github.com/Ikaros-521/Real-ESRGAN) 的**图片超分**移植到 iPhone（视频超分没有移植）。PyTorch 模型被转换成 Core ML，在设备端用神经网络引擎或 GPU 推理，不需要联网。

- 目标设备：iPhone 18 Pro / iOS 27（最低部署版本 iOS 26）
- 构建：GitHub Actions `macos-26` 运行器 + Xcode 26
- 界面：SwiftUI，按照 iOS 26 设计规范使用 Liquid Glass
- 产物：未签名 IPA，发布在 [Releases](../../releases)

## 功能

| Python 版 | iOS 版 |
| --- | --- |
| `-n` 模型选择 | RealESRGAN_x4plus、RealESRGAN_x4plus_anime_6B、realesr-general-x4v3、RealESRGAN_x2plus |
| `-dn` 降噪强度（DNI） | realesr-general-x4v3 提供 0 / 0.25 / 0.5 / 0.75 / 1 五档（转换时预先插值好权重） |
| `-s/--outscale` | 1× / 2×（默认）/ 3× / 4×，在拼接分块时直接按目标尺寸重采样 |
| `-t/--tile`、`--tile_pad` | 固定 256×256 分块，每边留 16 像素上下文 |
| EXIF 元数据 | 可选：把原图的相机、镜头、拍摄参数、拍摄时间写入结果，位置信息可单独关闭；尺寸、方向和色彩信息按新图更新 |
| Alpha 通道 | 保留，Alpha 单独用高质量插值放大（相当于 `--alpha_upsampler bicubic`） |
| `--face_enhance`（GFPGAN） | 未移植 |
| 视频超分 | 未移植 |

输出最大约 1.2 亿像素。超出时 App 会自动降低倍率，并在状态栏用橙色标出。

## 界面

参照 Apple 自带 App 的排版，用系统组件搭建，iOS 26 的 Liquid Glass 效果由系统自动套用：

- 主界面是分组列表 `Form`：最上面是图片卡片，下面依次是进度/结果、选项（模型、降噪、放大倍率、存储格式）、处理器和关于
- 主操作按钮（选择照片 / 开始超分 / 取消 / 存储到“照片”）通过 `safeAreaBar` 固定在底部，使用 `.glassProminent` 样式
- 超分完成后轻点图片，进入全屏对比：拖动分割线比较原图和结果，双指缩放
- 处理器可选：自动、CPU、GPU、神经网络引擎（NPU），列表底部会显示本机实际可用的计算设备
- 超分时，进度、剩余时间和百分比会以实时活动（Widget 扩展 `RealESRGANWidgets`）显示在灵动岛和锁定屏幕上。同时会申请 iOS 26 的 `BGContinuedProcessingTask`，让 App 切到后台后继续处理。如果系统批准了这个申请，会改用系统自带的进度实时活动（带取消按钮），以免同时出现两个。后台不允许使用 GPU，所以切到后台后，剩余分块会自动改由神经网络引擎处理
- 模型会在启动时和更改设置后提前在后台加载，界面上会显示加载状态和耗时，所以点「开始超分」后马上就能开始

## 目录

```
RealESRGAN/            SwiftUI App
  App/                 入口、视图模型
  Engine/              Core ML 分块推理（Upscaler）、图片编解码、模型列表
  Views/               主界面（Form）、全屏对比查看器
Shared/                   App 和 Widget 共用的实时活动数据定义
Widgets/                  灵动岛 / 锁定屏幕实时活动（Widget 扩展）
tools/convert_models.py   PyTorch → Core ML 转换（自带网络结构，不依赖 basicsr）
tools/build_models.sh     转换并编译成 .mlmodelc
project.yml               XcodeGen 工程描述
.github/workflows/build.yml  CI：转换模型 → Xcode 26 构建 → 打包未签名 IPA → 发布 Release
```

## 本地构建

```bash
pip install -r tools/requirements.txt --extra-index-url https://download.pytorch.org/whl/cpu
tools/build_models.sh            # 下载权重、转换模型，再编译成 build/Models/*.mlmodelc
brew install xcodegen && xcodegen generate
open RealESRGAN.xcodeproj
```

## 发布

推送 `v*` 标签，或者手动运行 **Build iOS IPA** 工作流并填写 `release_tag`，就会把 `RealESRGAN-unsigned.ipa` 发布到 Release。IPA 没有签名，安装前需要先自行签名（AltStore、SideStore、Sideloadly、TrollStore 或开发者证书都可以）。

## 许可

Real-ESRGAN 及其模型权重使用 BSD-3-Clause 许可，版权归原作者所有，见 [LICENSE](LICENSE)。
