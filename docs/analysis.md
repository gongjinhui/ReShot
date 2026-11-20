# iShot 截图与 OCR 分析记录

分析日期：2026-11-06。目标：`/Applications/iShot.app`，版本 2.6.9，构建 20260831001。

## 目标身份与 REA 证据

主程序 SHA-256：`b837137e5e647ca1155d96ce40cd4a26edab53ec7f67ea523bdbe29ad55720a3`。

使用本机已缓存的 REA 6.7.0 公共命令行入口，执行 `doctor --client codex --json` 与 `inspect-macho /Applications/iShot.app --json`。

成功记录：`evidence/rea-macho.json`，Evidence ID：`ev_0f8a7579df77fabfd89a35333eff41e7fff8b89043645d19d8a549744bbfecaf`。确认通用 Mach-O 含 x86_64、arm64；本次关注 arm64，切片容器偏移 2572288，UUID `8DBE917B-028D-35B6-903D-8EEFD27E5014`。依赖含 AppKit、Vision、CoreGraphics、Carbon、ScreenCaptureKit（弱链接）以及 PTHotKey、ShortcutRecorder。

限制：REA 导入/导出汇总来自 dyld_info 与 nm，可能缺失隐藏或剥离符号；vtool 只保留出处，规范化构建信息来自 otool。依赖存在本身不能证明某个功能实际调用了该框架。

历史初次分析时，`evidence/rea-doctor.json` 显示尚未注册 REA MCP，也没有可用的 Hopper/Ghidra/IDA/Kuna 深度分析提供器。因此使用 REA CLI 完成结构分析，随后使用系统工具补充汇编及 Objective-C 元数据；未声称完成反编译或恢复原始源码。`rea-plist.json` 是失败诊断记录，不是成功 Evidence。该初次结构分析没有更改 REA 配置或安装引擎。后续已按授权配置 Ghidra 12.1.4、Temurin JDK 21 和 Mac ARM64 原生组件；当前环境结果见 `evidence/rea-ghidra-environment.json`。本次定向反编译补充见 `ishot-ghidra.md`。

## 补充静态观察（非 REA Evidence）

系统 `otool -ov`、`otool -arch arm64 -tvV` 与 `strings` 输出分别保存在 `ishot-objc.txt`、`ishot-arm64-assembly.txt`、`ishot-strings.txt`。`scripts/inspect_static.py` 直接解析 arm64 的标准 Objective-C selector stub 和 OCR CFString 常量，将虚拟地址映射回切片文件字节；输出 `static-selectors.json`。`focused-annotated-assembly.txt` 将已解析 selector 附在对应调用后，便于复核。

### 截图

`NSImage` 的 `Screenshot` 分类包含：

- `imageFullScreen`：`0x10003cfb4`，函数内 `0x10003cfe4` 调用 `CGWindowListCreateImage`。
- `imageMainFullScreen`：`0x10003d0ac`，函数内 `0x10003d0ec` 调用 `CGDisplayCreateImage`。
- `imageMainScreenForRect:`：`0x10003d134`，调用 `CGDisplayCreateImageForRect`。
- `captureScreenhotBelowWindow:onRect:`：`0x10003d4dc`。
- `captureWindowWithWindowID:`：`0x10003d58c`，函数内 `0x10003d5d0` 调用 `CGWindowListCreateImage`。

以上是函数入口与内部直接调用的静态观察。可以据此确认捕获屏幕/窗口图像的系统 API 路径，不能据此确认运行时每一种多屏、缩放或系统版本分支。ScreenCaptureKit 的弱依赖不意味着上述静态截图路径由它实现。

### OCR

`ocrFromImage:` 实现入口 `0x10003fc04`。观察到以下调用：

1. 首先存在 `analysisQRCode:` 路径，完整分支行为未经运行验证。
2. `0x10003fce4` 加载 `VNRecognizeTextRequest` 类，随后调用 `initWithCompletionHandler:`。
3. `0x10003fcfc` 调用 `setRecognitionLevel:`，参数寄存器 x2 为 0。本机 Apple SDK 的 `VNRecognizeTextRequest.h` 第 19 行将 0 定义为 `VNRequestTextRecognitionLevelAccurate`。
4. `0x10003fd88` 调用 `setRecognitionLanguages:`，前方构造 8 元素数组。CFString 内容依序为 `zh-Hans`、`zh-Hant`、`en-US`、`fr-FR`、`it-IT`、`de-DE`、`es-ES`、`pt-BR`。
5. `0x10003fd9c` 调用 `setUsesLanguageCorrection:`，参数为 0。
6. `VNImageRequestHandler` 经 `initWithCGImage:orientation:options:` 构建；`0x10003fe10` 调用 `performRequests:error:`。
7. 回调在 `0x10003ff90` 调用 `topCandidates:`，参数为 2，遍历候选并调用 `string`。不据此声称原版最终结果一定仅保留一个候选。

还存在 `ocrGetTextYFromImage:`（`0x1000400c4`），其回调使用 `VNImageRectForNormalizedRect` 计算文本几何信息。`startOCRAtScreenRect:`（`0x10000dc64`）中能看到区域捕获以及 OCR 窗口相关路径；`startOCRFromImage:`（`0x10000e834`）提供图片入口。发现 OCR 文本视图、复制、合并换行、连续模式等名称，但名称本身不代表完整行为已被验证。

## 历史初次复刻决策与差异（当前实现另见 README）

ReShot 独立使用 AppKit、Vision、Carbon。区域/窗口选择采用系统 `screencapture -i`；全屏采用其主屏参数。这是功能替代实现，不是重用原版捕获代码。Vision 使用 accurate 级别、每条结果首选候选；默认开启语言纠正，提供中英文、简体、繁体、英文选择。它与原版的语言集合、纠错设置和候选聚合存在明确差异，识别结果不保证逐字相同。

长截图的新增实现及证据见 `long-capture.md`。未还原原版标注、翻译、录屏、连续模式、品牌图形及购买相关功能。没有修改 iShot 本体或绕过其访问控制。

## 验证边界

构建、真实 Vision OCR 测试和 GUI 检查的结果详见 `validation.md`。系统屏幕录制授权和人工拖动选区尚需在获授权的桌面环境完成，不能把静态 API 证据或编译成功视为截图端到端验证。

## 实现 API 参考

Apple 官方：[Recognizing Text in Images](https://developer.apple.com/documentation/vision/recognizing-text-in-images)；[VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)。这些文档用于确认独立实现的 API 用法，不作为 iShot 运行行为证据。
