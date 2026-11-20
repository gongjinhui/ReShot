import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit

/// Uses a monotonic clock; paused time never advances the movie timeline.
struct RecordingClock {
    private var accumulated: TimeInterval = 0
    private var began: UInt64?
    private var segments: [(start: UInt64,end: UInt64,offset: TimeInterval)] = []
    mutating func resume(at now: UInt64) { if began == nil { began = now } }
    mutating func pause(at now: UInt64) {
        if let began { segments.append((began,now,accumulated)) }
        accumulated = elapsed(at: now); began = nil
    }
    func audioTime(at host: UInt64) -> (time: TimeInterval,remaining: TimeInterval)? {
        if let began, host >= began { return (accumulated+Double(host-began)/1_000_000_000,.infinity) }
        for segment in segments.reversed() where host >= segment.start && host < segment.end {
            return (segment.offset+Double(host-segment.start)/1_000_000_000,Double(segment.end-host)/1_000_000_000)
        }
        return nil
    }
    func elapsed(at now: UInt64) -> TimeInterval {
        accumulated + (began.map { Double(now >= $0 ? now-$0 : 0)/1_000_000_000 } ?? 0)
    }
}

/// One writer owned by the capture queue. Only a successfully finished movie is
/// renamed to the visible output path; both paths use the chosen image folder.
final class RecordingMovie {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var audioInput: AVAssetWriterInput?
    private let temporary: URL
    private let final: URL
    private var lastTime: CMTime?
    private lazy var compositor = CIContext(options: [.cacheIntermediates: false])
    init(folder: URL,width: Int,height: Int,audio: Bool = false) throws {
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        let id = UUID().uuidString
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":",with: "-")
        temporary = folder.appendingPathComponent(".ReShot-recording-"+id+".mp4")
        final = folder.appendingPathComponent("ReShot-"+stamp+"-"+id+".mp4")
        writer = try AVAssetWriter(outputURL: temporary,fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let bitRate = max(500_000,min(32_000_000,width*height*3))
        input = AVAssetWriterInput(mediaType: .video,outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate, AVVideoExpectedSourceFrameRateKey: 30]
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(input) else { throw ReShotError(message: "无法配置 MP4 视频编码。") }
        writer.add(input)
        if audio {
            let audio = AVAssetWriterInput(mediaType: .audio,outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,AVSampleRateKey: 48_000,AVNumberOfChannelsKey: 2,AVEncoderBitRateKey: 192_000])
            audio.expectsMediaDataInRealTime = true
            guard writer.canAdd(audio) else { throw ReShotError(message: "无法配置 AAC 录屏音频。") }
            writer.add(audio); audioInput = audio
        }
        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: temporary)
            throw writer.error ?? ReShotError(message: "无法开始写入录屏。")
        }
        writer.startSession(atSourceTime: .zero)
    }
    @discardableResult func append(_ buffer: CVPixelBuffer,elapsed: TimeInterval,overlay: CIImage? = nil) throws -> Bool {
        guard writer.status == .writing else { throw writer.error ?? ReShotError(message: "录屏写入已停止。") }
        guard input.isReadyForMoreMediaData else { return false }
        let time = lastTime == nil ? .zero : CMTime(seconds: elapsed,preferredTimescale: 60_000)
        if let lastTime, time <= lastTime { return false }
        let frame: CVPixelBuffer
        if let overlay {
            var composited: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,pool,&composited) == kCVReturnSuccess,
                  let composited else { throw ReShotError(message: "无法分配带标注的视频帧。") }
            let background = CIImage(cvPixelBuffer: buffer)
            compositor.render(overlay.composited(over: background),to: composited,bounds: background.extent,colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            frame = composited
        } else { frame = buffer }
        guard adaptor.append(frame,withPresentationTime: time) else { throw writer.error ?? ReShotError(message: "视频帧写入失败。") }
        lastTime = time; return true
    }
    @discardableResult func appendAudio(_ sample: CMSampleBuffer) throws -> Bool {
        guard writer.status == .writing, let audioInput else { throw writer.error ?? ReShotError(message: "录屏音频编码器不可用。") }
        guard audioInput.isReadyForMoreMediaData else { return false }
        guard audioInput.append(sample) else { throw writer.error ?? ReShotError(message: "录屏音频写入失败。") }
        return true
    }
    func discard() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: temporary)
    }
    func finish(elapsed: TimeInterval,completion: @escaping (Result<URL,Error>) -> Void) {
        guard let lastTime, writer.status == .writing else {
            let error = writer.error ?? ReShotError(message: "未录到有效画面。")
            discard(); completion(.failure(error)); return
        }
        let end = CMTimeMaximum(CMTime(seconds: elapsed,preferredTimescale: 60_000),lastTime + CMTime(value: 1,timescale: 30))
        writer.endSession(atSourceTime: end); input.markAsFinished(); audioInput?.markAsFinished()
        writer.finishWriting { [self] in
            guard writer.status == .completed else {
                let error = writer.error ?? ReShotError(message: "无法完成 MP4 文件。")
                discard(); completion(.failure(error)); return
            }
            do { try FileManager.default.moveItem(at: temporary,to: final); completion(.success(final)) }
            catch { completion(.failure(ReShotError(message: "影片已编码，但无法移动到最终文件名。可从此处取回：\(temporary.path)\n\(error.localizedDescription)"))) }
        }
    }

    static func selfTest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReShot-recording-test-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        func frame(blue: UInt8,red: UInt8) -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault,96,64,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,&buffer)
            let pixel = buffer!
            CVPixelBufferLockBaseAddress(pixel,[])
            let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<64 { for x in 0..<96 {
                let i = y*CVPixelBufferGetBytesPerRow(pixel)+x*4; base[i] = blue; base[i+1] = 0; base[i+2] = red; base[i+3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pixel,[]); return pixel
        }
        let red = frame(blue: 0,red: 255), blue = frame(blue: 255,red: 0)
        var clock = RecordingClock(); clock.resume(at: 0)
        let movie = try RecordingMovie(folder: folder,width: 96,height: 64)
        func write(_ frame: CVPixelBuffer,_ elapsed: TimeInterval,overlay: CIImage? = nil) throws {
            let deadline = Date().addingTimeInterval(2)
            while try !movie.append(frame,elapsed: elapsed,overlay: overlay) {
                guard Date() < deadline else { throw ReShotError(message: "测试视频编码超时") }; Thread.sleep(forTimeInterval: 0.005)
            }
        }
        for i in 0..<30 { try write(red,clock.elapsed(at: UInt64(i)*1_000_000_000/30)) }
        clock.pause(at: 1_000_000_000)
        guard clock.elapsed(at: 8_000_000_000) == 1 else { throw ReShotError(message: "暂停时长进入了影片时间轴") }
        clock.resume(at: 8_000_000_000)
        let line = Mark(tool: .line,points: [CGPoint(x: 5,y: 6),CGPoint(x: 18,y: 6)],color: .green,width: 3)
        let overlay = try RecordingAnnotations.render([line],pointSize: CGSize(width: 48,height: 32),width: 96,height: 64)
        for i in 0..<30 { try write(blue,clock.elapsed(at: 8_000_000_000+UInt64(i)*1_000_000_000/30),overlay: overlay) }
        clock.pause(at: 9_000_000_000)
        guard clock.elapsed(at: 9_000_000_000) == 2 else { throw ReShotError(message: "继续录制的时间轴错误") }
        let done = DispatchSemaphore(value: 0); var result: Result<URL,Error>?
        movie.finish(elapsed: clock.elapsed(at: 9_000_000_000)) { result = $0; done.signal() }
        guard done.wait(timeout: .now()+15) == .success, let result else { throw ReShotError(message: "测试视频写入超时") }
        let url = try result.get()
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == folder.resolvingSymlinksInPath().standardizedFileURL.path,
              url.pathExtension == "mp4", files.filter({ $0.hasSuffix(".mp4") }) == [url.lastPathComponent] else {
            throw ReShotError(message: "录屏未正确写入目标目录：目标 \(folder.path)，影片 \(url.path)，文件 \(files)")
        }
        let read = DispatchSemaphore(value: 0); var check: Result<Void,Error>?
        Task.detached {
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first, abs(CMTimeGetSeconds(duration)-2) < 0.12 else { throw ReShotError(message: "MP4 时长不等于两段实际录制时长") }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track,outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(output); guard reader.startReading() else { throw reader.error ?? ReShotError(message: "MP4 无法解码") }
                var count = 0, firstRed = false, lastBlue = false, lastMark = false
                while let sample = output.copyNextSampleBuffer(), let image = sample.imageBuffer {
                    CVPixelBufferLockBaseAddress(image,.readOnly)
                    let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
                    if count == 0 { firstRed = bytes[2] > 180 && bytes[0] < 50 }
                    lastBlue = bytes[0] > 180 && bytes[2] < 50
                    let stride = CVPixelBufferGetBytesPerRow(image)
                    let mark = 12*stride+20*4, mirrored = 51*stride+20*4
                    lastMark = bytes[mark+1] > 170 && bytes[mirrored] > 180
                    CVPixelBufferUnlockBaseAddress(image,.readOnly); count += 1
                }
                guard reader.status == .completed, count == 60, firstRed, lastBlue, lastMark else { throw ReShotError(message: "MP4 画面未完整保留") }
                check = .success(())
            } catch { check = .failure(error) }
            read.signal()
        }
        guard read.wait(timeout: .now()+15) == .success, let check else { throw ReShotError(message: "测试视频解码超时") }
        try check.get()
        print("PASS: pause-free timeline, playable H.264 MP4, 60 decoded frames, start/end pixels, scaled annotations at correct location, output folder and atomic finalization")
    }
}

final class ScreenRecording: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    enum Phase { case preparing, recording, paused, finishing, finished }
    struct Outcome { let url: URL; let interruption: Error? }
    var completion: ((Result<Outcome,Error>) -> Void)?
    private(set) var visiblePhase: Phase = .preparing  // main queue
    private let queue = DispatchQueue(label: "local.reshot.recording",qos: .userInitiated)
    private var phase: Phase = .preparing  // capture queue
    private var stream: SCStream?
    private var movie: RecordingMovie?
    private var microphone: AVCaptureSession?
    private let microphoneControl = DispatchQueue(label: "local.reshot.microphone")
    private let audio = RecordingAudio()
    private var latest: CVPixelBuffer?
    private var timer: DispatchSourceTimer?
    private var clock = RecordingClock()
    private var shownSecond = -1
    private var panel: NSPanel?
    private var annotations: RecordingAnnotations?
    private let label = NSTextField(labelWithString: "正在准备录屏…")
    private let pauseButton = NSButton(title: "暂停",target: nil,action: nil)
    private let stopButton = NSButton()
    private let cancelButton = NSButton()

    func start(area: CGRect,folder: URL) {
        let access = AVCaptureDevice.authorizationStatus(for: .audio)
        if access == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.start(area: area,folder: folder) }
                    else { self.completion?(.failure(ReShotError(message: "请在系统设置的麦克风权限中允许 ReShot。"))) }
                }
            }
            return
        }
        guard access == .authorized else { completion?(.failure(ReShotError(message: "请在系统设置 → 隐私与安全性 → 麦克风中允许 ReShot。"))); return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(area) }),
              let primary = NSScreen.screens.first,
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            completion?(.failure(ReShotError(message: "请选择同一显示器内的录屏区域。"))); return
        }
        let scale = screen.backingScaleFactor
        let region = CaptureGeometry.pixelAligned(CaptureGeometry.cgRect(area,primaryTop: primary.frame.maxY),scale: scale).intersection(CGDisplayBounds(id))
        guard !region.isNull, region.width > 0, region.height > 0 else {
            completion?(.failure(ReShotError(message: "录屏区域已失效，请重新框选。"))); return
        }
        let alignedArea = CGRect(x: region.minX,y: primary.frame.maxY-region.maxY,width: region.width,height: region.height)
        let annotations = RecordingAnnotations(area: alignedArea)
        self.annotations = annotations
        annotations.show()
        showControls(on: screen,area: alignedArea,toolbar: annotations.toolbar)
        SCShareableContent.getExcludingDesktopWindows(false,onScreenWindowsOnly: false) { [weak self] content,error in
            guard let self else { return }
            self.queue.async { [self] in
                guard self.phase == .preparing else { return }
                do {
                    guard let content, let display = content.displays.first(where: { $0.displayID == id }) else { throw error ?? ReShotError(message: "无法访问录屏显示器。") }
                    let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                    let filter = SCContentFilter(display: display,excludingApplications: own,exceptingWindows: [])
                    let config = SCStreamConfiguration(), bounds = CGDisplayBounds(id)
                    config.sourceRect = region.offsetBy(dx: -bounds.minX,dy: -bounds.minY)
                    let factor = min(scale,4096/max(region.width,region.height),sqrt(8_847_360/(region.width*region.height)))
                    config.width = max(2,Int(region.width*factor)/2*2); config.height = max(2,Int(region.height*factor)/2*2)
                    config.pixelFormat = kCVPixelFormatType_32BGRA; config.colorSpaceName = CGColorSpace.sRGB
                    config.minimumFrameInterval = CMTime(value: 1,timescale: 30); config.queueDepth = 4
                    config.showsCursor = true; config.capturesAudio = true
                    config.excludesCurrentProcessAudio = true; config.sampleRate = 48_000; config.channelCount = 2
                    self.movie = try RecordingMovie(folder: folder,width: config.width,height: config.height,audio: true)
                    let stream = SCStream(filter: filter,configuration: config,delegate: self)
                    try stream.addStreamOutput(self,type: .screen,sampleHandlerQueue: self.queue)
                    try stream.addStreamOutput(self,type: .audio,sampleHandlerQueue: self.queue)
                    self.stream = stream
                    try self.startMicrophone()
                    stream.startCapture { [weak self, weak stream] error in
                        guard let self else { stream?.stopCapture { _ in }; return }
                        self.queue.async {
                            if self.phase == .finished || self.phase == .finishing { stream?.stopCapture { _ in }; return }
                            if let error { self.finish(interruption: error) }
                        }
                    }
                } catch { self.finish(interruption: error) }
            }
        }
        queue.asyncAfter(deadline: .now()+12) { [weak self] in
            guard let self, self.phase == .preparing else { return }
            self.finish(interruption: ReShotError(message: "录屏启动超时，没有收到屏幕画面。"))
        }
    }
    private func showControls(on screen: NSScreen,area: CGRect,toolbar: AnnotationToolbar) {
        let frame = screen.visibleFrame, w = toolbar.preferredSize.width+20, h: CGFloat = 78
        let x = min(frame.maxX-w,max(frame.minX,area.maxX-w))
        let y = area.minY-h-10 >= frame.minY ? area.minY-h-10 : min(frame.maxY-h,area.maxY+10)
        let panel = NSPanel(contentRect: CGRect(x: x,y: y,width: w,height: h),styleMask: [.titled,.nonactivatingPanel],backing: .buffered,defer: false)
        panel.title = "屏幕录制"; panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue+1); panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        let root = NSView(frame: CGRect(x: 0,y: 0,width: w,height: h)); panel.contentView = root
        toolbar.frame = CGRect(x: 10,y: 40,width: toolbar.preferredSize.width,height: toolbar.preferredSize.height)
        root.addSubview(toolbar)
        label.frame = CGRect(x: 14,y: 12,width: w-136,height: 20); root.addSubview(label)
        let actions: [(NSButton,String,String,Selector)] = [
            (pauseButton,"pause.fill","暂停录屏",#selector(togglePause)),
            (stopButton,"stop.fill","停止并保存",#selector(stop)),
            (cancelButton,"xmark","取消录制并丢弃",#selector(cancel))
        ]
        for (index,(button,symbol,title,action)) in actions.enumerated() {
            button.frame = CGRect(x: w-118+CGFloat(index*36),y: 8,width: 30,height: 28)
            button.title = ""; button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: symbol,accessibilityDescription: title)
            button.setAccessibilityLabel(title); button.toolTip = title
            button.bezelStyle = .rounded; button.target = self; button.action = action
            root.addSubview(button)
        }
        pauseButton.isEnabled = false; stopButton.isEnabled = false
        stopButton.keyEquivalent = "\r"
        self.panel = panel; panel.orderFrontRegardless()
    }
    private func startMicrophone() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else { throw ReShotError(message: "没有可用的麦克风。") }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(input),session.canAddOutput(output) else { throw ReShotError(message: "无法配置麦克风输入。") }
        session.addInput(input); session.addOutput(output)
        output.setSampleBufferDelegate(self,queue: queue)
        microphone = session
        microphoneControl.async { [weak self] in
            session.startRunning()
            guard let self else { session.stopRunning(); return }
            self.queue.async { [weak self] in
                guard let self, self.phase != .finished, self.phase != .finishing else { return }
                if !session.isRunning { self.finish(interruption: ReShotError(message: "麦克风启动失败。")) }
            }
        }
    }
    private func stopMicrophone() {
        guard let session = microphone else { return }
        microphone = nil
        microphoneControl.async { session.stopRunning() }
    }
    func captureOutput(_ output: AVCaptureOutput,didOutput sampleBuffer: CMSampleBuffer,from connection: AVCaptureConnection) {
        receiveAudio(sampleBuffer,source: .microphone,sourceClock: microphone?.synchronizationClock)
    }
    private func receiveAudio(_ sample: CMSampleBuffer,source: RecordingAudio.Source,sourceClock: CMClock?) {
        guard phase == .recording || phase == .paused || phase == .finishing, sample.isValid, CMSampleBufferDataIsReady(sample), sample.numSamples > 0 else { return }
        var time = sample.presentationTimeStamp
        if let sourceClock { time = CMSyncConvertTime(time,from: sourceClock,to: CMClockGetHostTimeClock()) }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0, seconds < Double(UInt64.max)/1_000_000_000,
              let position = clock.audioTime(at: UInt64(seconds*1_000_000_000)) else { return }
        do { try audio.add(sample,source: source,time: position.time,maximumDuration: position.remaining) }
        catch { finish(interruption: error) }
    }
    @objc func togglePause() {
        queue.async { [self] in
            let now = DispatchTime.now().uptimeNanoseconds
            switch phase {
            case .recording: clock.pause(at: now); phase = .paused; publish(force: true)
            case .paused: clock.resume(at: now); phase = .recording; publish(force: true)
            default: break
            }
        }
    }
    @objc func cancel() {
        queue.async { [self] in
            guard phase != .finishing, phase != .finished else { return }
            phase = .finishing
            timer?.cancel(); timer = nil; latest = nil
            stream?.stopCapture { _ in }; stream = nil
            stopMicrophone()
            movie?.discard(); movie = nil
            finishUI(.failure(CancellationError()))
        }
    }
    @objc func stop() { queue.async { [self] in finish(interruption: phase == .preparing ? CancellationError() : nil) } }
    func stream(_ stream: SCStream,didStopWithError error: Error) { queue.async { [self] in finish(interruption: error) } }
    func stream(_ stream: SCStream,didOutputSampleBuffer sampleBuffer: CMSampleBuffer,of type: SCStreamOutputType) {
        if type == .audio { receiveAudio(sampleBuffer,source: .system,sourceClock: stream.synchronizationClock); return }
        guard phase == .preparing || phase == .recording || phase == .paused, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        latest = buffer
        do { try annotations?.track(buffer) }
        catch { finish(interruption: error); return }
        if phase == .preparing && timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(),repeating: .nanoseconds(33_333_333),leeway: .milliseconds(4))
            timer.setEventHandler { [weak self] in self?.writeFrame() }; self.timer = timer; timer.resume()
        }
    }
    private func writeFrame() {
        guard phase == .preparing || phase == .recording, let latest, let movie else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        do {
            let overlay = try annotations?.image(width: CVPixelBufferGetWidth(latest),height: CVPixelBufferGetHeight(latest))
            let written = try movie.append(latest,elapsed: clock.elapsed(at: now),overlay: overlay)
            if phase == .preparing, written { phase = .recording; clock.resume(at: now); publish(force: true) }
            else if phase == .recording { publish() }
            if phase == .recording { try audio.flush(through: clock.elapsed(at: now),append: movie.appendAudio) }
        }
        catch { finish(interruption: error) }
    }
    private func publish(force: Bool = false) {
        let second = Int(clock.elapsed(at: DispatchTime.now().uptimeNanoseconds))
        guard force || second != shownSecond else { return }; shownSecond = second
        let phase = phase, elapsed = String(format: "%02d:%02d",second/60,second%60)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.visiblePhase = phase
            self.label.stringValue = phase == .finishing ? "正在保存视频…" : (phase == .paused ? "已暂停  " : "录屏中  ")+elapsed
            let pauseTitle = phase == .paused ? "继续录屏" : "暂停录屏"
            self.pauseButton.title = ""
            self.pauseButton.image = NSImage(systemSymbolName: phase == .paused ? "play.fill" : "pause.fill",accessibilityDescription: pauseTitle)
            self.pauseButton.toolTip = pauseTitle; self.pauseButton.setAccessibilityLabel(pauseTitle)
            self.pauseButton.isEnabled = phase == .recording || phase == .paused
            self.stopButton.isEnabled = phase == .recording || phase == .paused
            self.cancelButton.isEnabled = phase != .finishing
            self.annotations?.setPaused(phase == .paused)
            if phase == .finishing { self.annotations?.close() }
        }
    }
    private func finish(interruption: Error?) {
        guard phase != .finishing, phase != .finished else { return }
        let wasPreparing = phase == .preparing
        clock.pause(at: DispatchTime.now().uptimeNanoseconds); phase = .finishing; publish(force: true)
        timer?.cancel(); timer = nil; latest = nil
        if let stream { stream.stopCapture { _ in } }; stream = nil
        stopMicrophone()
        guard let movie, !wasPreparing else {
            movie?.discard(); self.movie = nil
            finishUI(.failure(interruption ?? ReShotError(message: "未录到有效画面。"))); return
        }
        finalize(movie,interruption: interruption,deadline: Date().addingTimeInterval(5))
    }
    private func finalize(_ movie: RecordingMovie,interruption: Error?,deadline: Date) {
        let elapsed = clock.elapsed(at: DispatchTime.now().uptimeNanoseconds)
        do {
            let drained = try audio.flush(through: elapsed,final: true,append: movie.appendAudio)
            if !drained {
                guard Date() < deadline else { throw ReShotError(message: "录屏音频结束处理超时。") }
                queue.asyncAfter(deadline: .now()+0.01) { [self] in finalize(movie,interruption: interruption,deadline: deadline) }
                return
            }
        } catch {
            movie.finish(elapsed: elapsed) { [self] result in
                queue.async { [self] in self.movie = nil; finishUI(result.map { Outcome(url: $0,interruption: error) }) }
            }
            return
        }
        movie.finish(elapsed: elapsed) { [self] result in
            queue.async { [self] in self.movie = nil; finishUI(result.map { Outcome(url: $0,interruption: interruption) }) }
        }
    }
    private func finishUI(_ result: Result<Outcome,Error>) {
        phase = .finished
        DispatchQueue.main.async { [self] in
            visiblePhase = .finished; annotations?.close(); panel?.orderOut(nil); panel = nil
            let callback = completion; completion = nil; callback?(result)
        }
    }
}
