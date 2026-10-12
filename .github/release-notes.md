## Real-ESRGAN for iOS（未签名 IPA）

基于 [Ikaros-521/Real-ESRGAN](https://github.com/Ikaros-521/Real-ESRGAN) / [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) 移植的 iPhone 图片超分辨率应用，所有推理都在设备端通过 Core ML（神经网络引擎）完成。

- **系统要求**：iOS 26 或更新版本（面向 iPhone 18 Pro / iOS 27 调校），由 GitHub Actions 中的 Xcode 26 构建
- **界面**：遵循 iOS 26 设计规范，使用 Liquid Glass（液态玻璃）
- **模型**：RealESRGAN_x4plus、RealESRGAN_x4plus_anime_6B、realesr-general-x4v3（5 档降噪）、RealESRGAN_x2plus
- **功能**：分块推理、1–4× 输出倍率、透明通道保留、前后对比滑块、保存到相册 / 分享，可输出 PNG、JPEG 或 HEIC

### 安装
`RealESRGAN-unsigned.ipa` **没有签名**，需要用 AltStore、SideStore、Sideloadly、TrollStore 或你自己的开发者证书重新签名后再安装。校验值见 `.sha256` 文件。
