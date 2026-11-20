# 长截图与长图 OCR

当前实现为独立重写。没有复制 iShot 可执行代码或资源。

## 从 iShot 得到的静态证据

沿用 `docs/analysis.md` 的 REA Mach-O 证据和同一主程序摘要；再次校验 SHA-256 未改变。当时深度反编译引擎尚不可用；该记录仅为历史静态分析。后续 Ghidra 定向分析见 `ishot-ghidra.md`。

补充系统汇编和 Objective-C selector 解析保存在 `evidence/scroll-annotated-assembly.txt`。确认的静态入口：

- `scrollWheel:`：arm64 `0x1000347d4`。
- `scrollFinished`：`0x1000349f0`，跳转到 `screenShotsAtScrollScreenshots`。
- `screenShotsAtScrollScreenshots`：`0x1000349f4`。
- `drawScrollView`：`0x100035f08`。
- `startAutoScroll:`：`0x10002491c`。

在滚轮路径中，`0x100034954` 调用采集方法；`0x100034998` 设置以 `scrollFinished` 为 selector 的定时器。采集函数读取图像数据提供者、宽高，并调用 `sameArrColumn:to:`、`sameArr:to:`、`getSameColorValueInArrColumn:from:withUp:` 和 `cutImageToRect:Rect:`。这些直接调用支持“按滚动事件采集、比较图像行列并裁切”的解释，具体阈值、全部边界分支及运行效果未被恢复或逐项验证。

## 历史实现流程（当前实现另见 README）

1. 用户框选单个屏幕内的滚动内容区域，避开固定头尾、侧栏和动画。
2. 控制条放在选区外；若没有安全位置则要求缩小选区。
3. 用户在原应用向下滚动。每 1.2 秒进行两次间隔约 0.2 秒的区域采集；仅接收已停稳且相对上一帧有变化的画面。
4. 完成后比较相邻帧的纵向偏移，去除重叠，生成原宽度长图。重复帧跳过，不确定的匹配报告错误。
5. 自动对拼好的长图识别；可编辑、复制识别文字，或复制/保存 PNG。

另提供“导入截图序列拼长图”，按文件名自然排序。它经过相同的重叠匹配，不是简单上下堆叠。CLI 可用 `--stitch OUTPUT FRAME1 FRAME2 ...`。

## OCR

保持本机 Apple Vision，中英文、简体、繁体、英文选择。原宽度图像切成最多 2000px 高的块，相邻块重叠 240px。依据识别框的几何中心划分重叠区域；不会按字符串全局去重，因此文档不同位置的相同文字可以保留。请求最小文字高度设为 0.005，整体等待最多 120 秒。

Apple 官方参考：[VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest) 与 [minimumTextHeight](https://developer.apple.com/documentation/vision/vnrecognizetextrequest/minimumtextheight)。官方文档用于实现 API 依据，不能代替 iShot 行为证据。

## 边界

当前是手动滚动、自动采集与拼接，不自动向其它应用发送滚轮输入。不支持逆向滚动或横向拼接。选区与缩放必须保持不变；大块空白、完全重复的纹理、动态内容可能无法可靠匹配。固定头尾没有自动移除，用户需要在框选时避开。采集上限 30 帧 / 6000 万输入像素；输出限制 60000 像素高 / 192MB 原始像素。

真实屏幕采集验收需要用户授予屏幕录制权限；图像算法和长图 OCR 的自动测试不等于已通过跨应用桌面滚动验收。
