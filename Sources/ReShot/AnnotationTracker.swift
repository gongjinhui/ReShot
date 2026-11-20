import AppKit

/// Tracks the captured content under each annotation, independently of the
/// mouse wheel's acceleration or a fixed header elsewhere in the viewport.
final class AnnotationTracker {
    struct Raster {
        let width: Int
        let height: Int
        let pixels: [UInt8]
        init(_ image: CGImage) throws {
            width = image.width; height = image.height
            guard let context = CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width,space: CGColorSpaceCreateDeviceGray(),bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                throw ReShotError(message: "无法读取标注目标画面。")
            }
            context.draw(image,in: CGRect(x: 0,y: 0,width: width,height: height))
            pixels = Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),count: width*height))
        }
    }
    private struct Feature { let x: Int; let y: Int; let value: Int }
    private struct Anchor {
        var x: Int
        var y: Int
        let features: [Feature]
        let textured: Bool
    }
    private var anchors: [UUID:Anchor] = [:]
    private var previous: Raster?
    func reset() { anchors.removeAll(); previous = nil }
    func follow(_ marks: [Mark],in frame: Raster,pointSize: CGSize) -> [Mark] {
        defer { previous = frame }
        let sx = CGFloat(frame.width)/pointSize.width, sy = CGFloat(frame.height)/pointSize.height
        let viewport = CGRect(origin: .zero,size: pointSize)
        var kept: [Mark] = [], next: [UUID:Anchor] = [:]
        for var mark in marks {
            guard var anchor = anchors[mark.id] else {
                let patch = CGRect(x: mark.rect.minX*sx,y: mark.rect.minY*sy,width: mark.rect.width*sx,height: mark.rect.height*sy).insetBy(dx: -max(8,24*sx),dy: -max(8,24*sy))
                let found = makeAnchor(patch,frame: frame)
                kept.append(mark); next[mark.id] = found; continue
            }
            let offset: (Int,Int)?
            if anchor.textured { offset = locate(anchor,in: frame) }
            else { offset = sceneChanged(frame) ? nil : (0,0) }
            guard let (dx,dy) = offset else { continue }
            mark.points = mark.points.map { CGPoint(x: $0.x+CGFloat(dx)/sx,y: $0.y+CGFloat(dy)/sy) }
            guard mark.rect.intersects(viewport) else { continue }
            anchor.x += dx; anchor.y += dy
            kept.append(mark); next[mark.id] = anchor
        }
        anchors = next
        return kept
    }
    private func makeAnchor(_ patch: CGRect,frame: Raster) -> Anchor {
        let box = patch.integral.intersection(CGRect(x: 1,y: 1,width: frame.width-2,height: frame.height-2))
        let x = max(1,Int(box.minX)), y = max(1,Int(box.minY))
        let w = max(1,Int(box.width)), h = max(1,Int(box.height))
        var candidates: [(Feature,Int)] = []
        let step = max(1,Int(sqrt(Double(w*h)/600)))
        for py in stride(from: y,to: min(frame.height-1,y+h),by: step) {
            for px in stride(from: x,to: min(frame.width-1,x+w),by: step) {
                let i = py*frame.width+px, value = Int(frame.pixels[i])
                let contrast = max(abs(value-Int(frame.pixels[i+1])),abs(value-Int(frame.pixels[i+frame.width])))
                candidates.append((Feature(x: px-x,y: py-y,value: value),contrast))
            }
        }
        let edges = candidates.filter { $0.1 >= 12 }
        let textured = edges.count >= 12
        let source = textured ? edges : candidates
        let interval = max(1,source.count/128)
        let features = stride(from: 0,to: source.count,by: interval).prefix(160).map { source[$0].0 }
        return Anchor(x: x,y: y,features: features,textured: textured)
    }
    private func score(_ anchor: Anchor,dx: Int,dy: Int,in frame: Raster) -> Double {
        var sum = 0, count = 0
        for feature in anchor.features {
            let x = anchor.x+feature.x+dx, y = anchor.y+feature.y+dy
            if x >= 0, x < frame.width, y >= 0, y < frame.height {
                sum += min(60,abs(feature.value-Int(frame.pixels[y*frame.width+x]))); count += 1
            }
        }
        guard count >= max(8,anchor.features.count*2/3) else { return .infinity }
        return Double(sum)/Double(count)
    }
    private func locate(_ anchor: Anchor,in frame: Raster) -> (Int,Int)? {
        if score(anchor,dx: 0,dy: 0,in: frame) < 1.5 { return (0,0) }
        var best = (x: 0,y: 0,value: Double.infinity)
        var candidates: [(x: Int,y: Int,value: Double)] = []
        let limit = max(4,frame.height*2/3)
        func consider(_ x: Int,_ y: Int) {
            let value = score(anchor,dx: x,dy: y,in: frame)
            candidates.append((x,y,value))
            if value < best.value { best = (x,y,value) }
        }
        for y in stride(from: -limit,through: limit,by: 1) { consider(0,y) }
        if best.value > 10 {
            for x in stride(from: -24,through: 24,by: 4) where x != 0 {
                for y in stride(from: -limit,through: limit,by: 4) { consider(x,y) }
            }
        }
        let coarse = best
        for x in (coarse.x-3)...(coarse.x+3) {
            for y in (coarse.y-3)...(coarse.y+3) { consider(x,y) }
        }
        guard best.value < 12 else { return nil }
        let alternatives = candidates.filter { abs($0.x-best.x)+abs($0.y-best.y) > 4 }
        if let second = alternatives.map(\.value).min(), second <= best.value*1.15+0.5 { return nil }
        return (best.x,best.y)
    }
    private func sceneChanged(_ frame: Raster) -> Bool {
        guard let previous, previous.width == frame.width, previous.height == frame.height else { return true }
        var difference = 0, count = 0
        for i in stride(from: 0,to: frame.pixels.count,by: 31) {
            difference += abs(Int(frame.pixels[i])-Int(previous.pixels[i])); count += 1
        }
        return Double(difference)/Double(max(1,count)) > 8
    }
    static func selfTest() throws {
        let width = 160, height = 120
        func frame(offset: Int,changed: Bool = false) throws -> Raster {
            var pixels = [UInt8](repeating: 255,count: width*height*4)
            for y in 0..<height { for x in 0..<width {
                let world = y+offset
                let value = changed ? (x*13+y*37+93)%255 : (x*31+world*73+(x*world)%97)%255
                let i = (y*width+x)*4
                pixels[i] = UInt8(value); pixels[i+1] = UInt8(value); pixels[i+2] = UInt8(value)
            } }
            let image = CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),provider: CGDataProvider(data: Data(pixels) as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
            return try Raster(image)
        }
        let tracker = AnnotationTracker(), size = CGSize(width: width,height: height)
        let mark = Mark(tool: .rectangle,points: [CGPoint(x: 60,y: 50),CGPoint(x: 90,y: 70)],color: .red,width: 2)
        var marks = tracker.follow([mark],in: try frame(offset: 0),pointSize: size)
        marks = tracker.follow(marks,in: try frame(offset: 20),pointSize: size)
        guard marks.count == 1, abs(marks[0].rect.minY-30) < 1 else { throw ReShotError(message: "标注没有随内容向上滚动") }
        marks = tracker.follow(marks,in: try frame(offset: 11),pointSize: size)
        guard marks.count == 1, abs(marks[0].rect.minY-39) < 1 else { throw ReShotError(message: "回滚后标注位置错误") }
        marks = tracker.follow(marks,in: try frame(offset: 11,changed: true),pointSize: size)
        guard marks.isEmpty else { throw ReShotError(message: "目标消失后标注仍留在屏幕") }
        tracker.reset()
        marks = tracker.follow([mark],in: try frame(offset: 0),pointSize: size)
        marks = tracker.follow(marks,in: try frame(offset: 70),pointSize: size)
        guard marks.isEmpty else { throw ReShotError(message: "目标滚出视口后标注未消失") }
        let document = AnnotationDocument()
        document.checkpoint(); document.marks = [mark]
        var moved = mark; moved.points = moved.points.map { CGPoint(x: $0.x,y: $0.y-20) }
        document.replaceTrackedMarks([moved])
        document.undo(); document.redo()
        guard document.marks.first?.points == moved.points else { throw ReShotError(message: "跟随滚动后重做恢复到了旧位置") }
        document.replaceTrackedMarks([]); document.undo(); document.redo()
        guard document.marks.isEmpty else { throw ReShotError(message: "撤销重做恢复了已经消失的目标") }
        print("PASS: content-anchored annotations, upward scroll, rollback, scene replacement, offscreen removal and aligned undo/redo")
    }
}
