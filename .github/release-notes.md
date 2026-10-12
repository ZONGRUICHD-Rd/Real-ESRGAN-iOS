## Real-ESRGAN for iOS（未签名 IPA）

基于 [Ikaros-521/Real-ESRGAN](https://github.com/Ikaros-521/Real-ESRGAN) / [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) 移植的 iPhone 图片超分辨率应用，所有推理都在设备端通过 Core ML 完成。

- **系统要求**：iOS 26 或更新版本（面向 iPhone 18 Pro / iOS 27），由 GitHub Actions 中的 Xcode 26 构建
- **界面**：按照 Apple 自带 App 的分组列表排版，iOS 26 的 Liquid Glass 效果由系统自动套用；超分完成后可全屏对比原图和结果
- **处理器**：自动、CPU、GPU、神经网络引擎（NPU）四选一；模型会提前在后台加载，界面上能看到加载状态
- **灵动岛**：超分进度、剩余时间和取消按钮会以实时活动显示在灵动岛和锁定屏幕上（iOS 26 BGContinuedProcessingTask），切到后台后处理也会继续
- **模型**：RealESRGAN_x4plus、RealESRGAN_x4plus_anime_6B、realesr-general-x4v3（5 档降噪）、RealESRGAN_x2plus
- **功能**：分块推理、1–4× 输出倍率、保留透明通道、存储到“照片”或分享，可输出 PNG、JPEG 或 HEIC

### 安装
`RealESRGAN-unsigned.ipa` **没有签名**，需要用 AltStore、SideStore、Sideloadly、TrollStore 或你自己的开发者证书重新签名后再安装。校验值见 `.sha256` 文件。
