import AppKit

enum SelectionGeometry {
    static func selfTest() throws {
        let bounds = CGRect(x: 0,y: 0,width: 1000,height: 800), rect = CGRect(x: 100,y: 100,width: 400,height: 300)
        let moved = adjust(rect,delta: CGPoint(x: 900,y: -500),edges: 0,bounds: bounds)
        let resized = adjust(rect,delta: CGPoint(x: 100,y: 80),edges: 2|8,bounds: bounds)
        let minimum = adjust(rect,delta: CGPoint(x: 999,y: 999),edges: 1|4,bounds: bounds)
        guard moved == CGRect(x: 600,y: 0,width: 400,height: 300), resized.size == CGSize(width: 500,height: 380), minimum.size == CGSize(width: 20,height: 20) else { throw ReShotError(message: "选区调整测试失败") }
        print("PASS: move clamps to screen, edge/corner resize, minimum size")
    }
    static func adjust(_ rect: CGRect, delta: CGPoint, edges: Int, bounds: CGRect) -> CGRect {
        if edges == 0 {
            return CGRect(x: max(bounds.minX,min(rect.minX+delta.x,bounds.maxX-rect.width)),
                          y: max(bounds.minY,min(rect.minY+delta.y,bounds.maxY-rect.height)),width: rect.width,height: rect.height)
        }
        var l = rect.minX, r = rect.maxX, b = rect.minY, t = rect.maxY
        if edges & 1 != 0 { l = max(bounds.minX,min(l+delta.x,r-20)) }
        if edges & 2 != 0 { r = min(bounds.maxX,max(r+delta.x,l+20)) }
        if edges & 4 != 0 { b = max(bounds.minY,min(b+delta.y,t-20)) }
        if edges & 8 != 0 { t = min(bounds.maxY,max(t+delta.y,b+20)) }
        return CGRect(x: l,y: b,width: r-l,height: t-b)
    }
}

private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect,styleMask: style,backing: backingStoreType,defer: flag)
        isMovable = false; isMovableByWindowBackground = false
    }
}
private final class PickerView: NSView {
    var selection = CGRect.zero
    var scale: CGFloat = 1
    var completion: ((CGRect?) -> Void)?
    var editCompletion: ((Result<CGImage?,Error>) -> Void)?
    var snapshot: CGImage?
    private var frozenImage: NSImage?
    private var crosshair: CGPoint?
    private var cursorTracking: NSTrackingArea?
    fileprivate var displaysCrosshair: Bool { selection.isEmpty && crosshair != nil }
    fileprivate var confirmationTitle: String { get { confirm.title } set { confirm.title = newValue } }
    var cornerRadiusPoints = CaptureAppearance.radius()
    let preview = ImagePreview()
    var toolbar: AnnotationToolbar?
    private var lastCrop = CGRect.zero
    private var moveLabel: CGRect { CGRect(x: max(8,selection.minX),y: min(bounds.height-28,selection.maxY+8),width: 235,height: 24) }
    func enableEditing(_ image: CGImage) {
        snapshot = image
        frozenImage = NSImage(cgImage: image,size: bounds.size)
        confirm.isHidden = true; cancel.isHidden = true
        preview.borderType = .noBorder; preview.hasVerticalScroller = false
        preview.wantsLayer = true; preview.layer?.masksToBounds = true
        preview.isHidden = true; addSubview(preview)
        let bar = AnnotationToolbar(preview: preview); toolbar = bar; addSubview(bar); bar.isHidden = true
        bar.confirm = { [weak self] in self?.accept() }; bar.cancel = { [weak self] in self?.abandon() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point,from: superview)
        if toolbar?.frame.contains(localPoint) == true { return super.hitTest(point) }
        if snapshot != nil, !selection.isEmpty {
            let nearEdge = selection.insetBy(dx: -9,dy: -9).contains(localPoint) && !selection.insetBy(dx: 9,dy: 9).contains(localPoint)
            if preview.annotations.tool == .select && (nearEdge || (selection.contains(localPoint) && preview.annotations.marks.isEmpty)) { return self }
        }
        return super.hitTest(point)
    }
    private func updateEditor() {
        guard let snapshot else { return }
        guard selection.width >= 20, selection.height >= 20 else { preview.isHidden = true; toolbar?.isHidden = true; return }
        let crop = CaptureGeometry.pixelAligned(CGRect(x: selection.minX,y: bounds.height-selection.maxY,width: selection.width,height: selection.height),scale: scale)
        let pixels = CGRect(x: crop.minX*scale,y: crop.minY*scale,width: crop.width*scale,height: crop.height*scale).intersection(CGRect(x: 0,y: 0,width: snapshot.width,height: snapshot.height))
        guard let image = snapshot.cropping(to: pixels) else { return }
        if pixels != lastCrop {
            var marks = preview.annotations.marks
            let dx = lastCrop.minX-pixels.minX, dy = lastCrop.minY-pixels.minY
            for i in marks.indices { marks[i].points = marks[i].points.map { CGPoint(x: $0.x+dx,y: $0.y+dy) } }
            preview.frame = CGRect(x: pixels.minX/scale,y: bounds.height-pixels.maxY/scale,width: pixels.width/scale,height: pixels.height/scale)
            preview.display(image,fitWhole: true,reset: true)
            preview.annotations.marks = marks; preview.refreshAnnotations(); lastCrop = pixels
        }
        preview.layer?.cornerRadius = min(cornerRadiusPoints,min(preview.frame.width,preview.frame.height)/2)
        preview.isHidden = false
        let barWidth = min(bounds.width-16,toolbar?.preferredSize.width ?? 473)
        let barHeight = toolbar?.preferredSize.height ?? 32
        let below = selection.minY-barHeight-8
        let y = below >= 8 ? below : min(bounds.height-barHeight-8,selection.maxY+8)
        toolbar?.frame = CGRect(x: max(8,min(selection.maxX-barWidth,bounds.width-barWidth-8)),y: max(8,y),width: barWidth,height: barHeight)
        toolbar?.isHidden = false
    }
    private var anchor = CGPoint.zero, original = CGRect.zero, edges = 0
    private var creating = true
    private var selectionGestureActive = false
    override var mouseDownCanMoveWindow: Bool { false }
    private let confirm = NSButton(title: "确认截图 ↵",target: nil,action: nil)
    private let cancel = NSButton(title: "取消 Esc",target: nil,action: nil)
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    fileprivate var selectionCursor: NSCursor {
        let established = selectionGestureActive ? original : selection
        if snapshot != nil && established.width >= 20 && established.height >= 20 {
            return .arrow
        }
        return .crosshair
    }
    override func resetCursorRects() { addCursorRect(bounds,cursor: selectionCursor) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let tracking = NSTrackingArea(rect: .zero,options: [.activeAlways,.inVisibleRect,.mouseMoved,.mouseEnteredAndExited],owner: self,userInfo: nil)
        addTrackingArea(tracking); cursorTracking = tracking
    }
    fileprivate func trackPointer(_ point: CGPoint) { crosshair = bounds.contains(point) ? point : nil; needsDisplay = true }
    override func mouseMoved(with event: NSEvent) { trackPointer(convert(event.locationInWindow,from: nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { crosshair = nil; needsDisplay = true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        confirm.target = self; confirm.action = #selector(accept)
        cancel.target = self; cancel.action = #selector(abandon)
        addSubview(confirm); addSubview(cancel); positionButtons()
    }
    required init?(coder: NSCoder) { fatalError() }
    fileprivate func positionButtons() {
        let x = max(12,min(selection.isEmpty ? bounds.midX-120 : selection.midX-120,bounds.width-252))
        let y = selection.isEmpty ? bounds.height-90 : (selection.minY >= 48 ? selection.minY-42 : min(bounds.height-42,selection.maxY+10))
        confirm.frame = CGRect(x: x,y: y,width: 130,height: 32)
        cancel.frame = CGRect(x: x+140,y: y,width: 100,height: 32)
        confirm.isEnabled = selection.width >= 20 && selection.height >= 20
        if selectionGestureActive && creating && snapshot != nil {
            preview.isHidden = true; toolbar?.isHidden = true
        } else { updateEditor() }
    }
    override func draw(_ dirtyRect: NSRect) {
        frozenImage?.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.35).setFill(); bounds.fill()
        if displaysCrosshair, let crosshair {
            let line = NSBezierPath()
            line.move(to: CGPoint(x: bounds.minX,y: crosshair.y)); line.line(to: CGPoint(x: bounds.maxX,y: crosshair.y))
            line.move(to: CGPoint(x: crosshair.x,y: bounds.minY)); line.line(to: CGPoint(x: crosshair.x,y: bounds.maxY))
            NSColor.white.withAlphaComponent(0.75).setStroke(); line.lineWidth = 1/scale; line.stroke()
            let pixel = "\(Int((crosshair.x*scale).rounded())), \(Int(((bounds.height-crosshair.y)*scale).rounded())) px"
            let style: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedSystemFont(ofSize: 12,weight: .medium),.foregroundColor:NSColor.white,.backgroundColor:NSColor.black]
            (pixel as NSString).draw(at: CGPoint(x: max(4,min(crosshair.x+10,bounds.width-130)),y: max(4,min(crosshair.y-22,bounds.height-18))),withAttributes: style)
        }
        if !selection.isEmpty {
            let radius = snapshot == nil ? 0 : min(cornerRadiusPoints,min(selection.width,selection.height)/2)
            let outline = NSBezierPath(roundedRect: selection,xRadius: radius,yRadius: radius)
            if snapshot == nil { NSColor.clear.setFill(); selection.fill(using: .copy) }
            else if preview.isHidden {
                NSGraphicsContext.saveGraphicsState(); outline.addClip(); frozenImage?.draw(in: bounds); NSGraphicsContext.restoreGraphicsState()
            }
            NSColor.systemBlue.setStroke(); outline.lineWidth = 2; outline.stroke()
            NSColor.white.setFill()
            for x in [selection.minX,selection.midX,selection.maxX] {
                for y in [selection.minY,selection.midY,selection.maxY] where x != selection.midX || y != selection.midY {
                    NSBezierPath(rect: CGRect(x: x-4,y: y-4,width: 8,height: 8)).fill()
                }
            }
            let style: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedSystemFont(ofSize: 17,weight: .bold),.foregroundColor:NSColor.white,.backgroundColor:NSColor.black]
            let aligned = CaptureGeometry.pixelAligned(CGRect(x: selection.minX,y: bounds.height-selection.maxY,width: selection.width,height: selection.height),scale: scale)
            let pixelWidth = Int((aligned.width*scale).rounded()), pixelHeight = Int((aligned.height*scale).rounded())
            ("\(pixelWidth) px × \(pixelHeight) px" as NSString).draw(at: moveLabel.origin,withAttributes: style)
            ("\(pixelHeight) px" as NSString).draw(at: CGPoint(x: max(8,selection.minX-90),y: selection.midY),withAttributes: style)
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow,from: nil)
        // Child controls and the annotation canvas never start a selection drag.
        if let toolbar, !toolbar.isHidden, toolbar.frame.contains(point) { return }
        if snapshot != nil, !selection.isEmpty, preview.annotations.tool != .select { return }
        selectionGestureActive = true
        window?.makeKey(); window?.makeFirstResponder(self); anchor = convert(event.locationInWindow,from: nil); original = selection; edges = 0
        let labelDrag = snapshot != nil && !selection.isEmpty && moveLabel.contains(anchor)
        let near = (selection.insetBy(dx: -9,dy: -9).contains(anchor) || labelDrag) && !selection.isEmpty
        if near && !labelDrag {
            if abs(anchor.x-selection.minX)<9 { edges |= 1 }; if abs(anchor.x-selection.maxX)<9 { edges |= 2 }
            if abs(anchor.y-selection.minY)<9 { edges |= 4 }; if abs(anchor.y-selection.maxY)<9 { edges |= 8 }
        }
        creating = !near
    }
    override func mouseDragged(with event: NSEvent) {
        guard selectionGestureActive else { return }
        let point = convert(event.locationInWindow,from: nil)
        if creating {
            selection = CGRect(x: min(anchor.x,point.x),y: min(anchor.y,point.y),width: abs(anchor.x-point.x),height: abs(anchor.y-point.y)).intersection(bounds)
        } else { selection = SelectionGeometry.adjust(original,delta: CGPoint(x: point.x-anchor.x,y: point.y-anchor.y),edges: edges,bounds: bounds) }
        positionButtons(); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard selectionGestureActive else { return }
        mouseDragged(with: event); selectionGestureActive = false
        if snapshot != nil {
            window?.invalidateCursorRects(for: self)
            selectionCursor.set()
        }
        positionButtons(); needsDisplay = true
    }
    @objc fileprivate func accept() {
        guard confirm.isEnabled, let window else { return }
        if snapshot != nil {
            do { editCompletion?(.success(try CaptureAppearance.rounded(preview.renderedImage(),points: cornerRadiusPoints,scale: scale))) }
            catch { editCompletion?(.failure(error)) }
        } else { completion?(window.convertToScreen(selection)) }
    }
    @objc fileprivate func abandon() { if snapshot != nil { editCompletion?(.success(nil)) } else { completion?(nil) } }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { abandon() }; if event.keyCode == 36 { accept() }
    }
}

final class RegionPicker {
    private var windows: [NSWindow] = []
    private var completion: ((CGRect?) -> Void)?
    private var editCompletion: ((Result<CGImage?,Error>) -> Void)?
    func startEditing(_ snapshots: [CGImage], completion: @escaping (Result<CGImage?,Error>) -> Void) {
        guard snapshots.count == NSScreen.screens.count else { completion(.failure(ReShotError(message: "显示器配置已变化，请重新截图。"))); return }
        editCompletion = completion
        open(snapshots: snapshots)
    }
    func start(confirmTitle: String = "确认截图 ↵", _ completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        open(snapshots: nil,confirmTitle: confirmTitle)
    }
    private func open(snapshots: [CGImage]?,confirmTitle: String = "确认截图 ↵") {
        NSApp.unhide(nil)
        let pointer = NSEvent.mouseLocation
        var activeView: PickerView?
        for (index,screen) in NSScreen.screens.enumerated() {
            let w = PickerWindow(contentRect: screen.frame,styleMask: [.borderless],backing: .buffered,defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.level = snapshots == nil ? .screenSaver : .floating
            w.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
            let view = PickerView(frame: CGRect(origin: .zero,size: screen.frame.size)); view.scale = screen.backingScaleFactor
            view.confirmationTitle = confirmTitle; w.acceptsMouseMovedEvents = true
            if let snapshots {
                view.enableEditing(snapshots[index])
                view.editCompletion = { [weak self] result in
                    guard let self, let callback = self.editCompletion else { return }
                    self.editCompletion = nil; self.close(); callback(result)
                }
            }
            view.completion = { [weak self] rect in
                guard let self, let callback = self.completion else { return }
                self.completion = nil; self.close(); callback(rect)
            }
            w.contentView = view; w.orderFrontRegardless(); windows.append(w)
            if screen.frame.contains(pointer) {
                view.trackPointer(CGPoint(x: pointer.x-screen.frame.minX,y: pointer.y-screen.frame.minY)); activeView = view
            }
        }
        if snapshots != nil { NSApp.activate(ignoringOtherApps: true) }
        if let view = activeView ?? (windows.first?.contentView as? PickerView) {
            view.window?.makeKeyAndOrderFront(nil); view.window?.makeFirstResponder(view)
        }
    }
    static func editingSelfTest() throws {
        _ = NSApplication.shared
        let recordingView = PickerView(frame: CGRect(x: 0,y: 0,width: 800,height: 600))
        recordingView.confirmationTitle = "开始录屏 ↵"
        recordingView.selection = CGRect(x: 200,y: 180,width: 400,height: 280)
        recordingView.positionButtons()
        let recordingButtons = recordingView.subviews.compactMap { $0 as? NSButton }
        let union = recordingButtons.reduce(CGRect.null) { $0.union($1.frame) }
        guard abs(union.midX-recordingView.selection.midX) < 0.5, union.maxY < recordingView.selection.minY else {
            throw ReShotError(message: "录屏确认和取消按钮应居中显示在选区下方")
        }
        let width = 1600, height = 1200
        let context = CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2,green: 0.8,blue: 0.3,alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: width,height: height))
        let view = PickerView(frame: CGRect(x: 0,y: 0,width: 800,height: 600)); view.scale = 2
        let window = PickerWindow(contentRect: view.bounds,styleMask: [.borderless],backing: .buffered,defer: false); window.contentView = view
        defer { window.orderOut(nil) }
        view.cornerRadiusPoints = 0
        view.enableEditing(context.makeImage()!)
        var calls = 0; var output: CGImage?
        view.editCompletion = { result in calls += 1; output = try? result.get() }
        view.trackPointer(CGPoint(x: 100,y: 100))
        guard view.displaysCrosshair, view.acceptsFirstMouse(for: nil) else { throw ReShotError(message: "进入选区应自动显示标线并接受第一次拖动") }
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds,to: bitmap)
            try bitmap.representation(using: .png,properties: [:])?.write(to: URL(fileURLWithPath: "dist/region-guides-2.0.png"))
        }
        func selectionEvent(_ type: NSEvent.EventType,_ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type,location: view.convert(point,to: nil),modifierFlags: [],timestamp: 0,windowNumber: window.windowNumber,context: nil,eventNumber: 1,clickCount: 1,pressure: 1)!
        }
        view.mouseDown(with: selectionEvent(.leftMouseDown,CGPoint(x: 100,y: 100)))
        view.mouseDragged(with: selectionEvent(.leftMouseDragged,CGPoint(x: 400,y: 300)))
        guard view.toolbar?.isHidden == true else { throw ReShotError(message: "标注栏不应抢占框选手势") }
        guard view.selectionCursor === NSCursor.crosshair else { throw ReShotError(message: "首次框选期间应保留十字光标") }
        view.mouseUp(with: selectionEvent(.leftMouseUp,CGPoint(x: 400,y: 300)))
        guard view.selectionCursor === NSCursor.arrow else { throw ReShotError(message: "选区完成后应恢复系统指针") }
        guard calls == 0, view.toolbar?.isHidden == false, view.preview.displayedImage?.width == 600, view.preview.displayedImage?.height == 400 else { throw ReShotError(message: "框选后应直接显示标注，且确认前不提交") }
        view.layoutSubtreeIfNeeded()
        func buttons(_ parent: NSView) -> [NSButton] { parent.subviews.flatMap { child in (child as? NSButton).map { [$0] } ?? buttons(child) } }
        let controls = buttons(view.toolbar!).filter { $0.toolTip != nil }
        func control(_ title: String) throws -> NSButton {
            guard let button = controls.first(where: { $0.toolTip == title }) else { throw ReShotError(message: "缺少按钮："+title) }; return button
        }
        for button in controls {
            let center = button.convert(CGPoint(x: button.bounds.midX,y: button.bounds.midY),to: view)
            let target = view.hitTest(center)
            guard target === button else { throw ReShotError(message: "工具栏点击被其他视图截获：\(button.toolTip ?? button.title)，命中 \(String(describing: target))") }
        }
        try control("矩形").performClick(nil)
        let canvasPoint = CGPoint(x: 220,y: 180)
        guard let canvas = view.hitTest(canvasPoint), canvas !== view, canvas.isDescendant(of: view.preview) else { throw ReShotError(message: "标注点击误命中选区控制层") }
        let fixedSelection = view.selection
        guard !window.isMovable, !view.mouseDownCanMoveWindow, !canvas.mouseDownCanMoveWindow else { throw ReShotError(message: "标注层不能拖动整个覆盖窗口") }
        func mouse(_ type: NSEvent.EventType,_ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type,location: view.convert(point,to: nil),modifierFlags: [],timestamp: 0,windowNumber: window.windowNumber,context: nil,eventNumber: 1,clickCount: 1,pressure: 1)!
        }
        try control("选择").performClick(nil)
        view.mouseDown(with: mouse(.leftMouseDown,view.selection.origin))
        view.mouseUp(with: mouse(.leftMouseUp,view.selection.origin))
        try control("矩形").performClick(nil)
        let edgePoint = CGPoint(x: view.selection.minX+2,y: view.selection.midY)
        guard view.hitTest(edgePoint)?.isDescendant(of: view.preview) == true else { throw ReShotError(message: "标注工具在选区边缘仍误触缩放") }
        canvas.mouseDown(with: mouse(.leftMouseDown,canvasPoint))
        canvas.mouseDragged(with: mouse(.leftMouseDragged,CGPoint(x: 280,y: 240)))
        canvas.mouseUp(with: mouse(.leftMouseUp,CGPoint(x: 280,y: 240)))
        guard view.selection == fixedSelection, view.preview.annotations.marks.count == 1 else { throw ReShotError(message: "绘制矩形导致选区变化或未生成标注") }
        // The parent also ignores unrelated releases, even after a completed real selection gesture.
        view.mouseDown(with: mouse(.leftMouseDown,CGPoint(x: 700,y: 500)))
        view.mouseDragged(with: mouse(.leftMouseDragged,CGPoint(x: 730,y: 530)))
        view.mouseUp(with: mouse(.leftMouseUp,CGPoint(x: 700,y: 500)))
        guard view.selection == fixedSelection else { throw ReShotError(message: "子视图松开事件移动了选区") }
        try control("撤销").performClick(nil)
        guard view.preview.annotations.marks.isEmpty else { throw ReShotError(message: "撤销按钮未生效") }
        try control("重做").performClick(nil)
        guard view.preview.annotations.marks.count == 1 else { throw ReShotError(message: "重做按钮未生效") }
        view.preview.annotations.marks = [Mark(tool: .rectangle,points: [CGPoint(x: 40,y: 40),CGPoint(x: 150,y: 140)],color: .red,width: 5)]
        view.selection.origin.x -= 10; view.selection.size.width += 10; view.positionButtons()
        guard view.preview.annotations.marks[0].points[0].x == 60 else { throw ReShotError(message: "调整选区后标注位置漂移") }
        view.accept()
        guard calls == 1, let exported = output, exported.width == 620, exported.height == 400 else { throw ReShotError(message: "确认未输出 Retina 原尺寸图片") }
        let bitmap = NSBitmapImageRep(cgImage: exported)
        guard let markColor = bitmap.colorAt(x: 60,y: 60)?.usingColorSpace(.deviceRGB), markColor.redComponent > 0.8 else { throw ReShotError(message: "最终截图缺少标注像素") }
        guard let corner = bitmap.colorAt(x: 0,y: 0)?.usingColorSpace(.deviceRGB), corner.greenComponent > 0.7, corner.redComponent < 0.3 else { throw ReShotError(message: "蓝框或遮罩进入最终截图") }
        view.cornerRadiusPoints = 10; view.positionButtons(); view.layoutSubtreeIfNeeded()
        guard let toolbar = view.toolbar, toolbar.frame.width == toolbar.preferredSize.width, toolbar.frame.width < 520, toolbar.frame.height == 32 else { throw ReShotError(message: "标注栏没有收紧到控件宽度") }
        let swatch = toolbar.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSColorWell }.first
        guard swatch?.frame.size == CGSize(width: 26,height: 24) && controls.allSatisfy({ $0.frame.size == CGSize(width: 26,height: 24) }) else { throw ReShotError(message: "工具栏控件尺寸未统一：色块 \(String(describing: swatch?.frame.size))，按钮 \(controls.map { ($0.toolTip ?? "", $0.frame.size) })") }
        view.accept()
        guard calls == 2, let rounded = output, NSBitmapImageRep(cgImage: rounded).colorAt(x: 0,y: 0)!.alphaComponent == 0, rounded.width == 620 else { throw ReShotError(message: "区域导出没有应用圆角") }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds,to: bitmap)
            try bitmap.representation(using: .png,properties: [:])!.write(to: URL(fileURLWithPath: "dist/region-annotation-workflow.png"))
        }
        try control("取消 Esc").performClick(nil); guard calls == 3, output == nil else { throw ReShotError(message: "取消必须返回空结果") }
        print("PASS: automatic pixel guides, single drag, uniform toolbar, canvas drag/release preserves selection, toolbar hit targets, undo/redo/cancel actions, frozen Retina selection, immediate toolbar, deferred commit, resized marks, annotated export, no overlay pixels, cancel discards")
    }
    func close() { if windows.contains(where: { ($0.contentView as? PickerView)?.snapshot != nil }) { NSColorPanel.shared.orderOut(nil) }; windows.forEach { $0.orderOut(nil) }; windows.removeAll(); completion = nil; editCompletion = nil }
}
