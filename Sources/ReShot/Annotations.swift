import AppKit

enum MarkTool: String, CaseIterable {
    case select = "选择", rectangle = "矩形", ellipse = "圆", line = "直线", arrow = "箭头", pen = "画笔", mosaic = "马赛克", text = "文字", number = "序号", highlight = "高亮"
}
struct Mark {
    var id = UUID()
    var tool: MarkTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text = ""
    var rect: CGRect {
        if let first = points.first, tool == .text {
            return CGRect(origin: first,size: (text as NSString).size(withAttributes: [.font:NSFont.systemFont(ofSize: max(18,width*6))]))
        }
        if let first = points.first, tool == .number { return CGRect(origin: first,size: CGSize(width: max(30,width*9),height: max(30,width*9))) }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min() ?? 0,y: ys.min() ?? 0,width: max(1,(xs.max() ?? 0)-(xs.min() ?? 0)),height: max(1,(ys.max() ?? 0)-(ys.min() ?? 0)))
    }
}
final class AnnotationDocument {
    var image: CGImage?
    var marks: [Mark] = []
    var tool: MarkTool = .select
    var color = NSColor.systemRed
    var width: CGFloat = 4
    private var undoStack: [[Mark]] = [], redoStack: [[Mark]] = []
    func reset(_ image: CGImage) { self.image = image; marks = []; undoStack = []; redoStack = [] }
    func replaceTrackedMarks(_ values: [Mark]) {
        let previous = Dictionary(uniqueKeysWithValues: marks.map { ($0.id,$0) })
        let current = Dictionary(uniqueKeysWithValues: values.map { ($0.id,$0) })
        func moveHistory(_ history: [[Mark]]) -> [[Mark]] {
            history.map { state in
                state.compactMap { mark in
                    guard let old = previous[mark.id]?.points.first, let new = current[mark.id]?.points.first else { return nil }
                    var moved = mark
                    moved.points = moved.points.map { CGPoint(x: $0.x+new.x-old.x,y: $0.y+new.y-old.y) }
                    return moved
                }
            }
        }
        undoStack = moveHistory(undoStack)
        redoStack = moveHistory(redoStack)
        marks = values
    }
    func checkpoint() { undoStack.append(marks); redoStack = [] }
    func undo() { guard let last = undoStack.popLast() else { return }; redoStack.append(marks); marks = last }
    func redo() { guard let last = redoStack.popLast() else { return }; undoStack.append(marks); marks = last }
    func draw() {
        guard let image else { return }
        NSImage(cgImage: image,size: NSSize(width: image.width,height: image.height)).draw(in: CGRect(x: 0,y: 0,width: image.width,height: image.height),from: .zero,operation: .sourceOver,fraction: 1,respectFlipped: true,hints: nil)
        Self.drawMarks(marks,source: image)
    }
    static func drawMarks(_ marks: [Mark],source: CGImage? = nil) {
        for mark in marks {
            guard let first = mark.points.first, let last = mark.points.last else { continue }
            mark.color.setStroke(); mark.color.setFill()
            let p = NSBezierPath(); p.lineWidth = mark.width; p.lineCapStyle = .round; p.lineJoinStyle = .round
            switch mark.tool {
            case .rectangle: p.appendRect(mark.rect); p.stroke()
            case .ellipse: p.appendOval(in: mark.rect); p.stroke()
            case .line,.arrow,.pen:
                p.move(to: first); for point in mark.points.dropFirst() { p.line(to: point) }; p.stroke()
                if mark.tool == .arrow {
                    let angle = atan2(last.y-first.y,last.x-first.x), length = max(14,mark.width*4)
                    p.move(to: CGPoint(x: last.x-length*cos(angle-0.5),y: last.y-length*sin(angle-0.5))); p.line(to: last)
                    p.line(to: CGPoint(x: last.x-length*cos(angle+0.5),y: last.y-length*sin(angle+0.5))); p.stroke()
                }
            case .highlight: mark.color.withAlphaComponent(0.28).setFill(); mark.rect.fill()
            case .text:
                (mark.text as NSString).draw(at: first,withAttributes: [.font:NSFont.systemFont(ofSize: max(18,mark.width*6)),.foregroundColor:mark.color])
            case .number:
                let diameter = max(30,mark.width*9), rect = CGRect(x: first.x,y: first.y,width: diameter,height: diameter)
                NSBezierPath(ovalIn: rect).fill()
                let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.boldSystemFont(ofSize: diameter*0.6),.foregroundColor:NSColor.white]
                let size = (mark.text as NSString).size(withAttributes: attributes)
                (mark.text as NSString).draw(at: CGPoint(x: rect.midX-size.width/2,y: rect.midY-size.height/2),withAttributes: attributes)
            case .mosaic:
                guard let image = source else { continue }
                let rect = mark.rect.intersection(CGRect(x: 0,y: 0,width: image.width,height: image.height))
                if let crop = image.cropping(to: rect), let context = CGContext(data: nil,width: max(1,Int(rect.width/12)),height: max(1,Int(rect.height/12)),bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    context.draw(crop,in: CGRect(x: 0,y: 0,width: context.width,height: context.height))
                    if let low = context.makeImage() { NSImage(cgImage: low,size: rect.size).draw(in: rect,from: .zero,operation: .copy,fraction: 1,respectFlipped: true,hints: [.interpolation:NSImageInterpolation.none]) }
                }
            case .select: break
            }
        }
    }
    func rendered() throws -> CGImage {
        guard let image, let context = CGContext(data: nil,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ReShotError(message: "请先截图或导入图片。") }
        context.translateBy(x: 0,y: CGFloat(image.height)); context.scaleBy(x: 1,y: -1)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context,flipped: true)
        draw(); NSGraphicsContext.restoreGraphicsState()
        guard let result = context.makeImage() else { throw ReShotError(message: "标注渲染失败") }; return result
    }
}
