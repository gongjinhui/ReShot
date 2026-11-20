import AppKit

enum FeatureTests {
    static func annotations() throws {
        _ = NSApplication.shared
        let width = 400, height = 300
        var bytes = [UInt8](repeating: 255,count: width*height*4)
        for y in 0..<height { for x in 0..<width {
            let i = (y*width+x)*4; bytes[i] = UInt8(x%256); bytes[i+1] = UInt8(y%256); bytes[i+2] = UInt8((x+y)%256)
        } }
        let image = CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),provider: CGDataProvider(data: Data(bytes) as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
        func pixels(_ image: CGImage) -> Data {
            let c = CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image,in: CGRect(x: 0,y: 0,width: width,height: height)); return Data(bytes: c.data!,count: width*height*4)
        }
        let doc = AnnotationDocument(); doc.reset(image)
        let original = pixels(image)
        guard pixels(try doc.rendered()) == original else { throw ReShotError(message: "导出图像方向或原始像素发生变化") }
        for tool in MarkTool.allCases where tool != .select {
            doc.reset(image); doc.checkpoint()
            doc.marks.append(Mark(tool: tool,points: [CGPoint(x: 40,y: 40),CGPoint(x: 180,y: 150)],color: .red,width: 6,text: tool == .number ? "1" : "测试"))
            let rendered = try doc.rendered()
            guard pixels(rendered) != original, rendered.width == width, rendered.height == height else { throw ReShotError(message: "标注未写入导出："+tool.rawValue) }
            doc.undo(); guard doc.marks.isEmpty else { throw ReShotError(message: "撤销失败") }
            doc.redo(); guard doc.marks.count == 1 else { throw ReShotError(message: "重做失败") }
        }
        doc.reset(image)
        doc.marks = [Mark(tool: .arrow,points: [CGPoint(x: 30,y: 40),CGPoint(x: 220,y: 80)],color: .red,width: 6),Mark(tool: .text,points: [CGPoint(x: 40,y: 160)],color: .white,width: 5,text: "ReShot 标注")]
        try ImageFiles.png(doc.rendered()).write(to: URL(fileURLWithPath: "dist/annotation-test.png"))
        print("PASS: original pixel identity, all nine annotation exports, undo/redo, original dimensions")
    }
    static func ocr() throws {
        _ = NSApplication.shared
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: 1200,pixelsHigh: 4600,bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 0,bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); CGRect(x: 0,y: 0,width: 1200,height: 4600).fill()
        for i in 0..<12 {
            ("ReShot Section \(1000+i) 截图识字" as NSString).draw(at: CGPoint(x: 40,y: 4480-i*370),withAttributes: [.font:NSFont.systemFont(ofSize: 48),.foregroundColor:NSColor.black])
        }
        for y in [2700,1050] {
            ("Same paragraph 重复段落" as NSString).draw(at: CGPoint(x: 40,y: y),withAttributes: [.font:NSFont.systemFont(ofSize: 48),.foregroundColor:NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        let result = try OCR.recognize(bitmap.cgImage!)
        guard result.components(separatedBy: "\n").filter({ $0.contains("Same paragraph") }).count == 2 else { throw ReShotError(message: "不同位置的重复段落被删除") }
        let blank = CGContext(data: nil,width: 300,height: 300,bitsPerComponent: 8,bytesPerRow: 1200,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        blank.setFillColor(CGColor(gray: 1,alpha: 1)); blank.fill(CGRect(x: 0,y: 0,width: 300,height: 300))
        guard try OCR.recognize(blank.makeImage()!).isEmpty else { throw ReShotError(message: "空白图片识别结果应为空") }
        for i in 0..<12 { guard result.components(separatedBy: "\n").filter({$0.contains(String(1000+i))}).count == 1 else { throw ReShotError(message: "长图识字漏行或重复") } }
        guard result.contains("截图识字") else { throw ReShotError(message: "中文识别失败") }
        var progress: [Double] = []
        let document = try OCR.analyze(bitmap.cgImage!,progress: { progress.append($0) })
        guard progress.last == 1, zip(progress,progress.dropFirst()).allSatisfy({ $0 <= $1 }),
              document.blocks.allSatisfy({ $0.rect.minY >= 0 && $0.rect.maxY <= 4600 && $0.confidence >= 0 }) else { throw ReShotError(message: "OCR 坐标或进度错误") }
        let job = OCR.Job(); job.cancel()
        do { _ = try OCR.analyze(bitmap.cgImage!,job: job); throw ReShotError(message: "OCR 取消未生效") }
        catch is CancellationError { }
        let ordered = OCR.ordered([
            OCR.Block(text: "重复",rect: CGRect(x: 100,y: 300,width: 80,height: 20),confidence: 1),
            OCR.Block(text: "右",rect: CGRect(x: 200,y: 10,width: 80,height: 20),confidence: 1),
            OCR.Block(text: "重复",rect: CGRect(x: 0,y: 10,width: 80,height: 20),confidence: 1)])
        guard ordered.text == "重复\n右\n重复" else { throw ReShotError(message: "OCR 阅读顺序或重复文字错误") }
        print(result); print("PASS: long Chinese/English OCR, unique tile seams, pixel coordinates, progress, cancellation and reading order")
    }
}
