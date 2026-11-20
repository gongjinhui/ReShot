import AppKit
import ApplicationServices

/// UI state is main-thread owned; pixels, stream and stitching are worker-owned.
final class ScrollCapture: NSObject {
    enum State { case selecting, manual, automatic, paused, needsAlignment, finishing, cancelled, completed }
    var completion: ((Result<[CGImage], Error>) -> Void)?
    private(set) var state: State = .selecting
    private let worker = DispatchQueue(label: "local.reshot.scroll",qos: .userInitiated)
    private let session = ScrollStitcher.Session()
    private var picker: RegionPicker?
    private var rect = CGRect.zero
    private var captureScale: CGFloat = 1
    private let cornerRadiusPoints = CaptureAppearance.radius()
    private var rangeWindows: [NSWindow] = []
    private var panel: NSPanel?
    private let label = NSTextField(wrappingLabelWithString: "准备采集…")
    private let thumbnail = NSImageView()
    private let mode = NSPopUpButton()
    private let pauseButton = NSButton(title: "暂停",target: nil,action: nil)
    private var monitor: Any?, keyMonitor: Any?
    private var timer: Timer?
    private var lastScroll = Date.distantPast
    private var inFlight = false, waitingForPointer = true, canFinish = true, atLimit = false
    private var automatic = false
    private var motionCaptured = false
    private var lastFrameTime = Date.distantPast
    private var duplicateAttempts = 0, step: Int32 = 100
    private var targetPID: pid_t?
    private var targetWindowID: CGWindowID?
    // Accessed only on worker:
    private var modern: AnyObject?
    private var sequence: UInt64 = 0
    private var ending = false

    func start() {
        let picker = RegionPicker(); self.picker = picker
        picker.start { [weak self] selected in
            guard let self else { return }; self.picker = nil
            guard let selected else { self.cancelCapture(); return }
            self.selected(selected)
        }
    }
    private func selected(_ selected: CGRect) {
        rect = selected
        captureScale = NSScreen.screens.first(where: { $0.frame.contains(selected) })?.backingScaleFactor ?? 1
        let center = CGPoint(x: rect.midX,y: rect.midY)
        let cgCenter = CaptureGeometry.cgRect(CGRect(origin: center,size: .zero),primaryTop: NSScreen.screens.first!.frame.maxY).origin
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        let targetWindow = windows.first(where: { row in
            guard (row[kCGWindowLayer as String] as? Int) == 0,
                  (row[kCGWindowOwnerPID as String] as? Int32) != ProcessInfo.processInfo.processIdentifier,
                  let bounds = row[kCGWindowBounds as String] as? [String:Any],
                  let area = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return area.contains(cgCenter)
        })
        targetPID = targetWindow?[kCGWindowOwnerPID as String] as? Int32
        targetWindowID = targetWindow?[kCGWindowNumber as String] as? UInt32
        let controls = NSPanel(contentRect: CGRect(x: 0,y: 0,width: 330,height: 380),styleMask: [.titled,.nonactivatingPanel],backing: .buffered,defer: false)
        controls.title = "长截图"; controls.level = .floating; controls.hidesOnDeactivate = false
        controls.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12,left: 16,bottom: 12,right: 16)
        mode.addItems(withTitles: ["手动滚动","自动滚动"]); mode.target = self; mode.action = #selector(modeChanged)
        pauseButton.target = self; pauseButton.action = #selector(togglePause)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.widthAnchor.constraint(equalToConstant: 280).isActive = true
        thumbnail.heightAnchor.constraint(equalToConstant: 190).isActive = true
        label.preferredMaxLayoutWidth = 290
        let finishButton = NSButton(title: "完成截图",target: self,action: #selector(finishCapture))
        let cancel = NSButton(title: "取消",target: self,action: #selector(cancelCapture))
        [mode,label,thumbnail,NSStackView(views:[pauseButton,finishButton,cancel])].forEach { stack.addArrangedSubview($0) }
        controls.contentView = stack
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.screens.first!
        let available = screen.visibleFrame
        let candidates = [CGPoint(x: rect.maxX+12,y: rect.minY),CGPoint(x: rect.minX-controls.frame.width-12,y: rect.minY),CGPoint(x: rect.minX,y: rect.minY-controls.frame.height-12),CGPoint(x: rect.minX,y: rect.maxY+12)]
        if let point = candidates.first(where: { available.contains(CGRect(origin:$0,size:controls.frame.size)) }) { controls.setFrameOrigin(point) }
        else if #available(macOS 14.0, *) { controls.setFrameOrigin(CGPoint(x: available.maxX-controls.frame.width-10,y: available.maxY-controls.frame.height-10)) }
        else { finish(.failure(ReShotError(message: "请缩小选区，为控制条留出空间。"))); return }
        panel = controls; showRange(); controls.orderFrontRegardless()
        state = .manual; label.stringValue = "正在采集第一帧…"
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            guard let self, self.rect.contains(NSEvent.mouseLocation) else { return }
            self.lastScroll = Date()
            if self.state == .manual || self.state == .needsAlignment { self.requestFrame() }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancelCapture() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.12,repeats: true) { [weak self] _ in self?.tick() }
        requestFrame(force: true)
    }
    private func showRange() {
        let r = rect.insetBy(dx: -4,dy: -4), t: CGFloat = 2
        let lines = [CGRect(x:r.minX-t,y:r.maxY,width:r.width+2*t,height:t),CGRect(x:r.minX-t,y:r.minY-t,width:r.width+2*t,height:t),CGRect(x:r.minX-t,y:r.minY,width:t,height:r.height),CGRect(x:r.maxX,y:r.minY,width:t,height:r.height)]
        for line in lines {
            let w = NSWindow(contentRect:line,styleMask:.borderless,backing:.buffered,defer:false)
            w.backgroundColor = .systemBlue; w.isOpaque = true; w.hasShadow = false; w.ignoresMouseEvents = true
            w.level = .screenSaver; w.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
            w.orderFrontRegardless(); rangeWindows.append(w)
        }
    }
    @objc private func modeChanged() {
        automatic = mode.indexOfSelectedItem == 1
        if automatic && !checkAutomaticPermission() { return }
        if automatic { activateTarget() }
        if !atLimit { state = automatic ? .automatic : .manual; waitingForPointer = true; duplicateAttempts = 0; pauseButton.title = "暂停" }
        label.stringValue = automatic ? "请把鼠标移入选区，开始自动滚动。" : "滚动时采集，静止时暂停。"
    }
    @objc private func togglePause() {
        guard state != .finishing, state != .cancelled, state != .completed, !atLimit else { return }
        if state == .paused || state == .needsAlignment {
            if automatic { guard checkAutomaticPermission() else { return }; activateTarget() }
            state = automatic ? .automatic : .manual; waitingForPointer = true; duplicateAttempts = 0
            pauseButton.title = "暂停"; label.stringValue = automatic ? "鼠标移入选区后继续自动滚动。" : "已恢复，请回滚少许重接后向下滚动。"
        } else { pause("已暂停，可继续或完成截图。") }
    }
    private func pause(_ message: String) { state = .paused; pauseButton.title = "继续"; label.stringValue = message }
    private func tick() {
        guard !inFlight else { return }
        if state == .automatic {
            guard rect.contains(NSEvent.mouseLocation) else {
                if !waitingForPointer { pause("鼠标离开选区，已暂停自动滚动。") }; return
            }
            guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
                pause("自动滚动未启动：辅助功能授权失效，请重新授权当前 ReShot 后点击继续。"); return
            }
            guard let targetPID, let target = NSRunningApplication(processIdentifier:targetPID), !target.isTerminated else {
                pause("自动滚动已暂停：原目标应用已关闭，请取消后重新框选。"); return
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
                pause("自动滚动已暂停：目标应用不在前台，请点击继续恢复。"); return
            }
            guard targetWindowIsValid() else {
                pause("自动滚动已暂停：鼠标下方不是原目标窗口，请移开遮挡窗口后继续。"); return
            }
            waitingForPointer = false
            if Date().timeIntervalSince(lastFrameTime) >= 0.35 {
                // WindowServer must route the wheel to the scroll view under
                // the pointer. Process-only delivery can miss that routing.
                // The target app, topmost window and pointer were all checked
                // immediately above; no synthetic mouse click is sent.
                let point = CaptureGeometry.cgRect(CGRect(origin:NSEvent.mouseLocation,size:.zero),primaryTop:NSScreen.screens.first!.frame.maxY).origin
                do { try AutoScroll.event(step:step,at:point).post(tap:.cghidEventTap) }
                catch { pause(error.localizedDescription); return }
                lastScroll = Date(); requestFrame(delay: 0.22,automaticAttempt:true)
            }
        } else if state == .manual || state == .needsAlignment {
            if Date().timeIntervalSince(lastScroll) < 0.65 { requestFrame() }
        }
    }
    private func checkAutomaticPermission() -> Bool {
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary), CGPreflightPostEventAccess() else {
            pause("自动滚动未启动：请在系统设置 → 隐私与安全性 → 辅助功能中重新允许当前 ReShot，然后点击继续。也可选择手动滚动。")
            return false
        }
        guard targetPID != nil else { pause("自动滚动未启动：无法确定原目标应用，请取消后重新框选。"); return false }
        return true
    }
    private func activateTarget() {
        // Starting/resuming automatic scrolling is an explicit user action.
        // Restore the selected app after the picker; later focus loss still pauses.
        if let targetPID { NSRunningApplication(processIdentifier:targetPID)?.activate(options:[.activateIgnoringOtherApps]) }
    }
    private func targetWindowIsValid() -> Bool {
        guard let id = targetWindowID,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else { return false }
        let point = CaptureGeometry.cgRect(CGRect(origin:NSEvent.mouseLocation,size:.zero),primaryTop:NSScreen.screens.first!.frame.maxY).origin
        let top = windows.first { row in
            guard (row[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = row[kCGWindowBounds as String] as? [String:Any],
                  let area = CGRect(dictionaryRepresentation:bounds as CFDictionary) else { return false }
            return area.contains(point)
        }
        return top?[kCGWindowNumber as String] as? UInt32 == id
    }
    private func requestFrame(force: Bool = false,delay: TimeInterval = 0,automaticAttempt: Bool = false) {
        guard !inFlight, state != .cancelled, state != .completed, !atLimit else { return }
        inFlight = true
        let isFinal = state == .finishing && force
        let selected = rect, primaryTop = NSScreen.screens.first!.frame.maxY
        worker.asyncAfter(deadline:.now()+delay) {
            guard !self.ending else { return }
            do {
                let image: CGImage
                if #available(macOS 14.0, *) {
                    if self.modern == nil {
                        let capture = try ModernRegionCapture(region:CaptureGeometry.cgRect(selected,primaryTop:primaryTop))
                        try capture.startStream(); self.modern = capture
                    }
                    let capture = self.modern as! ModernRegionCapture
                    let frame = try capture.streamFrame(after:self.sequence,timeout:self.session.count == 0 ? 2 : (force || automaticAttempt ? 0.3 : 0.08))
                    self.sequence = frame.sequence; image = frame.image
                } else {
                    DispatchQueue.main.sync { self.rangeWindows.forEach { $0.orderOut(nil) } }
                    defer { DispatchQueue.main.async { if self.state != .cancelled && self.state != .completed { self.rangeWindows.forEach { $0.orderFrontRegardless() } } } }
                    image = try CaptureService.region(selected).image
                }
                let result = try self.session.update(image), preview = self.session.preview()
                let count = self.session.count, height = self.session.height
                let pinned = self.session.topInset+self.session.bottomInset
                DispatchQueue.main.async {
                    guard self.state != .cancelled && self.state != .completed else { return }
                    self.inFlight = false; self.lastFrameTime = Date()
                    if let preview { self.thumbnail.image = NSImage(cgImage:preview,size:NSSize(width:preview.width,height:preview.height)) }
                    switch result {
                    case .appended(let rows):
                        self.canFinish = true; self.duplicateAttempts = 0
                        if count > 1 { self.motionCaptured = true }
                        self.step = max(20,min(Int32(self.rect.height*0.45),Int32(max(30,rows/2))))
                        if self.state == .needsAlignment { self.state = .manual }
                        if self.state != .paused {
                            self.label.stringValue = (self.state == .automatic && self.waitingForPointer ? "鼠标移入选区开始自动滚动 · " : "")+"已拼接 \(count) 帧 · \(image.width) × \(height) px"+(pinned > 0 ? " · 固定栏只保留一次" : "")
                        }
                    case .duplicate:
                        // An exact return to the last valid viewport also recovers a failed match.
                        self.canFinish = true
                        if self.state == .needsAlignment { self.state = .manual }
                        if automaticAttempt { self.duplicateAttempts += 1 }
                        if self.duplicateAttempts >= 3 && self.state != .finishing { self.pause(AutoScroll.idleMessage(hasProgress:self.motionCaptured)) }
                    case .rollback:
                        self.canFinish = true; self.duplicateAttempts = 0
                        if count > 1 { self.motionCaptured = true }
                        if self.state == .needsAlignment { self.state = .manual }
                        if self.state != .paused { self.label.stringValue = "已重接历史区域，继续下滚不会重复添加。" }
                    case .realignment(let message):
                        self.canFinish = false; self.step = max(20,self.step/2)
                        if self.state != .finishing && self.state != .paused { self.state = self.automatic ? .paused : .needsAlignment; self.pauseButton.title = "继续" }
                        self.label.stringValue = message
                    case .limitReached:
                        self.atLimit = true; self.canFinish = true
                        if self.state != .finishing { self.pause("已达 60000px / 192MB 上限，请完成当前长图。") }
                    }
                    if self.state == .finishing { if isFinal || self.atLimit { self.finishImage() } else { self.requestFrame(force:true) } }
                }
            } catch { DispatchQueue.main.async { guard self.state != .cancelled else { return }; self.finish(.failure(error)) } }
        }
    }
    @objc private func finishCapture() { completeCapture(allowSingleFrame:false) }
    private func completeCapture(allowSingleFrame: Bool) {
        guard state != .finishing, state != .cancelled, state != .completed else { return }
        guard canFinish else { label.stringValue = "最后画面未接上，请回滚重接后完成；或取消本次截图。"; return }
        if automatic && !motionCaptured && !allowSingleFrame, let panel {
            pause("未捕获到滚动内容，尚未生成长截图。")
            let alert = NSAlert(); alert.messageText = "尚未捕获到滚动内容"
            alert.informativeText = "自动滚动没有带来新内容。可继续采集，或明确选择只保存当前这一屏。"
            alert.addButton(withTitle:"继续采集"); alert.addButton(withTitle:"仅保存当前画面"); alert.addButton(withTitle:"取消截图")
            alert.beginSheetModal(for:panel) { response in
                guard self.state == .paused else { return }
                if response == .alertSecondButtonReturn { self.completeCapture(allowSingleFrame:true) }
                else if response == .alertThirdButtonReturn { self.cancelCapture() }
                else { self.togglePause() }
            }
            return
        }
        timer?.invalidate(); state = .finishing
        if !inFlight {
            if atLimit { finishImage() } else { requestFrame(force:true) }
        }
    }
    private func finishImage() {
        guard state == .finishing else { return }
        guard canFinish else { state = .paused; pauseButton.title = "继续"; label.stringValue = "最后一屏未接上，未保存。请继续手动重接，或取消。"; automatic = false; mode.selectItem(at:0); timer = Timer.scheduledTimer(withTimeInterval:0.12,repeats:true) { [weak self] _ in self?.tick() }; return }
        label.stringValue = "正在生成长图…"
        worker.async {
            let result = Result { [try CaptureAppearance.rounded(self.session.image(),points: self.cornerRadiusPoints,scale: self.captureScale)] }
            DispatchQueue.main.async { if self.state == .finishing { self.finish(result) } }
        }
    }
    @objc private func cancelCapture() { finish(.failure(CancellationError()),cancelled:true) }
    private func finish(_ result: Result<[CGImage],Error>,cancelled: Bool = false) {
        guard state != .cancelled, state != .completed else { return }
        state = cancelled ? .cancelled : .completed
        timer?.invalidate(); timer = nil; panel?.orderOut(nil); panel = nil; picker?.close(); picker = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        rangeWindows.forEach { $0.orderOut(nil) }; rangeWindows.removeAll()
        worker.async { self.ending = true; if #available(macOS 14.0, *) { (self.modern as? ModernRegionCapture)?.stopStream() }; self.modern = nil }
        let callback = completion; completion = nil; callback?(result)
    }
}
