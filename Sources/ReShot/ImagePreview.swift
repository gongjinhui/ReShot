import AppKit

final class ImageCanvas: NSView {
    let document = AnnotationDocument()
    var image: CGImage? { didSet { if image !== oldValue { if let image { document.reset(image) } }; needsDisplay = true } }
    var liveOverlay = false
    var recordingBorder = false
    var recordingPaused = false { didSet { needsDisplay = true } }
    private(set) var drawingGesture = false
    var marksChanged: (([Mark]) -> Void)?
    var active: Int?
    func refreshMarks() {
        active = nil
        drawingGesture = false
        invalidateMarks()
    }
    private func invalidateMarks() {
        needsDisplay = true
        marksChanged?(document.marks)
    }
    var previous = CGPoint.zero
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // NSView's default forwards mouseUp through the responder chain. The region
    // selector must never interpret an annotation's release as a selection drag.
    override func mouseUp(with event: NSEvent) { drawingGesture = false; invalidateMarks() }
    var imageScale: CGFloat { guard let image else { return 1 }; return min(bounds.width/CGFloat(image.width),bounds.height/CGFloat(image.height)) }
    func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow,from: nil); return CGPoint(x: p.x/imageScale,y: p.y/imageScale)
    }
    override func mouseDown(with event: NSEvent) {
        guard image != nil || liveOverlay else { return }; window?.makeFirstResponder(self)
        drawingGesture = true
        let p = point(event); previous = p
        if document.tool == .select {
            active = document.marks.lastIndex { $0.rect.insetBy(dx: -20,dy: -20).contains(p) }
            if let active {
                document.checkpoint()
                if event.clickCount == 2 && document.marks[active].tool == .text {
                    let alert = NSAlert(); alert.messageText = "修改文字"
                    let field = NSTextField(frame: CGRect(x: 0,y: 0,width: 300,height: 28)); field.stringValue = document.marks[active].text
                    alert.accessoryView = field; alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消"); alert.window.initialFirstResponder = field
                    if alert.runModal() == .alertFirstButtonReturn { document.marks[active].text = field.stringValue; invalidateMarks() }
                }
            }; return
        }
        document.checkpoint()
        var mark = Mark(tool: document.tool,points: [p,p],color: document.color,width: document.width)
        if document.tool == .text {
            let alert = NSAlert(); alert.messageText = "文字标注"
            let field = NSTextField(frame: CGRect(x: 0,y: 0,width: 300,height: 28)); alert.accessoryView = field
            alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else {
                drawingGesture = false; invalidateMarks(); return
            }
            mark.text = field.stringValue; drawingGesture = false
        }
        if document.tool == .number { mark.text = String(document.marks.filter { $0.tool == .number }.count+1) }
        document.marks.append(mark); active = document.marks.count-1; invalidateMarks()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let active else { return }; let p = point(event)
        if document.tool == .select {
            document.marks[active].points = document.marks[active].points.map { CGPoint(x: $0.x+p.x-previous.x,y: $0.y+p.y-previous.y) }; previous = p
        } else if document.tool == .pen { document.marks[active].points.append(p) }
        else { document.marks[active].points[1] = p }
        invalidateMarks()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51, let active, document.marks.indices.contains(active) { document.checkpoint(); document.marks.remove(at: active); self.active = nil; invalidateMarks() }
        else { super.keyDown(with: event) }
    }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if liveOverlay {
            dirtyRect.fill(using: .clear)
            AnnotationDocument.drawMarks(document.marks)
            if recordingBorder {
                NSColor.systemBlue.withAlphaComponent(recordingPaused ? 0.55 : 0.85).setStroke()
                let rect = bounds.insetBy(dx: 0.75,dy: 0.75)
                let dash = NSBezierPath(rect: rect); dash.lineWidth = 0.5
                dash.setLineDash([4,4],count: 2,phase: 0); dash.stroke()
                let corners = NSBezierPath(); corners.lineWidth = 1.5
                let length = min(12,min(rect.width,rect.height)/3)
                for x in [rect.minX,rect.maxX] {
                    for y in [rect.minY,rect.maxY] {
                        let dx: CGFloat = x == rect.minX ? length : -length
                        let dy: CGFloat = y == rect.minY ? length : -length
                        corners.move(to: CGPoint(x: x+dx,y: y)); corners.line(to: CGPoint(x: x,y: y)); corners.line(to: CGPoint(x: x,y: y+dy))
                    }
                }
                corners.stroke()
            }
            return
        }
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        guard image != nil else { return }
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState(); context.scaleBy(x: imageScale,y: imageScale)
        document.draw(); context.restoreGState()
    }
}

/// A frame-based canvas inside a scroll view. It does not depend on an image
/// view's intrinsic size or the layout state of a hidden window.
final class ImagePreview: NSScrollView {
    private let canvas = ImageCanvas(frame: .zero)
    private var fittingWhole = false
    private var updating = false
    var displayedImage: CGImage? { canvas.image }
    var annotations: AnnotationDocument { canvas.document }
    func clear() { canvas.image = nil; canvas.document.image = nil; canvas.document.marks = []; refreshAnnotations() }
    func refreshAnnotations() { canvas.refreshMarks() }
    func renderedImage() throws -> CGImage { try canvas.document.rendered() }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = true; autohidesScrollers = true; borderType = .bezelBorder
        canvas.autoresizingMask = []; documentView = canvas
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    convenience init() { self.init(frame: .zero) }
    override func tile() { super.tile(); layoutImage(reset: false) }
    func display(_ image: CGImage, fitWhole: Bool, reset: Bool) {
        canvas.image = image; fittingWhole = fitWhole; layoutImage(reset: reset)
    }
    private func layoutImage(reset: Bool) {
        guard !updating, let image = canvas.image else { return }
        updating = true; defer { updating = false }
        let viewport = contentSize
        guard viewport.width > 1, viewport.height > 1 else { return }
        let widthScale = viewport.width/CGFloat(image.width)
        let scale = fittingWhole ? min(widthScale,viewport.height/CGFloat(image.height)) : widthScale
        let size = NSSize(width: viewport.width, height: max(viewport.height,CGFloat(image.height)*scale))
        if canvas.frame.size != size { canvas.setFrameSize(size) }
        canvas.needsDisplay = true
        if reset { contentView.scroll(to: .zero); reflectScrolledClipView(contentView) }
    }
}

enum ClipboardImages {
    static func read(_ board: NSPasteboard) -> CGImage? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = board.data(forType: type), let source = CGImageSourceCreateWithData(data as CFData,nil),
               let image = CGImageSourceCreateImageAtIndex(source,0,nil) { return image }
        }
        if let images = board.readObjects(forClasses: [NSImage.self]) as? [NSImage], let image = images.first {
            return image.cgImage(forProposedRect: nil,context: nil,hints: nil)
        }
        return nil
    }
}
