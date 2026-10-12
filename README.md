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
| `-s/--outscale` | 1× / 2× / 3× / 4×，在拼接分块时直接按目标尺寸重采样 |
| `-t/--tile`、`--tile_pad` | 固定 256×256 分块，每边留 16 像素上下文 |
| Alpha 通道 | 保留，Alpha 单独用高质量插值放大（相当于 `--alpha_upsampler bicubic`） |
| `--face_enhance`（GFPGAN） | 未移植 |
| 视频超分 | 未移植 |

输出最大约 1.2 亿像素。超出时 App 会自动降低倍率，并在状态栏用橙色标出。

## 界面（Liquid Glass）

按照 HIG 的建议，Liquid Glass 只用在浮在内容上方的功能层，图片本身作为内容层：

- 系统导航栏和工具栏会自动套用 Liquid Glass；工具栏按钮分组，中间用 `ToolbarSpacer` 隔开
- 底部的模型、倍率和「超分」按钮放在同一个 `GlassEffectContainer` 里。处理开始后，「超分」按钮（`.glassProminent`）会借助 `glassEffectID` 变形为进度胶囊
- 对比滑块的把手和标签悬浮在照片上，所以使用 `.clear` 变体，并按 HIG 加了暗色衬底
- 设置页是系统 sheet，自带玻璃材质

## 目录

```
RealESRGAN/            SwiftUI App
  App/                 入口、视图模型
  Engine/              Core ML 分块推理（Upscaler）、图片编解码、模型列表
  Views/               主界面、对比视图、底部控制条、设置
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
