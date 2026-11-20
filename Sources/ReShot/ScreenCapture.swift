import AppKit

struct ScreenshotFrame {
    let image: CGImage
    let displayID: CGDirectDisplayID?
    let scale: CGFloat?
    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
}

enum CaptureGeometry {
    static func cgRect(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
    static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let x = floor(rect.minX * scale) / scale, y = floor(rect.minY * scale) / scale
        return CGRect(x: x, y: y, width: ceil(rect.maxX * scale) / scale - x, height: ceil(rect.maxY * scale) / scale - y)
    }
}

enum CaptureService {
    static func requirePermission() throws {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw ReShotError(message: "请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 ReShot，随后重新打开应用。")
        }
    }
    private static func screens() -> [(CGRect, CGDirectDisplayID, CGFloat)] {
        let read = { NSScreen.screens.map { ($0.frame, ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID(), $0.backingScaleFactor) } }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }
    static func region(_ rect: CGRect) throws -> ScreenshotFrame {
        let all = screens()
        guard let screen = all.first(where: { $0.0.contains(rect) }), let primary = all.first else { throw ReShotError(message: "请将截图区域限制在单个显示器内。") }
        let global = CaptureGeometry.cgRect(rect, primaryTop: primary.0.maxY)
        let aligned = CaptureGeometry.pixelAligned(global, scale: screen.2).intersection(CGDisplayBounds(screen.1))
        let image: CGImage
        if #available(macOS 14, *) { image = try ModernRegionCapture(region: aligned).image() }
        else {
            image = try fileCapture(["-R\(aligned.minX),\(aligned.minY),\(aligned.width),\(aligned.height)"])!
        }
        return ScreenshotFrame(image: image, displayID: screen.1, scale: screen.2)
    }
    static func fullScreen(at point: CGPoint) throws -> ScreenshotFrame {
        let all = screens()
        guard let screen = all.first(where: { $0.0.contains(point) }) ?? all.first else { throw ReShotError(message: "没有可用显示器。") }
        return try region(screen.0)
    }
    /// macOS supplies the window highlight, confirmation and Escape cancellation.
    static func window() throws -> ScreenshotFrame? {
        guard let image = try fileCapture(["-i", "-w", "-o"], interactive: true) else { return nil }
        return ScreenshotFrame(image: image, displayID: nil, scale: nil)
    }
    private static func fileCapture(_ arguments: [String], interactive: Bool = false) throws -> CGImage? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ReShot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-t", "png"] + arguments + [file.path]
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        if !FileManager.default.fileExists(atPath: file.path), interactive, process.terminationStatus <= 1 { return nil }
        guard process.terminationStatus == 0 else { throw ReShotError(message: "截图失败，请检查屏幕录制权限。") }
        return try ImageFiles.read(file)
    }
    static func selfTest() throws {
        let negative = CGRect(x: -1200, y: 150, width: 600, height: 300)
        guard CaptureGeometry.cgRect(negative, primaryTop: 900) == CGRect(x: -1200,y:450,width:600,height:300),
              CaptureGeometry.pixelAligned(CGRect(x: -0.2,y: 0.3,width: 10.3,height: 8.1),scale: 2) == CGRect(x:-0.5,y:0,width:11,height:8.5) else { throw ReShotError(message: "截图坐标测试失败") }
        print("PASS: negative display coordinates, vertical transform and outward Retina pixel alignment")
    }
}
