import AppKit
import Carbon

enum WorkflowRegression {
    static func run() throws {
        _ = NSApplication.shared
        let suite = "ReShot-workflow-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let delegate = AppDelegate()
        delegate.settingsDefaults = defaults
        delegate.setupMenu(); delegate.buildWindow()
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        defer { if let item = delegate.statusItem { NSStatusBar.system.removeStatusItem(item) }; delegate.window.orderOut(nil) }
        guard !delegate.window.isVisible, delegate.window.title == "ReShot 2.1" else { throw ReShotError(message: "启动窗口默认应隐藏且不含旧标签") }
        let expected = ["区域截图","长截图","全屏截图","窗口截图","导入图片…","导入图片拼图","识别当前图片","偏好设置…","开始/停止录屏"]
        let items = delegate.statusItem.menu!.items
        guard expected.allSatisfy({ title in items.contains { $0.title == title } }) else {
            throw ReShotError(message: "状态栏菜单缺少功能入口")
        }
        let shortcuts: [(String, String, NSEvent.ModifierFlags, Selector)] = [
            ("区域截图", "a", .option, #selector(AppDelegate.regionCapture)),
            ("框选识字", "o", .option, #selector(AppDelegate.regionOCR)),
            ("开始/停止录屏", "w", .option, #selector(AppDelegate.toggleRecording)),
            ("窗口截图", "w", [.control,.option], #selector(AppDelegate.windowCapture)),
            ("长截图", "l", [.control,.option], #selector(AppDelegate.longCapture)),
            ("全屏截图", "f", [.control,.option], #selector(AppDelegate.fullCapture)),
            ("识别当前图片", "o", [.control,.option], #selector(AppDelegate.recognizeImage))
        ]
        for (title, key, modifiers, action) in shortcuts {
            guard let item = items.first(where: { $0.title == title }),
                  item.keyEquivalent == key, item.keyEquivalentModifierMask == modifiers,
                  item.action == action else {
                throw ReShotError(message: "状态栏快捷键错误：\(title)")
            }
        }
        let removedMenuTitles = ["复制图片", "粘贴图片", "保存图片", "显示整图", "导入截图序列拼长图", "保存目录", "截图圆角"]
        guard !items.contains(where: { item in removedMenuTitles.contains(where: { item.title.hasPrefix($0) }) }),
              items.first(where: { $0.title == "导入图片拼图" })?.action == #selector(AppDelegate.importSequence) else {
            throw ReShotError(message: "状态栏菜单仍有旧入口或拼图动作错误")
        }
        let preferences = PreferencesController(app: delegate)
        guard preferences.window?.title == "ReShot 偏好设置" else { throw ReShotError(message: "偏好设置窗口未创建") }
        func fitButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "显示整图" { return button }
            return view.subviews.lazy.compactMap { fitButton(in: $0) }.first
        }
        guard let content = preferences.window?.contentView, let fitWhole = fitButton(in: content),
              fitWhole.state == .off else { throw ReShotError(message: "偏好设置缺少整图开关") }
        fitWhole.performClick(nil)
        guard delegate.fitsWholeImage else { throw ReShotError(message: "整图开关未生效") }
        let modified = CaptureShortcut("9", kVK_ANSI_9, [.control,.option,.shift,.command])
        try delegate.changeShortcut(at: 0, to: modified)
        let replacement = CaptureShortcut("8", kVK_ANSI_8, [.control,.option,.shift,.command])
        try delegate.changeShortcut(at: 0, to: replacement)
        let reopened = AppDelegate()
        reopened.settingsDefaults = defaults
        guard reopened.fitsWholeImage, reopened.shortcut(at: 0) == replacement,
              items.first(where: { $0.title == "区域截图" })?.keyEquivalent == "8",
              delegate.hotKeys.count == 1 else { throw ReShotError(message: "快捷键未更新或持久化") }
        do {
            try delegate.changeShortcut(at: 1, to: replacement)
            throw ReShotError(message: "允许了重复的快捷键")
        } catch let error as ReShotError where error.message == "此快捷键已被 ReShot 的另一项功能使用。" {}
        let original = URL(fileURLWithPath: "/tmp/reshot-original")
        let images = URL(fileURLWithPath: "/tmp/reshot-images")
        defaults.set(original.path, forKey: CaptureFolders.imageKey)
        guard CaptureFolders.url(CaptureFolders.videoKey, in: defaults).path == original.path else {
            throw ReShotError(message: "旧保存目录未沿用")
        }
        CaptureFolders.set(images, for: CaptureFolders.imageKey, in: defaults)
        guard CaptureFolders.url(CaptureFolders.imageKey, in: defaults).path == images.path,
              CaptureFolders.url(CaptureFolders.videoKey, in: defaults).path == original.path else {
            throw ReShotError(message: "图片与视频目录未独立")
        }
        func labels(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
        }
        guard !labels(delegate.window.contentView!).contains("截图与长截图") else { throw ReShotError(message: "旧正文标签未移除") }
        let removedButtons = ["区域截图 ⌃⌥S","长截图 ⌃⌥L","全屏截图","窗口截图","复制图片","保存 PNG…","导入图片","粘贴图片","保存目录…","截图圆角…","录屏…"]
        func buttons(_ view: NSView) -> [String] { (view as? NSButton).map { [$0.title] } ?? view.subviews.flatMap(buttons) }
        guard !buttons(delegate.window.contentView!).contains(where: { removedButtons.contains($0) }) else { throw ReShotError(message: "绿框入口仍留在图片面板") }
        let board = NSPasteboard.general, before = board.changeCount
        let context = CGContext(data: nil,width: 200,height: 100,bitsPerComponent: 8,bytesPerRow: 800,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1,alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: 200,height: 100))
        delegate.stageCapture(context.makeImage()!)
        guard delegate.pendingCapture, board.changeCount == before else { throw ReShotError(message: "确认前不应更改剪贴板") }
        delegate.cancelCapture()
        guard !delegate.pendingCapture, delegate.image == nil, delegate.imageScroll.displayedImage == nil, !delegate.window.isVisible, board.changeCount == before else { throw ReShotError(message: "取消未丢弃暂存截图，或改变剪贴板") }
        try RegionPicker.editingSelfTest()
        try RecordingAnnotations.interactionSelfTest()
        print("PASS: hidden startup, removed labels/buttons, clean status menu, preview preference, shortcut replacement and conflict rejection, independent folders, pending/cancel clipboard invariants")
    }
}
