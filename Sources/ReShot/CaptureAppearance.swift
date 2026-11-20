import AppKit

enum CaptureAppearance {
    static let defaultRadius: CGFloat = 10
    private static let key = "captureCornerRadiusPoints"
    static func radius(in defaults: UserDefaults = .standard) -> CGFloat {
        guard let number = defaults.object(forKey: key) as? NSNumber, number.doubleValue.isFinite else { return defaultRadius }
        return min(100,max(0,CGFloat(number.doubleValue)))
    }
    static func setRadius(_ value: CGFloat, in defaults: UserDefaults = .standard) {
        defaults.set(Double(value.isFinite ? min(100,max(0,value)) : defaultRadius),forKey: key)
    }
    static func pixelRadius(points: CGFloat, scale: CGFloat, size: CGSize) -> CGFloat {
        let value = points.isFinite ? max(0,points) : defaultRadius
        let scale = scale.isFinite && scale > 0 ? scale : 1
        return min(value*scale,max(0,min(size.width,size.height)/2))
    }
    /// Mask only the outside corners after annotations or stitching are complete.
    /// The PNG keeps its dimensions; the four discarded corners are transparent.
    static func rounded(_ image: CGImage, points: CGFloat = CaptureAppearance.radius(), scale: CGFloat = 1) throws -> CGImage {
        let size = CGSize(width: image.width,height: image.height)
        let radius = pixelRadius(points: points,scale: scale,size: size)
        guard radius > 0 else { return image }
        guard let context = CGContext(data: nil,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width*4,space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ReShotError(message: "无法生成圆角截图。") }
        let rect = CGRect(origin: .zero,size: size)
        context.addPath(CGPath(roundedRect: rect,cornerWidth: radius,cornerHeight: radius,transform: nil)); context.clip()
        context.draw(image,in: rect)
        guard let result = context.makeImage() else { throw ReShotError(message: "圆角图片生成失败。") }
        return result
    }
    static func selfTest() throws {
        let suite = "ReShot-appearance-test-"+UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        guard radius(in: defaults) == 10 else { throw ReShotError(message: "圆角默认值应为 10pt") }
        setRadius(24,in: defaults)
        guard radius(in: UserDefaults(suiteName: suite)!) == 24 else { throw ReShotError(message: "圆角设置未持久化") }
        setRadius(0,in: defaults); guard radius(in: defaults) == 0 else { throw ReShotError(message: "无法关闭圆角") }
        let context = CGContext(data: nil,width: 120,height: 400,bitsPerComponent: 8,bytesPerRow: 480,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2,green: 0.8,blue: 0.3,alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: 120,height: 400))
        let original = context.makeImage()!
        let retina = try rounded(original,points: 10,scale: 2), standard = try rounded(original,points: 10,scale: 1)
        let decoded = try ImageFiles.read(CaptureStorage.save(ImageFiles.png(retina),folder: FileManager.default.temporaryDirectory.appendingPathComponent(suite)))
        defer { try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(suite)) }
        let bitmap = NSBitmapImageRep(cgImage: decoded)
        for (x,y) in [(0,0),(119,0),(0,399),(119,399)] {
            guard bitmap.colorAt(x: x,y: y)!.alphaComponent == 0 else { throw ReShotError(message: "PNG 四角应透明") }
        }
        guard bitmap.pixelsWide == 120, bitmap.pixelsHigh == 400,
              bitmap.colorAt(x: 60,y: 200)!.alphaComponent == 1,
              bitmap.colorAt(x: 0,y: 200)!.alphaComponent == 1,
              bitmap.colorAt(x: 5,y: 5)!.alphaComponent < 0.1,
              NSBitmapImageRep(cgImage: standard).colorAt(x: 5,y: 5)!.alphaComponent > 0.9,
              try rounded(original,points: 0) === original,
              pixelRadius(points: 100,scale: 2,size: CGSize(width: 20,height: 50)) == 10 else { throw ReShotError(message: "圆角尺寸、Retina 换算或直角模式错误") }
        let frames = try (1...6).map { try ImageFiles.read(URL(fileURLWithPath: String(format: "Tests/Fixtures/scroll-sequence/%03d.png",$0))) }
        let merged = try ScrollStitcher.stitch(frames)
        let long = try rounded(merged,points: 10,scale: 2)
        let longBitmap = NSBitmapImageRep(cgImage: long), mergedBitmap = NSBitmapImageRep(cgImage: merged)
        guard long.height == 5600, long.width == merged.width,
              longBitmap.colorAt(x: 0,y: 0)!.alphaComponent == 0,
              longBitmap.colorAt(x: long.width-1,y: long.height-1)!.alphaComponent == 0,
              longBitmap.colorAt(x: long.width/2,y: long.height/2) == mergedBitmap.colorAt(x: merged.width/2,y: merged.height/2) else { throw ReShotError(message: "合成长图圆角处理破坏了尺寸或正文像素") }
        try ImageFiles.png(long).write(to: URL(fileURLWithPath: "dist/rounded-long-regression.png"))
        print("PASS: six-frame 5600px stitched image rounded after merging, preserved content; default 10pt, persisted custom/zero radius, Retina point conversion, transparent PNG corners, long-image edges and dimensions, small-image clamp")
    }
}
