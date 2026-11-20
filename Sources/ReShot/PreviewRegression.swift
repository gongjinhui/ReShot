import AppKit

enum PreviewRegression {
    static func run() throws {
        _ = NSApplication.shared
        let width = 400, height = 1800
        var bytes = [UInt8](repeating: 255,count: width*height*4)
        for y in 0..<height { for x in 0..<width {
            let i = (y*width+x)*4
            bytes[i] = y < 900 ? 230 : 30
            bytes[i+1] = 40
            bytes[i+2] = y < 900 ? 30 : 230
        } }
        let image = CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,
            space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
        func require(_ condition: Bool,_ message: String) throws { if !condition { throw ReShotError(message: "预览回归失败："+message) } }
        func render(_ preview: ImagePreview,_ name: String, coloredImage: Bool = true) throws {
            preview.layoutSubtreeIfNeeded(); preview.displayIfNeeded()
            guard let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) else { throw ReShotError(message: "无法渲染预览") }
            preview.cacheDisplay(in: preview.bounds,to: bitmap)
            var colored = 0
            for y in stride(from: 20,to: bitmap.pixelsHigh-20,by: 3) { for x in stride(from: 20,to: bitmap.pixelsWide-20,by: 3) {
                if let color = bitmap.colorAt(x: x,y: y)?.usingColorSpace(.deviceRGB), (coloredImage ? abs(color.redComponent-color.blueComponent) > 0.4 : max(color.redComponent,max(color.greenComponent,color.blueComponent)) < 0.3) { colored += 1 }
            } }
            try require(colored > 50,"预览应绘制图片像素，不能只有空白背景："+name)
            try bitmap.representation(using: .png,properties: [:])!.write(to: URL(fileURLWithPath: "dist/\(name).png"))
        }
        // Exercise the real hidden-window completion path used by screenshot/paste/stitch.
        let suite = "ReShot-preview-" + UUID().uuidString
        let app = AppDelegate()
        app.settingsDefaults = UserDefaults(suiteName: suite)!
        defer { app.settingsDefaults.removePersistentDomain(forName: suite) }
        app.buildWindow(); app.window.appearance = NSAppearance(named: .aqua); app.window.setContentSize(NSSize(width: 1000,height: 800))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ReShot-preview-\(UUID().uuidString).png")
        try ImageFiles.png(image).write(to: temporary)
        let captured = try ImageFiles.read(temporary)
        try FileManager.default.removeItem(at: temporary)
        try require(!FileManager.default.fileExists(atPath: temporary.path),"截图临时文件应已删除")
        app.setImage(captured); app.window.contentView?.layoutSubtreeIfNeeded(); app.updatePreview(resetPosition: true)
        try render(app.imageScroll,"preview-width-regression")
        guard let document = app.imageScroll.documentView else { throw ReShotError(message: "预览缺少画布") }
        try require(document.frame.height > app.imageScroll.contentSize.height,"长图应支持滚动")
        try require(app.imageScroll.contentView.bounds.minY == 0,"长图应从顶部显示")
        app.fitsWholeImage = true
        try render(app.imageScroll,"preview-fit-regression")
        try require(document.frame.height <= app.imageScroll.contentSize.height+1,"整图模式应可见完整图片")
        app.window.setContentSize(NSSize(width: 1200,height: 900)); app.window.contentView?.layoutSubtreeIfNeeded(); app.updatePreview(resetPosition: false)
        try render(app.imageScroll,"preview-resize-regression")
        let board = NSPasteboard(name: NSPasteboard.Name("ReShot-regression-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        for type in [NSPasteboard.PasteboardType.png,.tiff] {
            board.clearContents()
            let bitmap = NSBitmapImageRep(cgImage: image)
            let data = type == .png ? bitmap.representation(using: .png,properties: [:])! : bitmap.tiffRepresentation!
            board.setData(data,forType: type)
            guard let pasted = ClipboardImages.read(board) else { throw ReShotError(message: "未读出剪贴板图片") }
            app.setImage(pasted); try render(app.imageScroll,"preview-paste-\(type == .png ? "png" : "tiff")")
        }
        let urls = (1...6).map { URL(fileURLWithPath: String(format: "Tests/Fixtures/scroll-sequence/%03d.png",$0)) }
        let frames = try urls.map { source -> CGImage in
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ReShot-frame-\(UUID().uuidString).png")
            try Data(contentsOf: source).write(to: temporary)
            let decoded = try ImageFiles.read(temporary)
            try FileManager.default.removeItem(at: temporary)
            return decoded
        }
        let stitched = try ScrollStitcher.stitch(frames)
        app.fitsWholeImage = false; app.setImage(stitched)
        try require(app.imageScroll.displayedImage?.height == 5600,"合并结果应进入预览")
        try render(app.imageScroll,"preview-stitched-regression",coloredImage: false)
        print("PASS: deleted temporary screenshot and scroll frames render correctly; full-window preview, width/whole/resize, PNG/TIFF paste, and 5600px stitched result")
    }
}
