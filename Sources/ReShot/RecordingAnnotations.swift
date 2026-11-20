import AppKit
import CoreImage

private final class RecordingCanvasPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The canvas is excluded from capture. Only the rasterized marks are encoded.
final class RecordingAnnotations {
    let canvas: ImageCanvas
    let toolbar: AnnotationToolbar
    private let panel: NSPanel
    private let lock = NSLock()
    private var marks: [Mark] = []
    private var revision = 0
    private var edits = 0
    private var editing = false
    private var trackedEdits = -1
    private let tracker = AnnotationTracker()
    private lazy var trackingContext = CIContext(options: [.cacheIntermediates: false])
    // Accessed only by the encoder queue.
    private var renderedRevision = -1
    private var rendered: CIImage?
    private let pointSize: CGSize

    init(area: CGRect) {
        pointSize = area.size
        canvas = ImageCanvas(frame: CGRect(origin: .zero,size: area.size))
        canvas.liveOverlay = true
        canvas.wantsLayer = true
        canvas.recordingBorder = true
        toolbar = AnnotationToolbar(document: canvas.document,recording: true,refresh: { [weak canvas] in canvas?.refreshMarks() })
        panel = RecordingCanvasPanel(contentRect: area,styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        panel.contentView = canvas
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        canvas.marksChanged = { [weak self] marks in self?.update(marks) }
        toolbar.toolChanged = { [weak self] tool in
            guard let self else { return }
            let drawing = tool != .select
            self.panel.ignoresMouseEvents = !drawing
            self.panel.backgroundColor = drawing ? NSColor.black.withAlphaComponent(0.02) : .clear
        }
    }
    func show() { panel.orderFrontRegardless() }
    func setPaused(_ paused: Bool) { canvas.recordingPaused = paused }
    func close() { toolbar.dismissOptions(); panel.orderOut(nil) }
    private func update(_ values: [Mark]) {
        lock.lock()
        marks = values
        editing = canvas.drawingGesture
        edits += 1
        revision += 1
        lock.unlock()
    }
    /// Called on the capture queue, before compositing this same screen frame.
    func track(_ buffer: CVPixelBuffer) throws {
        lock.lock()
        let current = marks, revision = revision, edits = edits, editing = editing
        lock.unlock()
        guard !current.isEmpty, !editing else { tracker.reset(); return }
        if trackedEdits != edits { tracker.reset(); trackedEdits = edits }
        let source = CIImage(cvPixelBuffer: buffer)
        let factor = min(1,512/source.extent.width,384/source.extent.height)
        let reduced = source.transformed(by: CGAffineTransform(scaleX: factor,y: factor))
        guard let image = trackingContext.createCGImage(reduced,from: reduced.extent.integral) else { return }
        let followed = tracker.follow(current,in: try AnnotationTracker.Raster(image),pointSize: pointSize)
        let changed = followed.count != current.count || zip(followed,current).contains { $0.points != $1.points }
        guard changed else { return }
        lock.lock()
        guard self.revision == revision else { lock.unlock(); return }
        marks = followed; self.revision += 1
        let appliedRevision = self.revision
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.revision == appliedRevision
            self.lock.unlock()
            guard current, !self.canvas.drawingGesture else { return }
            self.canvas.document.replaceTrackedMarks(followed)
            self.canvas.active = nil
            self.canvas.needsDisplay = true
        }
    }
    func image(width: Int,height: Int) throws -> CIImage? {
        lock.lock()
        let revision = revision, marks = marks
        lock.unlock()
        if renderedRevision != revision {
            rendered = try Self.render(marks,pointSize: pointSize,width: width,height: height)
            renderedRevision = revision
        }
        return rendered
    }
    static func interactionSelfTest() throws {
        let overlay = RecordingAnnotations(area: CGRect(x: 0,y: 0,width: 160,height: 100))
        func button(in view: NSView,title: String) -> NSButton? {
            if let button = view as? NSButton, button.toolTip == title { return button }
            return view.subviews.lazy.compactMap { button(in: $0,title: title) }.first
        }
        guard overlay.panel.ignoresMouseEvents, overlay.canvas.recordingBorder,
              let draw = button(in: overlay.toolbar,title: "画笔"),
              let desktop = button(in: overlay.toolbar,title: "操作桌面"),
              let clear = button(in: overlay.toolbar,title: "清空标注") else { throw ReShotError(message: "录屏边框或标注入口缺失。") }
        draw.performClick(nil)
        guard !overlay.panel.ignoresMouseEvents else { throw ReShotError(message: "标注模式没有接收鼠标。") }
        func event(_ type: NSEvent.EventType,_ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type,location: point,modifierFlags: [],timestamp: 0,windowNumber: overlay.panel.windowNumber,context: nil,eventNumber: 1,clickCount: 1,pressure: 1)!
        }
        overlay.canvas.mouseDown(with: event(.leftMouseDown,CGPoint(x: 15,y: 85)))
        overlay.canvas.mouseDragged(with: event(.leftMouseDragged,CGPoint(x: 75,y: 60)))
        overlay.canvas.mouseUp(with: event(.leftMouseUp,CGPoint(x: 75,y: 60)))
        desktop.performClick(nil)
        guard overlay.panel.ignoresMouseEvents, try overlay.image(width: 320,height: 200) != nil else {
            throw ReShotError(message: "操作桌面时应保留标注并让鼠标穿过。")
        }
        clear.performClick(nil)
        guard try overlay.image(width: 320,height: 200) == nil else { throw ReShotError(message: "清空后标注仍写入视频。") }
        print("PASS: recording border, draw-through mode switch, retained marks, clear invalidates encoded overlay")
    }
    static func render(_ marks: [Mark],pointSize: CGSize,width: Int,height: Int) throws -> CIImage? {
        guard !marks.isEmpty else { return nil }
        guard let context = CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ReShotError(message: "无法生成录屏标注画面。")
        }
        context.translateBy(x: 0,y: CGFloat(height))
        context.scaleBy(x: CGFloat(width)/pointSize.width,y: -CGFloat(height)/pointSize.height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context,flipped: true)
        AnnotationDocument.drawMarks(marks)
        guard let image = context.makeImage() else { throw ReShotError(message: "录屏标注渲染失败。") }
        return CIImage(cgImage: image)
    }
}
