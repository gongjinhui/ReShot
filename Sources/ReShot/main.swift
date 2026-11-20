import AppKit
import Carbon
import UniformTypeIdentifiers

struct ReShotError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func runCLI() -> Int32? {
    let args = CommandLine.arguments
    guard args.count > 1 else { return nil }
    do {
        if args[1] == "--audio-test" { try RecordingAudio.selfTest(); return 0 }
        if args[1] == "--tracking-test" { try AnnotationTracker.selfTest(); return 0 }
        if args[1] == "--sequence-test" { try ImageSequence.selfTest(); return 0 }
        if args[1] == "--recording-test" { try RecordingMovie.selfTest(); return 0 }
        if args[1] == "--join", args.count >= 5 {
            let urls = args.dropFirst(3).map { URL(fileURLWithPath: $0) }
            try ImageFiles.png(CaptureAppearance.rounded(ImageSequence.compose(urls))).write(to: URL(fileURLWithPath: args[2]),options: .atomic)
            return 0
        }
        if args[1] == "--appearance-test" { try CaptureAppearance.selfTest(); return 0 }
        if args[1] == "--workflow-test" { try WorkflowRegression.run(); return 0 }
        if args[1] == "--autoscroll-test" { try AutoScroll.selfTest(); return 0 }
        if args[1] == "--capture-test" { try CaptureService.selfTest(); return 0 }
        if args[1] == "--annotation-test" { try FeatureTests.annotations(); return 0 }
        if args[1] == "--ocr-test" { try FeatureTests.ocr(); return 0 }
        if args[1] == "--storage-test" { try CaptureStorage.selfTest(); return 0 }
        if args[1] == "--selection-test" { try SelectionGeometry.selfTest(); return 0 }
        if args[1] == "--preview-test" { try PreviewRegression.run(); return 0 }
        if args[1] == "--stitch-test" { try ScrollStitcher.selfTest(); return 0 }
        if args[1] == "--stitch", args.count >= 5 {
            let frames = try args.dropFirst(3).map { try ImageFiles.read(URL(fileURLWithPath: $0)) }
            try ImageFiles.png(CaptureAppearance.rounded(ScrollStitcher.stitch(frames))).write(to: URL(fileURLWithPath: args[2]),options: .atomic)
            return 0
        }
        fputs("Usage: ReShot [--recording-test | --sequence-test | --workflow-test | --join OUTPUT IMAGE1 IMAGE2 ... | --stitch OUTPUT FRAME1 FRAME2 ...]\n",stderr)
        return 2
    } catch { fputs("\(error.localizedDescription)\n",stderr); return 1 }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    let imageScroll = ImagePreview()
    let statusLabel = NSTextField(labelWithString: "选择截图区域，或导入一张图片。")
    let markTool = NSPopUpButton()
    let markColor = NSColorWell()
    let markWidth = NSSlider(value: 4,minValue: 2,maxValue: 16,target: nil,action: nil)
    let ocrLanguage = NSPopUpButton()
    var ocrResult: OCRResult?
    let cancelOCRButton = NSButton(title: "取消识别",target: nil,action: nil)
    let ocrProgress = NSProgressIndicator()
    var ocrJob: OCR.Job?
    var ocrOnNext = false
    var image: CGImage?
    var busy = false
    var scrollCapture: ScrollCapture?
    var recorder: ScreenRecording?
    var lastRecording: URL?
    var quitAfterRecording = false
    var recordingPauseItem: NSMenuItem?
    var recordingStopItem: NSMenuItem?
    var recordingRevealItem: NSMenuItem?
    var regionPicker: RegionPicker?
    var hotKeys: [Int: EventHotKeyRef] = [:]
    var handler: EventHandlerRef?
    var pendingCapture = false
    private var preferences: PreferencesController?
    var settingsDefaults = UserDefaults.standard
    private var shortcutItems: [Int: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        buildWindow()
        registerHotKeys()
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder else { return .terminateNow }
        quitAfterRecording = true; recorder.stop(); return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        ocrJob?.cancel()
        hotKeys.values.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowWillClose(_ notification: Notification) { if pendingCapture { discardPendingCapture() }; NSApp.setActivationPolicy(.accessory) }
    func setupMenu() {
        let main = NSMenu(); let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let settings = appMenu.addItem(withTitle: "偏好设置…", action: #selector(showPreferences), keyEquivalent: ","); settings.target = self
        appMenu.addItem(withTitle: "退出 ReShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); main.addItem(editItem)
        let edit = NSMenu(); editItem.submenu = edit
        let paste = edit.addItem(withTitle: "粘贴", action: #selector(pasteImage), keyEquivalent: "v"); paste.target = self
        let copy = edit.addItem(withTitle: "复制", action: #selector(copyImage), keyEquivalent: "c"); copy.target = self
        NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "ReShot")
        let menu = NSMenu(); menu.delegate = self
        for (title, action) in [
            ("区域截图", #selector(regionCapture)), ("长截图", #selector(longCapture)),
            ("窗口截图", #selector(windowCapture)), ("全屏截图", #selector(fullCapture)),
            ("导入图片…", #selector(importImage)), ("导入图片拼图", #selector(importSequence)),
            ("显示图片面板", #selector(showWindow)), ("框选识字", #selector(regionOCR)),
            ("识别当前图片", #selector(recognizeImage))
        ] {
            addStatusItem(title, action: action, to: menu)
        }
        menu.addItem(.separator())
        addStatusItem("开始/停止录屏", action: #selector(toggleRecording), to: menu)
        recordingPauseItem = menu.addItem(withTitle: "暂停录屏",action: #selector(toggleRecordingPause),keyEquivalent: "")
        recordingStopItem = menu.addItem(withTitle: "结束并保存录屏",action: #selector(stopRecording),keyEquivalent: "")
        recordingRevealItem = menu.addItem(withTitle: "在访达中显示最近录屏",action: #selector(revealRecording),keyEquivalent: "")
        for item in [recordingPauseItem,recordingStopItem,recordingRevealItem] { item?.target = self; item?.isHidden = true }
        menu.addItem(.separator())
        let settingsItem = menu.addItem(withTitle: "偏好设置…", action: #selector(showPreferences), keyEquivalent: ","); settingsItem.target = self
        menu.addItem(withTitle: "退出 ReShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }
    private static let shortcuts: [(title: String, binding: CaptureShortcut, action: Selector)] = [
        ("区域截图", .init("a", kVK_ANSI_A, .option), #selector(regionCapture)),
        ("从剪贴板载入图片", .init("s", kVK_ANSI_S, .option), #selector(pasteClipboardImage)),
        ("框选识字", .init("o", kVK_ANSI_O, .option), #selector(regionOCR)),
        ("开始/停止录屏", .init("w", kVK_ANSI_W, .option), #selector(toggleRecording)),
        ("窗口截图", .init("w", kVK_ANSI_W, [.control,.option]), #selector(windowCapture)),
        ("长截图", .init("l", kVK_ANSI_L, [.control,.option]), #selector(longCapture)),
        ("全屏截图", .init("f", kVK_ANSI_F, [.control,.option]), #selector(fullCapture)),
        ("识别当前图片", .init("o", kVK_ANSI_O, [.control,.option]), #selector(recognizeImage))
    ]
    static var shortcutTitles: [String] { shortcuts.map(\.title) }

    private static func shortcutKey(_ index: Int) -> String {
        "shortcut." + NSStringFromSelector(shortcuts[index].action)
    }

    func shortcut(at index: Int) -> CaptureShortcut {
        if let data = settingsDefaults.data(forKey: Self.shortcutKey(index)),
           let binding = try? JSONDecoder().decode(CaptureShortcut.self, from: data) {
            return binding
        }
        return Self.shortcuts[index].binding
    }

    func changeShortcut(at index: Int, to binding: CaptureShortcut) throws {
        if binding == shortcut(at: index) { return }
        guard !Self.shortcuts.indices.contains(where: {
            let other = shortcut(at: $0)
            return $0 != index && other.code == binding.code && other.carbonFlags == binding.carbonFlags
        }) else { throw ReShotError(message: "此快捷键已被 ReShot 的另一项功能使用。") }
        let data = try JSONEncoder().encode(binding)
        guard let ref = registerShortcut(binding, index: index) else {
            throw ReShotError(message: "无法注册此快捷键，可能已被系统或其他应用使用。")
        }
        if let previous = hotKeys.updateValue(ref, forKey: index) { UnregisterEventHotKey(previous) }
        settingsDefaults.set(data, forKey: Self.shortcutKey(index))
        shortcutItems[index]?.keyEquivalent = binding.key
        shortcutItems[index]?.keyEquivalentModifierMask = binding.flags
    }

    @discardableResult
    private func addStatusItem(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        if let index = Self.shortcuts.firstIndex(where: { $0.action == action }) {
            let binding = shortcut(at: index)
            item.keyEquivalent = binding.key
            item.keyEquivalentModifierMask = binding.flags
            shortcutItems[index] = item
        }
        return item
    }

    func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        if action == #selector(confirmCapture) { b.keyEquivalent = "\r" }
        if action == #selector(cancelCapture) { b.keyEquivalent = "\u{1b}" }
        return b
    }
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1040,height: 760),styleMask: [.titled,.closable,.miniaturizable,.resizable],backing: .buffered,defer: false)
        window.title = "ReShot 2.1"; window.minSize = NSSize(width: 880,height: 520)
        window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        let root = NSView(); window.contentView = root
        markTool.addItems(withTitles: MarkTool.allCases.map(\.rawValue)); markTool.target = self; markTool.action = #selector(markSettings)
        NSColorPanel.shared.showsAlpha = true
        markColor.toolTip = "标注颜色与透明度"
        markColor.color = .systemRed; markColor.target = self; markColor.action = #selector(markSettings)
        markColor.widthAnchor.constraint(equalToConstant: 44).isActive = true
        markWidth.target = self; markWidth.action = #selector(markSettings); markWidth.widthAnchor.constraint(equalToConstant: 90).isActive = true
        ocrLanguage.addItems(withTitles: ["中英文","简体中文","繁體中文","English"])
        let annotationBar = NSStackView(views: [NSTextField(labelWithString: "标注工具"),markTool,markColor,NSTextField(labelWithString: "粗细"),markWidth,button("撤销",#selector(undoMark)),button("重做",#selector(redoMark)),button("确认保存 ↵",#selector(confirmCapture)),button("取消 Esc",#selector(cancelCapture))]); annotationBar.spacing = 8
        cancelOCRButton.target = self; cancelOCRButton.action = #selector(cancelOCR); cancelOCRButton.isEnabled = false
        ocrProgress.isIndeterminate = false; ocrProgress.minValue = 0; ocrProgress.maxValue = 100
        ocrProgress.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let ocrBar = NSStackView(views: [ocrLanguage,button("OCR 识字",#selector(recognizeImage)),button("框选识字",#selector(regionOCR)),ocrProgress,cancelOCRButton]); ocrBar.spacing = 10
        for bar in [annotationBar,ocrBar] { bar.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(bar) }
        statusLabel.textColor = .secondaryLabelColor; statusLabel.lineBreakMode = .byTruncatingTail
        for view in [imageScroll,statusLabel] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            annotationBar.topAnchor.constraint(equalTo: root.topAnchor,constant: 16),annotationBar.leadingAnchor.constraint(equalTo: root.leadingAnchor,constant: 20),annotationBar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor,constant: -16),
            ocrBar.topAnchor.constraint(equalTo: annotationBar.bottomAnchor,constant: 8),ocrBar.leadingAnchor.constraint(equalTo: annotationBar.leadingAnchor),
            imageScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor,constant: 20),imageScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor,constant: -20),imageScroll.topAnchor.constraint(equalTo: ocrBar.bottomAnchor,constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: imageScroll.leadingAnchor),statusLabel.trailingAnchor.constraint(equalTo: imageScroll.trailingAnchor),statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor,constant: -12),imageScroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor,constant: -10)
        ])
        root.layoutSubtreeIfNeeded()
    }
    func menuWillOpen(_ menu: NSMenu) {
        let phase = recorder?.visiblePhase
        recordingPauseItem?.title = phase == .paused ? "继续录屏" : "暂停录屏"
        recordingPauseItem?.isHidden = phase != .recording && phase != .paused
        recordingStopItem?.isHidden = phase != .recording && phase != .paused
        recordingRevealItem?.isHidden = lastRecording == nil
    }

    @objc func showPreferences() {
        if preferences == nil { preferences = PreferencesController(app: self) }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        preferences?.showWindow(nil)
        preferences?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showWindow() { NSApp.setActivationPolicy(.regular); NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); updatePreview(resetPosition: false); DispatchQueue.main.async { self.updatePreview(resetPosition: false) } }
    func notify(_ message: String) { statusLabel.stringValue = message; statusItem?.button?.toolTip = message }
    func fail(_ error: Error) { showWindow(); notify(error.localizedDescription); let alert = NSAlert(error: error); alert.beginSheetModal(for: window) }
    @objc func toggleRecording() {
        if let recorder { recorder.stop() } else { startRecording() }
    }
    private func startRecording() {
        guard !busy else { return }
        do { try CaptureService.requirePermission() } catch { fail(error); return }
        busy = true; preferences?.window?.orderOut(nil); window.orderOut(nil)
        let picker = RegionPicker(); regionPicker = picker
        picker.start(confirmTitle: "开始录屏 ↵") { [weak self] area in
            guard let self else { return }; self.regionPicker = nil
            guard let area else { self.busy = false; return }
            let session = ScreenRecording(); self.recorder = session
            self.statusItem.button?.image = NSImage(systemSymbolName: "record.circle",accessibilityDescription: "ReShot 录屏")
            session.completion = { [weak self] result in
                guard let self else { return }
                self.recorder = nil; self.busy = false
                self.statusItem.button?.image = NSImage(systemSymbolName: "viewfinder",accessibilityDescription: "ReShot")
                let quitting = self.quitAfterRecording; self.quitAfterRecording = false
                switch result {
                case .success(let outcome):
                    self.lastRecording = outcome.url
                    let message = outcome.interruption.map { "录屏中断（\($0.localizedDescription)），已保存可用片段：" } ?? "录屏已保存："
                    self.notify(message+outcome.url.path)
                    if quitting { NSApp.reply(toApplicationShouldTerminate: true) }
                    else if let error = outcome.interruption { self.fail(ReShotError(message: "录屏中断：\(error.localizedDescription)\n已保留：\(outcome.url.path)")) }
                case .failure(let error):
                    if quitting { NSApp.reply(toApplicationShouldTerminate: error is CancellationError) }
                    if !(error is CancellationError) { self.fail(error) }
                }
            }
            session.start(area: area,folder: CaptureFolders.url(CaptureFolders.videoKey))
        }
    }
    @objc func toggleRecordingPause() { recorder?.togglePause() }
    @objc func stopRecording() { recorder?.stop() }
    @objc func revealRecording() { if let lastRecording { NSWorkspace.shared.activateFileViewerSelecting([lastRecording]) } }
    @objc func longCapture() {
        guard !busy else { return }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            fail(ReShotError(message: "请在系统设置中允许 ReShot 屏幕录制权限，重新打开后使用长截图。")); return
        }
        busy = true; preferences?.window?.orderOut(nil); window.orderOut(nil)
        let session = ScrollCapture(); scrollCapture = session
        session.completion = { [weak self] result in
            guard let self else { return }; self.scrollCapture = nil
            switch result {
            case .success(let frames):
                self.busy = false
                if let image = frames.first { self.persistCapture(image, showPreview: false) }
            case .failure(let error): self.busy = false; if !(error is CancellationError) { self.fail(error) }
            }
        }
        session.start()
    }
    @objc func importSequence() {
        guard !busy else { return }; showWindow(); busy = true
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png,.jpeg,.tiff,.heic,.bmp,.gif,.webP]; panel.allowsMultipleSelection = true
        panel.message = "选择任意截图。默认按文件名排序，下一步可以调整顺序。"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { self.busy = false; return }
            let urls = panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            guard urls.count >= 2 else { self.busy = false; self.notify("请至少选择两张截图。"); return }
            DispatchQueue.main.async {
                guard let ordered = SequenceOrder(urls).run() else { self.busy = false; return }
                let radius = CaptureAppearance.radius()
                self.notify("正在按顺序拼接 \(ordered.count) 张图片…")
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try CaptureAppearance.rounded(ImageSequence.compose(ordered),points: radius) }
                    DispatchQueue.main.async {
                        self.busy = false
                        switch result { case .success(let image): self.completeCapture(image); case .failure(let error): self.fail(error) }
                    }
                }
            }
        }
    }
    @objc func regionCapture() {
        guard !busy else { return }
        do { try CaptureService.requirePermission() } catch { ocrOnNext = false; fail(error); return }
        busy = true; preferences?.window?.orderOut(nil); window.orderOut(nil)
        let picker = RegionPicker(); regionPicker = picker
        if ocrOnNext {
            picker.start { [weak self] rect in
                guard let self else { return }; self.regionPicker = nil
                guard let rect else { self.ocrOnNext = false; self.busy = false; return }
                self.runCapture { try CaptureService.region(rect) }
            }
            return
        }
        // Freeze display pixels before showing selection or annotation controls.
        let screens = NSScreen.screens.map { $0.frame }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now()+0.15) { [self] in
            let result = Result { try screens.map { try CaptureService.region($0) } }
            DispatchQueue.main.async {
                switch result {
                case .success(let frames):
                    guard screens == NSScreen.screens.map(\.frame) else { self.regionPicker = nil; self.busy = false; self.fail(ReShotError(message: "显示器配置已变化，请重新截图。")); return }
                    picker.startEditing(frames.map(\.image)) { [weak self] result in
                        guard let self else { return }; self.regionPicker = nil; self.busy = false
                        switch result {
                        case .success(let image): if let image { self.persistCapture(image, showPreview: false) }
                        case .failure(let error): self.fail(error)
                        }
                    }
                case .failure(let error): self.regionPicker = nil; self.busy = false; self.fail(error)
                }
            }
        }
    }

    @objc func fullCapture() {
        guard !busy else { return }
        do { try CaptureService.requirePermission() } catch { fail(error); return }
        let point = NSEvent.mouseLocation
        busy = true; preferences?.window?.orderOut(nil); window.orderOut(nil); NSApp.hide(nil)
        runCapture { try CaptureService.fullScreen(at: point) }
    }
    @objc func windowCapture() {
        guard !busy else { return }
        do { try CaptureService.requirePermission() } catch { fail(error); return }
        busy = true; preferences?.window?.orderOut(nil); window.orderOut(nil); NSApp.hide(nil)
        runCapture { try CaptureService.window() }
    }
    private func runCapture(_ operation: @escaping () throws -> ScreenshotFrame?) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline:.now()+0.2) {
            let result = Result { try operation() }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let frame):
                    if let frame { self.completeCapture(frame.image) }
                    else { self.ocrOnNext = false; self.notify("本次截图已取消。") }
                case .failure(let error): self.ocrOnNext = false; self.fail(error)
                }
            }
        }
    }
    func windowDidResize(_ notification: Notification) { updatePreview(resetPosition: false) }
    var fitsWholeImage: Bool {
        get { settingsDefaults.bool(forKey: "previewFitsWholeImage") }
        set {
            settingsDefaults.set(newValue, forKey: "previewFitsWholeImage")
            updatePreview(resetPosition: true)
        }
    }
    func updatePreview(resetPosition: Bool) {
        guard let image else { return }; window.contentView?.layoutSubtreeIfNeeded()
        imageScroll.display(image, fitWhole: fitsWholeImage, reset: resetPosition)
    }

    func setImage(_ newImage: CGImage) {
        image = newImage
        updatePreview(resetPosition: true)
        notify("图片 \(newImage.width) × \(newImage.height) · 图片已载入，可保存或复制。")
    }
    @objc func importImage() {
        guard !busy else { return }; showWindow()
        let p = NSOpenPanel(); p.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .bmp]; p.allowsMultipleSelection = false
        p.beginSheetModal(for: window) { response in
            guard response == .OK, let url = p.url else { return }
            do { self.presentImage(try ImageFiles.read(url)) } catch { self.fail(error) }
        }
    }
    @objc func pasteImage() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.paste(nil); return }
        pasteClipboardImage()
    }
    @objc func pasteClipboardImage() {
        guard !busy else { return }
        guard let image = ClipboardImages.read(.general) else { showWindow(); notify("剪贴板中没有图片，请先复制图片。"); return }
        presentImage(image)
    }
    func presentImage(_ image: CGImage) {
        setImage(image); showWindow(); updatePreview(resetPosition: true)
        window.contentView?.displayIfNeeded()
        DispatchQueue.main.async { self.updatePreview(resetPosition: true); self.window.contentView?.displayIfNeeded() }
    }
    func completeCapture(_ image: CGImage) {
        if ocrOnNext { ocrOnNext = false; presentImage(image); recognizeImage(); return }
        stageCapture(image)
        showWindow()
    }
    func stageCapture(_ image: CGImage) {
        pendingCapture = true; setImage(image)
        notify("请标注图片，确认后保存并复制；Esc 取消。")
    }
    @objc func confirmCapture() {
        guard !busy, image != nil else { return }
        do { let rendered = try imageScroll.renderedImage(); pendingCapture = false; persistCapture(rendered, showPreview: false) }
        catch { fail(error) }
    }
    func discardPendingCapture() {
        pendingCapture = false; image = nil; imageScroll.clear()
        notify("本次截图已取消。")
    }
    @objc func cancelCapture() {
        guard !busy else { return }
        if pendingCapture { discardPendingCapture() }
        window.orderOut(nil); NSApp.setActivationPolicy(.accessory)
    }
    func persistCapture(_ image: CGImage, showPreview: Bool) {
        if showPreview { presentImage(image) }
        do {
            let data = try ImageFiles.png(image)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data,forType: .png)
            do {
                let file = try saveCapturedImage(image, png: data)
                setImage(image)
                notify("已保存："+file.path+" · 图片已复制，可粘贴到其他应用")
                window.orderOut(nil); NSApp.setActivationPolicy(.accessory)
            } catch {
                presentImage(image)
                notify("图片已复制，自动保存失败："+error.localizedDescription+"。请在偏好设置中重选目录，然后点“确认保存”重试。")
                let alert = NSAlert(); alert.messageText = "自动保存失败，截图仍可复制和预览"
                alert.informativeText = error.localizedDescription; alert.addButton(withTitle:"选择保存目录…"); alert.addButton(withTitle:"稍后")
                alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { self.showPreferences() } }
            }
        } catch { fail(error) }
    }
    @objc func markSettings() {
        imageScroll.annotations.tool = MarkTool.allCases[max(0,markTool.indexOfSelectedItem)]
        imageScroll.annotations.color = markColor.color; imageScroll.annotations.width = CGFloat(markWidth.doubleValue)
    }
    @objc func undoMark() { imageScroll.annotations.undo(); imageScroll.refreshAnnotations() }
    @objc func redoMark() { imageScroll.annotations.redo(); imageScroll.refreshAnnotations() }
    private func saveCapturedImage(_ image: CGImage, png: Data? = nil) throws -> URL {
        let format = CaptureFormat.selected()
        let data = try (format == .png ? png : nil) ?? format.encode(image)
        return try CaptureStorage.save(data, folder: CaptureFolders.url(CaptureFolders.imageKey), format: format)
    }
    @objc func regionOCR() { guard !busy else { return }; ocrOnNext = true; regionCapture() }
    @objc func recognizeImage() {
        guard !busy else { return }
        do {
            let image = try imageScroll.renderedImage()
            let choices = [["zh-Hans","zh-Hant","en-US"],["zh-Hans","en-US"],["zh-Hant","en-US"],["en-US"]]
            let languages = choices[max(0,ocrLanguage.indexOfSelectedItem)]
            let job = OCR.Job(), token = UUID()
            ocrJob = job; ocrToken = token; busy = true; cancelOCRButton.isEnabled = true; ocrProgress.doubleValue = 0
            notify("正在本机识别文字…")
            DispatchQueue.main.asyncAfter(deadline:.now()+120) {
                guard self.ocrToken == token else { return }
                self.cancelOCR(); self.notify("识别超过两分钟，已取消，可缩小图片后重试。")
            }
            DispatchQueue.global(qos:.userInitiated).async {
                let result = Result { try OCR.analyze(image,languages:languages,job:job) { progress in
                    DispatchQueue.main.async { if self.ocrToken == token { self.ocrProgress.doubleValue = progress*100; self.notify("正在识别文字：\(Int(progress*100))%") } }
                } }
                DispatchQueue.main.async {
                    guard self.ocrToken == token else { return }
                    self.ocrToken = nil; self.ocrJob = nil; self.busy = false; self.cancelOCRButton.isEnabled = false
                    switch result {
                    case .success(let document):
                        if self.ocrResult == nil { self.ocrResult = OCRResult() }
                        self.ocrResult?.show(document.text); self.notify(document.text.isEmpty ? "未识别到文字。" : "识别完成，结果可编辑、复制或保存。")
                    case .failure(let error): if !(error is CancellationError) { self.fail(error) }
                    }
                }
            }
        } catch { fail(error) }
    }
    @objc func cancelOCR() {
        ocrJob?.cancel(); ocrJob = nil; ocrToken = nil; busy = false
        cancelOCRButton.isEnabled = false; notify("识别已取消。")
    }
    var ocrToken: UUID?
    @objc func copyImage() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.copy(nil); return }
        guard let image = try? imageScroll.renderedImage() else { notify("请先截图或导入图片。"); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))]); notify("图片已复制。")
    }
    func registerHotKeys() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard status == noErr, key.signature == 0x52534854,
                  Int(key.id) < AppDelegate.shortcuts.count else { return OSStatus(eventNotHandledErr) }
            let index = Int(key.id)
            let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                if app.preferences?.receiveRegisteredShortcut(app.shortcut(at: index)) == true { return }
                NSApp.sendAction(AppDelegate.shortcuts[index].action, to: app, from: nil)
            }
            return noErr
        }, 1, &eventType, context, &handler)
        for index in Self.shortcuts.indices {
            if let ref = registerShortcut(shortcut(at: index), index: index) {
                hotKeys[index] = ref
            } else {
                notify("全局快捷键被占用，可在偏好设置中更改。")
            }
        }
    }

    private func registerShortcut(_ binding: CaptureShortcut, index: Int) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x52534854, id: UInt32(index))
        let result = RegisterEventHotKey(binding.code, binding.carbonFlags, id, GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &ref)
        return result == noErr ? ref : nil
    }

}

if let status = runCLI() { exit(status) }
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
