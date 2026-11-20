import AppKit

enum LongOCRTest {
    static func stitchFixture() throws {
        let image = try OCR.image(at: URL(fileURLWithPath: "dist/long-ocr-fixture.png"))
        let folder = URL(fileURLWithPath: "Tests/Fixtures/scroll-sequence", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let frames = [0, 900, 1800, 2700, 3600, 4100].map { image.cropping(to: CGRect(x: 0,y: $0,width: image.width,height: 1500))! }
        for (i, frame) in frames.enumerated() {
            try NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(String(format: "%03d.png",i+1)))
        }
        let result = try ScrollStitcher.stitch(frames)
        guard result.height == image.height else { throw ReShotError(message: "真实文字长图拼接高度不匹配") }
        func pixels(_ image: CGImage) -> [UInt8] {
            var values = [UInt8](repeating: 0, count: image.width*image.height*4)
            values.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
            }; return values
        }
        guard pixels(result) == pixels(image) else { throw ReShotError(message: "真实文字长图拼接像素不匹配") }
        try NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "dist/stitched-long.png"))
        print("PASS: six overlapping text screenshots → 1100×5600 long image, exact pixel identity")
    }
    static func run() throws {
        let width = 1100, height = 5600
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(x: 0,y: 0,width: width,height: height).fill()
        let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 46), .foregroundColor: NSColor.black]
        for i in 0..<18 {
            ("Section \(1000+i)" as NSString).draw(at: NSPoint(x: 60, y: height-100-i*300), withAttributes: style)
            ("截图文字识别" as NSString).draw(at: NSPoint(x: 60, y: height-165-i*300), withAttributes: style)
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "dist/long-ocr-fixture.png"))
        let result = try OCR.recognize(bitmap.cgImage!)
        print(result); fflush(stdout)
        for i in 0..<18 {
            guard result.components(separatedBy: "\n").filter({ $0.contains(String(1000+i)) }).count == 1 else { throw ReShotError(message: "长图 OCR 缺行或重复：\(1000+i)") }
        }
        guard result.components(separatedBy: "截图文字识别").count-1 == 18 else { throw ReShotError(message: "长图中不同位置的重复文字被误删或丢失") }
        print("PASS: 5600px long image, 18 numbered rows and 18 repeated Chinese lines, no tile duplicates or lost rows")
    }
}
