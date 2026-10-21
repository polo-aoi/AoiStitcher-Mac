# 图片压缩模块

来源：AoiFit 0.1.1 的 `Sources/ImagePipeline.swift` 与其 `reference/OutputSharpening.swift` 五档参数表。没有引入 AoiFit 独立应用的视觉组件。

## 分层

- `Core/ImagePipeline.swift`：Foundation / CoreGraphics / CoreImage / ImageIO / Metal；图片检查、尺寸计算、Lanczos 缩放、中间图渲染、CIUnsharpMask、sRGB、透明区域、方向、元数据与编码。没有 AppKit、SwiftUI 或用户偏好依赖。
- `Core/OutputSharpening.swift`：五档枚举与原参数，关闭、轻度、标准、中度、强力控制锐化，绝非 JPEG 质量档位。
- `Core/CompressionProcessor.swift`：串行后台队列、目录展开、逐文件结果、取消标志；不持有视图。每张图片在 autoreleasepool 内处理。
- `CompressionWorkspace.swift`：主线程可观察状态、偏好迁移、macOS 文件面板和 Finder 操作。
- `CompressionView.swift`：共用现有 EditorSidebarHeader / EditorSection / EditorToolbar / EditorActionBar；右侧使用原生多选 Table，无缩略图和预览。

## 保留的 AoiFit 行为

朋友圈短边 1920，小红书短边 2560，小图不放大，输出 JPG。平台先编码全质量 JPEG，再由 ImageIO AddImageFromSource 写出；第二阶段不手写质量。自定义保留 320–4320 px、长边/短边/宽度/高度/原尺寸、JPG/PNG/HEIC 与质量。保留五档锐化参数、sRGB 静态输出、PNG 透明、JPG/HEIC 白底、EXIF/TIFF/IPTC 保留与默认去 GPS、输入方向校正。处理测试随模块迁移并补充新增场景。

## 抖音预设

aoipic 3.1.1 新增抖音短边 2160 px，接入同一平台自动编码、五档输出锐化与元数据处理；用户不能手动选择质量。尺寸取自本机图适 4.7.1 的 `tiktok` 场景分支，详见 [抖音参数核对](抖音参数核对.md)。保持 AoiFit 的小图不放大行为，自定义设置在切换后恢复。

## 整合时的明确差异

文件后缀改为 `_aoipic`；已有文件自动编号。完整数据先写同目录临时文件，再用 Darwin `renamex_np(RENAME_EXCL)` 原子交付；成功、失败均清理临时文件，最后一刻出现的同名文件也不会覆盖。取消发生在当前不可中断的 Core Image 编码完成后、写出前；如果取消到达时本张已成功写出，则保留完整输出。原图从不以写入方式打开。

不可读输入作为失败行保留，显示具体路径；修复原文件后可以单独重试。重试会重新读取原文件尺寸，且使用当前选择的输出文件夹。自定义尺寸、格式、质量和放大选择在平台切换后恢复。

偏好保留在旧 `polo-aoi.AoiStitcher` 应用域。压缩键使用 `aoipic.compression.*`；首次缺少这些键时只读复制 AoiFit 设置，不改动 AoiFit 的偏好。之后的重启不会重新覆盖已恢复默认的输出位置。

## 范围与后续

这是 macOS 整合版，不宣称与图适逐像素、色彩或文件体积完全一致。无移动端实现。以后 iOS 可以复用 Core 算法和模型，但需单独验证平台原子写入、文件访问和 Metal/ImageIO 表现，并实现移动端界面。HDR gain map、实况照片、RAW 显影不在本次范围；多帧静态格式只处理第一帧。PNG 无损或高质量输出有时会比原文件更大。
