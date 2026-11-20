# iShot 三项功能定向反编译

2026-11-06。本记录为静态分析，不表示曾执行或完整测试 iShot 的这些分支。

## 身份和方法

安装包 `/Applications/iShot.app` 为 2.6.9，构建 20260831001。主程序 SHA-256 为 `b837137e5e647ca1155d96ce40cd4a26edab53ec7f67ea523bdbe29ad55720a3`，与历史 `rea-macho.json` 相符。

REA 6.7.0 的 Ghidra 提供器不能直接选择 universal Mach-O 的架构，因此通过系统 lipo 提取 ARM64 分析副本 `evidence/ishot-analysis-arm64`，未修改原 App。该副本 SHA-256 为 `0fd04bf6c49aa4f5e3bbc392bd88c0d319faa663fbc27edd7a2b97d51a88126b`。

使用已安装公共 CLI `rea decompile <arm64副本> <入口地址> --provider ghidra --format json`；后端为 Ghidra 12.1.4、Temurin JDK 21.0.13、本机构建的 mac_arm_64 反编译器。每个 CLI 调用拥有自己的临时项目，结束后自动关闭和清理。未修改支付相关代码或资源，未绕过访问控制。

## 截图

入口 `0x10003d134` 对应历史元数据中的 `imageMainScreenForRect:`。

证据 `evidence/rea-ishot-region.json`，ID `ev_7215a2abbe8659207f1beacf1ba303a43ac00806bb841b9e96f05d830c08d2b5`；可读伪代码在 `evidence/ishot-region-pseudocode.txt`。

观察到 `NSScreen::mainScreen`、`frame`、`CGMainDisplayID`、`CGDisplayCreateImageForRect`、`NSImage::initWithCGImage_size_` 和图像释放。支持“主显示器区域捕获并包装为 NSImage”的结论。Ghidra 对包含 CGRect 的浮点调用参数恢复不完整，不能将伪代码参数表达式直接作为正确坐标转换公式使用；也不能据该单一入口推断多屏全部实现。

## 长截图

入口 `0x1000349f4` 恢复为 `MXClipView::screenShotsAtScrollScreenshots`。

证据 `evidence/rea-ishot-scroll.json`，ID `ev_36eb5b280f7d34fbcd0ff6b1565674167f0ac837c456914981c66bc2b436b105`；伪代码在 `evidence/ishot-scroll-pseudocode.txt`。

观察到读取当前鼠标显示器与缩放比例，经 `CGWindowListCreateImage` 获取图像；对空图像、数据提供者失败有返回分支。获取像素宽高和行跨度，构造逐行原始数据及逐列灰度数据；存在数组相等时提前返回的分支。调用 `Global::sameArrColumn_to_` 从左右两侧比较列，调用 `getSameColorValueInArrColumn_from_withUp_`、`sameArr_to_` 搜索匹配行，并包含忽略纯白／重复行候选的分支。

成功匹配后经 `NSImage::cutImageToRect_Rect_` 裁剪、追加或更新图像视图及高度数组，再调用 `drawScrollView` 更新预览。支持“内容匹配后增量拼接、重复帧跳过”的静态解释。

未单独恢复全部辅助比较函数，不能声称已准确恢复误差阈值、全局状态含义、所有回滚条件和固定区域策略。变量 DAT_*、extraout_* 是反编译器生成的名字，不是原始源码。ReShot 使用独立匹配算法，不照搬这些未恢复的全局状态。

## 自动滚动启动

入口 `0x10002491c` 恢复为 `MXClipView::startAutoScroll_`。证据 `evidence/rea-ishot-auto-scroll.json`，ID `ev_6ca224ce789fd8486cca621f6c267e42dd395c661d6c11e2c3097e61cb59cac9`；伪代码在 `evidence/ishot-auto-scroll-pseudocode.txt`。

观察到先以 prompt=false 检查 `AXIsProcessTrustedWithOptions`。未信任时发送取消截图通知并调用辅助功能权限提示方法；信任时更新全局状态、把按钮标题设为本地化 StopScroll，并令选区窗口忽略鼠标事件。本入口没有实际滚动事件发送代码，因此滚动步长、节奏及末尾检测仍未知；不能据该入口声称恢复了自动滚动算法。

## OCR

入口 `0x10003fc04` 对应 `ocrFromImage:`。

证据 `evidence/rea-ishot-ocr.json`，ID `ev_f26a7435c584cd7070abd89ba3df11857428209df8405c750e9ab7d56f5d2170`；伪代码在 `evidence/ishot-ocr-pseudocode.txt`。

存在平台检查及二维码结果为空后进入文本识别的分支。构造 `VNRecognizeTextRequest`，识别级别设置为 0（accurate），最低文本高度参数为 `0x3a83126f`（按 float 解释为约 0.001）。识别语言依次为简体中文、繁体中文、英文、法文、意大利文、德文、西班牙文、葡萄牙文；关闭语言纠错。构造 `VNImageRequestHandler` 并同步 `performRequests_error_`，完成回调为 `FUN_10003feb0`。

本次未反编译回调和全部 OCR 窗口流程，不声称恢复了阅读排序、断行合并或长图分块策略。ReShot 按用户已确认的中英文纯文本范围独立实现，默认语言纠错设置与原版可能不同，逐字结果不保证一致。

## 行为验证与独立实现边界

本次没有启动受调试的 iShot，也没有实际观看新的官方视频；历史视频画面参考见现有功能说明。动态行为、付费受限入口和跨应用效果均不从静态伪代码推定。ReShot 的构建、合成样本测试及真实桌面验证应单独记录在交付验证文档，不与 iShot 静态证据混用。
