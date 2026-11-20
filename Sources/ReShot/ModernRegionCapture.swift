import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage

/// Reuses a filter/configuration across frames; own UI is excluded by the compositor.
@available(macOS 14.0, *)
final class ModernRegionCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let lock = NSCondition()
    private var latest: CGImage?
    private var sequence: UInt64 = 0
    private var streamError: Error?
    private let outputQueue = DispatchQueue(label: "local.reshot.frames", qos: .userInitiated)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    init(region: CGRect) throws {
        let ready = DispatchSemaphore(value: 0)
        var outcome: Result<SCShareableContent, Error>?
        SCShareableContent.getExcludingDesktopWindows(false,onScreenWindowsOnly: true) { content,error in
            if let content { outcome = .success(content) }
            else { outcome = .failure(error ?? ReShotError(message: "无法读取屏幕内容。")) }
            ready.signal()
        }
        guard ready.wait(timeout: .now()+8) == .success, let outcome else { throw ReShotError(message: "屏幕采集初始化超时。") }
        let content = try outcome.get()
        guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(region) }) else {
            throw ReShotError(message: "请在单个显示器内选择区域，重新启动 ReShot 后重试。")
        }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        filter = SCContentFilter(display: display,excludingApplications: own,exceptingWindows: [])
        configuration = SCStreamConfiguration()
        let bounds = CGDisplayBounds(display.displayID)
        configuration.sourceRect = region.offsetBy(dx: -bounds.minX,dy: -bounds.minY)
        configuration.width = Int((region.width*CGFloat(filter.pointPixelScale)).rounded())
        configuration.height = Int((region.height*CGFloat(filter.pointPixelScale)).rounded())
        configuration.showsCursor = false; configuration.capturesAudio = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        super.init()
    }
    /// Start once on a worker queue. Only the latest complete frame is retained.
    func startStream() throws {
        guard stream == nil else { return }
        let value = SCStream(filter: filter, configuration: configuration, delegate: self)
        try value.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        stream = value
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        value.startCapture { error in failure = error; ready.signal() }
        guard ready.wait(timeout: .now()+8) == .success else { stopStream(); throw ReShotError(message: "屏幕流启动超时。") }
        if let failure { stopStream(); throw failure }
    }
    func latestFrame(after previous: UInt64 = 0) throws -> (image: CGImage, sequence: UInt64)? {
        lock.lock(); defer { lock.unlock() }
        if let streamError { throw streamError }
        guard sequence > previous, let latest else { return nil }
        return (latest, sequence)
    }
    /// Use the same stream pixel/color pipeline for first, intermediate and final
    /// frames. Wait for a newer complete sample; idle content may reuse its last
    /// complete sample after the bounded wait (SCStream does not emit idle pixels).
    func streamFrame(after previous: UInt64, timeout: TimeInterval = 0.3) throws -> (image: CGImage,sequence: UInt64) {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        while (latest == nil || sequence <= previous) && streamError == nil && Date() < deadline {
            _ = lock.wait(until:deadline)
        }
        if let streamError { throw streamError }
        guard let latest else { throw ReShotError(message:"尚未收到完整屏幕帧，请重试。") }
        return (latest,sequence)
    }
    func stopStream() {
        if let stream { stream.stopCapture { _ in } }
        stream = nil
        lock.lock(); latest = nil; lock.unlock()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); streamError = error; lock.broadcast(); lock.unlock()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sampleBuffer.imageBuffer,
              let image = imageContext.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0,y: 0,width: CVPixelBufferGetWidth(buffer),height: CVPixelBufferGetHeight(buffer))) else { return }
        lock.lock(); latest = image; sequence &+= 1; lock.broadcast(); lock.unlock()
    }
    func image() throws -> CGImage {
        let ready = DispatchSemaphore(value: 0)
        var outcome: Result<CGImage, Error>?
        SCScreenshotManager.captureImage(contentFilter: filter,configuration: configuration) { image,error in
            if let image { outcome = .success(image) }
            else { outcome = .failure(error ?? ReShotError(message: "区域采集失败。")) }
            ready.signal()
        }
        guard ready.wait(timeout: .now()+5) == .success, let outcome else { throw ReShotError(message: "区域采集超时。") }
        return try outcome.get()
    }
}
