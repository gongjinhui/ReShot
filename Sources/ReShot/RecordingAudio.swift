import AVFoundation

/// Converts both capture devices into one common PCM format before mixing.
final class RecordingAudio {
    enum Source: Hashable { case system, microphone }
    static let rate = 48_000.0
    private let format = AVAudioFormat(standardFormatWithSampleRate: rate,channels: 2)!
    private var converters: [Source:AVAudioConverter] = [:]
    private var endFrames: [Source:Int] = [:]
    private var chunks: [Int:[Float]] = [:]
    private var nextFrame = 0
    private let chunkFrames = 1024

    func add(_ sample: CMSampleBuffer,source: Source,time: TimeInterval,maximumDuration: TimeInterval = .infinity) throws {
        guard let description = sample.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let inputFormat = AVAudioFormat(streamDescription: asbd),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat,frameCapacity: AVAudioFrameCount(sample.numSamples)) else {
            throw ReShotError(message: "无法读取录屏音频格式。")
        }
        input.frameLength = input.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample,at: 0,frameCount: Int32(input.frameLength),into: input.mutableAudioBufferList) == noErr else {
            throw ReShotError(message: "无法读取录屏音频样本。")
        }
        let converted: AVAudioPCMBuffer
        if inputFormat == format { converted = input }
        else {
            let converter: AVAudioConverter
            if let cached = converters[source], cached.inputFormat == inputFormat { converter = cached }
            else {
                guard let created = AVAudioConverter(from: inputFormat,to: format) else { throw ReShotError(message: "无法转换麦克风音频格式。") }
                converters[source] = created; converter = created
            }
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength)*Self.rate/inputFormat.sampleRate))+64
            guard let output = AVAudioPCMBuffer(pcmFormat: format,frameCapacity: capacity) else { throw ReShotError(message: "无法分配音频缓冲。") }
            var supplied = false, error: NSError?
            let status = converter.convert(to: output,error: &error) { _, state in
                guard !supplied else { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            if status == .error { throw error ?? ReShotError(message: "音频转换失败。") }
            converted = output
        }
        guard let channels = converted.floatChannelData else { throw ReShotError(message: "音频转换未返回 PCM 数据。") }
        let start = Int((time*Self.rate).rounded())
        let allowed = maximumDuration.isFinite ? max(0,Int((maximumDuration*Self.rate).rounded(.down))) : Int(converted.frameLength)
        let length = min(Int(converted.frameLength),allowed)
        let skip = max(0,max(nextFrame,endFrames[source] ?? 0)-start)
        guard skip < length else { return }
        guard start+length-nextFrame <= Int(Self.rate*3) else { throw ReShotError(message: "音频写入落后超过三秒，录制已停止以保留已录内容。") }
        for i in skip..<length {
            let frame = start+i
            guard frame >= nextFrame else { continue }
            let index = frame/chunkFrames, offset = (frame%chunkFrames)*2
            if chunks[index] == nil { chunks[index] = [Float](repeating: 0,count: chunkFrames*2) }
            chunks[index]![offset] += channels[0][i]*0.7
            chunks[index]![offset+1] += channels[1][i]*0.7
        }
        endFrames[source] = max(endFrames[source] ?? 0,start+length)
    }
    /// Leaves 120ms for device callbacks. A silent source contributes silence.
    @discardableResult func flush(through time: TimeInterval,final: Bool = false,append: (CMSampleBuffer) throws -> Bool) throws -> Bool {
        let limit = max(0,Int(((final ? time : time-0.12)*Self.rate).rounded(.down)))
        while nextFrame < limit {
            let length = min(chunkFrames,limit-nextFrame)
            if length < chunkFrames && !final { break }
            let index = nextFrame/chunkFrames
            let values = chunks[index] ?? [Float](repeating: 0,count: chunkFrames*2)
            let clipped = values.prefix(length*2).map { max(-1,min(1,$0)) }
            let sample = try Self.sample(clipped,rate: Self.rate,channels: 2,time: Double(nextFrame)/Self.rate)
            guard try append(sample) else {
                if time-Double(nextFrame)/Self.rate > 2 { throw ReShotError(message: "音频编码器持续无响应。") }
                return false
            }
            chunks.removeValue(forKey: index); nextFrame += length
        }
        return nextFrame >= limit || !final
    }
    static func sample(_ values: [Float],rate: Double,channels: UInt32,time: TimeInterval) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: rate,mFormatID: kAudioFormatLinearPCM,mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,mBytesPerPacket: channels*4,mFramesPerPacket: 1,mBytesPerFrame: channels*4,mChannelsPerFrame: channels,mBitsPerChannel: 32,mReserved: 0)
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,asbd: &asbd,layoutSize: 0,layout: nil,magicCookieSize: 0,magicCookie: nil,extensions: nil,formatDescriptionOut: &description) == noErr, let description else { throw ReShotError(message: "无法创建音频描述。") }
        var block: CMBlockBuffer?
        let bytes = values.count*MemoryLayout<Float>.size
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,memoryBlock: nil,blockLength: bytes,blockAllocator: kCFAllocatorDefault,customBlockSource: nil,offsetToData: 0,dataLength: bytes,flags: 0,blockBufferOut: &block) == noErr, let block else { throw ReShotError(message: "无法分配音频数据。") }
        let status = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!,blockBuffer: block,offsetIntoDestination: 0,dataLength: bytes) }
        guard status == noErr else { throw ReShotError(message: "无法写入音频数据。") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1,timescale: Int32(rate)),presentationTimeStamp: CMTime(seconds: time,preferredTimescale: 48_000),decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,dataBuffer: block,formatDescription: description,sampleCount: values.count/Int(channels),sampleTimingEntryCount: 1,sampleTimingArray: &timing,sampleSizeEntryCount: 0,sampleSizeArray: nil,sampleBufferOut: &sample) == noErr, let sample else { throw ReShotError(message: "无法创建音频样本。") }
        return sample
    }
}

extension RecordingAudio {
    static func selfTest() throws {
        let mixer = RecordingAudio()
        var clock = RecordingClock()
        clock.resume(at: 0); clock.pause(at: 1_000_000_000); clock.resume(at: 8_000_000_000)
        guard clock.audioTime(at: 4_000_000_000) == nil,
              clock.audioTime(at: 8_500_000_000)?.time == 1.5,
              clock.audioTime(at: 990_000_000)!.remaining < 0.011 else { throw ReShotError(message: "暂停的音频时间映射错误。") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReShot-audio-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try RecordingMovie(folder: folder,width: 96,height: 64,audio: true)
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault,96,64,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,&pixel)
        guard let pixel else { throw ReShotError(message: "测试视频缓冲不可用。") }
        CVPixelBufferLockBaseAddress(pixel,[])
        memset(CVPixelBufferGetBaseAddress(pixel),255,CVPixelBufferGetBytesPerRow(pixel)*64)
        CVPixelBufferUnlockBaseAddress(pixel,[])
        func waitForWrite(_ body: () throws -> Bool) throws {
            let deadline = Date().addingTimeInterval(3)
            while try !body() {
                guard Date() < deadline else { throw ReShotError(message: "测试音频写入超时。") }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        for block in 0..<100 {
            let time = Double(block)/50
            let host = UInt64(time*1_000_000_000)+(block < 50 ? 0 : 7_000_000_000)
            let mapped = clock.audioTime(at: host)!
            var system = [Float](), mic = [Float]()
            for i in 0..<960 {
                let value = Float(sin(2*Double.pi*440*(time+Double(i)/48_000))*0.3)
                system.append(value); system.append(value)
            }
            for i in 0..<882 { mic.append(Float(sin(2*Double.pi*880*(time+Double(i)/44_100))*0.3)) }
            try mixer.add(sample(system,rate: 48_000,channels: 2,time: time),source: .system,time: mapped.time)
            try mixer.add(sample(mic,rate: 44_100,channels: 1,time: time),source: .microphone,time: mapped.time)
            if block%5 == 0 {
                let videoTime = Double(block)/50
                try waitForWrite { try movie.append(pixel,elapsed: videoTime) }
            }
            try mixer.flush(through: time,append: movie.appendAudio)
        }
        clock.pause(at: 9_000_000_000)
        try waitForWrite { try mixer.flush(through: 2,final: true,append: movie.appendAudio) }
        let done = DispatchSemaphore(value: 0); var result: Result<URL,Error>?
        movie.finish(elapsed: 2) { result = $0; done.signal() }
        guard done.wait(timeout: .now()+15) == .success, let result else { throw ReShotError(message: "测试音画保存超时。") }
        let url = try result.get()
        let inspected = DispatchSemaphore(value: 0); var verification: Result<Void,Error>?
        Task.detached {
            do {
                let asset = AVURLAsset(url: url)
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard tracks.count == 1 else { throw ReShotError(message: "MP4 应包含一条混合音轨。") }
                let duration = try await asset.load(.duration)
                guard abs(duration.seconds-2) < 0.15 else { throw ReShotError(message: "音画时长没有正确排除暂停。") }
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: tracks[0],outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,AVSampleRateKey: 48_000,AVNumberOfChannelsKey: 2,AVLinearPCMIsFloatKey: true,AVLinearPCMBitDepthKey: 32,AVLinearPCMIsNonInterleaved: false])
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? ReShotError(message: "无法解码 AAC 音轨。") }
                var wave: [Float] = []
                while let sample = output.copyNextSampleBuffer(),let block = sample.dataBuffer {
                    let bytes = CMBlockBufferGetDataLength(block)
                    var values = [Float](repeating: 0,count: bytes/4)
                    let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset: 0,dataLength: bytes,destination: $0.baseAddress!) }
                    guard status == noErr else { throw ReShotError(message: "音轨数据读取失败。") }
                    for i in stride(from: 0,to: values.count,by: 2) { wave.append(values[i]) }
                }
                guard reader.status == .completed, wave.count > 90_000 else { throw ReShotError(message: "音轨帧数不足。") }
                func amplitude(_ frequency: Double) -> Double {
                    var real = 0.0, imaginary = 0.0
                    let start = 5000, length = min(80_000,wave.count-start)
                    for i in 0..<length {
                        let phase = 2*Double.pi*frequency*Double(i)/48_000
                        real += Double(wave[start+i])*cos(phase); imaginary += Double(wave[start+i])*sin(phase)
                    }
                    return hypot(real,imaginary)/Double(length)
                }
                guard amplitude(440) > 0.04, amplitude(880) > 0.04 else { throw ReShotError(message: "系统音频或麦克风没有进入混合音轨。") }
                verification = .success(())
            } catch { verification = .failure(error) }
            inspected.signal()
        }
        guard inspected.wait(timeout: .now()+15) == .success, let verification else { throw ReShotError(message: "AAC 校验超时。") }
        try verification.get()
        let discarded = try RecordingMovie(folder: folder,width: 96,height: 64,audio: true)
        discarded.discard()
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        guard files.filter({ $0.hasSuffix(".mp4") }) == [url.lastPathComponent] else { throw ReShotError(message: "取消后残留了本次录屏。") }
        print("PASS: 48kHz stereo system + 44.1kHz mono mic conversion/mix, both tones in single AAC track, pause exclusion, A/V duration, cancel removes temporary movie")
    }
}
