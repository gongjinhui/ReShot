import Foundation
import CoreGraphics

/// Conservative, offline vertical stitching. Frames must be from the same viewport,
/// moving downward, with at least 64px / 12% overlap. Exclude sticky headers/footers.
/// No network calls, accessibility events or input injection are performed here.
enum ScrollStitcher {
    enum StitchError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
    }
    private static let byteLimit = 192_000_000
    private static let heightLimit = 60_000
    private struct Pixels {
        let width: Int
        let height: Int
        let rgba: [UInt8]
        let gray: [UInt8]
        init(_ image: CGImage) throws {
            width = image.width; height = image.height
            guard width > 20, height >= 96, width <= 16_384,
                  height <= heightLimit, width * height <= byteLimit / 4 else {
                throw StitchError.invalid("截图尺寸过大或过小，无法安全拼接。")
            }
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let pixelWidth = width, pixelHeight = height
            let succeeded = bytes.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(data: raw.baseAddress, width: pixelWidth, height: pixelHeight,
                    bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                return true
            }
            guard succeeded else { throw StitchError.invalid("无法读取截图像素。") }
            rgba = bytes
            // Ignore 12% on each side: right-hand scrollbar, borders and common floating controls.
            let columns = 64
            var samples = [UInt8](repeating: 0, count: columns * height)
            for y in 0..<height {
                for column in 0..<columns {
                    let x = min(width - 1, width * 12 / 100 + column * (width * 76 / 100) / columns)
                    let i = (y * width + x) * 4
                    samples[y * columns + column] = UInt8((Int(bytes[i]) * 77 + Int(bytes[i+1]) * 150 + Int(bytes[i+2]) * 29) >> 8)
                }
            }
            gray = samples
        }
    }
    /// Maximum output: 60,000 rows and 192 MB uncompressed RGBA. At most 100 frames.
    /// Throws on non-overlap, uncertain alignment, width/height changes, and allocation limits.
    static func stitch(_ frames: [CGImage]) throws -> CGImage {
        guard let first = frames.first, frames.count <= 100 else { throw StitchError.invalid("请选择 1 至 100 张滚动截图。") }
        let inputBytes = frames.reduce(Int64(0)) { $0 + Int64($1.width) * Int64($1.height) * 4 }
        guard inputBytes <= 256_000_000 else {
            throw StitchError.invalid("输入截图的解码像素超过 256 MB，请分段拼接。")
        }
        _ = first
        let session = Session()
        for frame in frames { try session.append(frame) }
        return try session.image()
    }
    /// Cheap motion estimate for frame retention, never used to assert a final seam.
    static func advanceHint(_ previous: CGImage,_ current: CGImage) -> Int? {
        guard previous.width == current.width, previous.height == current.height,
              let a = try? Pixels(previous), let b = try? Pixels(current) else { return nil }
        if difference(a,b,offset: 0) < 0.05 { return 0 }
        let last = a.height-max(64,a.height*12/100)
        guard last > 0 else { return nil }
        let step = max(1,a.height/160)
        let best = stride(from: 1,through: last,by: step).map { ($0,difference(a,b,offset: $0)) }.min { $0.1 < $1.1 }
        guard let best, best.1 < 8 else { return nil }
        return best.0
    }

    enum Update: Equatable {
        case appended(Int), duplicate, rollback, realignment(String), limitReached
    }

    /// All methods are called by the capture's serial worker. Origins are content
    /// coordinates, so revisiting an earlier viewport never appends duplicate rows.
    final class Session {
        private var previous: CGImage?
        private var first: CGImage?
        private var frontier: CGImage?
        private var pieces: [CGImage] = []
        private var thumbnails: [CGImage] = []
        private var origin = 0, maximumOrigin = 0
        private(set) var topInset = 0, bottomInset = 0
        private(set) var height = 0
        private(set) var count = 0
        private var width = 0

        @discardableResult func append(_ image: CGImage) throws -> Bool {
            switch try update(image) {
            case .appended: return true
            case .duplicate, .rollback: return false
            case .realignment(let message): throw StitchError.invalid(message)
            case .limitReached: throw StitchError.invalid("长图达到 60000px / 192MB 上限，请完成截图。")
            }
        }
        func update(_ image: CGImage) throws -> Update {
            _ = try Pixels(image)
            guard let previous else {
                width = image.width; height = image.height; first = image; frontier = image
                pieces = [image]; thumbnails = [try small(image)]; self.previous = image; count = 1
                return .appended(image.height)
            }
            guard previous.width == image.width, previous.height == image.height else {
                return .realignment("截图区域或缩放发生变化，请取消后重新框选。")
            }
            let rawA = try Pixels(previous), rawB = try Pixels(image)
            if isDuplicate(rawA,rawB) { return .duplicate }
            var top = topInset, bottom = bottomInset
            var movement: Int?
            func motion(_ t: Int,_ b: Int) throws -> Int? {
                let area = CGRect(x: 0,y: t,width: width,height: image.height-t-b)
                guard area.height >= 96, let ac = previous.cropping(to: area), let bc = image.cropping(to: area) else { return nil }
                let a = try Pixels(ac), b = try Pixels(bc)
                if isDuplicate(a,b) { return 0 }
                let down = try? alignment(a,b), up = try? alignment(b,a)
                if let down, let up {
                    let margin = min(down.1,up.1) < 0.02 ? 0.02 : max(0.3,min(down.1,up.1)*0.35)
                    guard abs(down.1-up.1) > margin else { return nil }
                    return down.1 < up.1 ? down.0 : -up.0
                }
                return down?.0 ?? up.map { -$0.0 }
            }
            movement = try motion(top,bottom)
            if count == 1 {
                // Only infer pinned edges when there is an exact stable textured
                // band and a unique match in the remaining moving content.
                let insets = stableInsets(rawA,rawB)
                if insets.0 > 0 || insets.1 > 0 {
                    if let croppedMotion = try motion(insets.0,insets.1) { movement = croppedMotion; top = insets.0; bottom = insets.1 }
                }
            }
            guard let movement else { return .realignment("未接上：请回滚少许重接；固定栏或动画较多时请调整选区。") }
            if movement == 0 { return .realignment("内容未移动，但固定栏发生变化，请暂停后重试。") }
            let nextOrigin = origin+movement
            guard nextOrigin >= 0 else { return .realignment("已滚到起始区域上方，请回到起始位置后继续。") }
            let added = max(0,nextOrigin-maximumOrigin)
            guard height+added <= heightLimit, (height+added)*width*4 <= byteLimit else { return .limitReached }
            if top != topInset || bottom != bottomInset {
                guard let first, let initial = first.cropping(to: CGRect(x: 0,y: 0,width: width,height: first.height-bottom)) else { throw StitchError.invalid("无法裁切固定栏。") }
                pieces = [try detached(initial)]; thumbnails = [try small(initial)]
                topInset = top; bottomInset = bottom
            }
            if added > 0 {
                guard let strip = image.cropping(to: CGRect(x: 0,y: image.height-bottom-added,width: width,height: added)) else { throw StitchError.invalid("无法提取新增内容。") }
                let copy = try detached(strip)
                pieces.append(copy); thumbnails.append(try small(copy)); height += added
                maximumOrigin = nextOrigin; frontier = image; count += 1
            }
            origin = nextOrigin; self.previous = image
            return added > 0 ? .appended(added) : .rollback
        }
        private func detached(_ image: CGImage) throws -> CGImage {
            guard let c = CGContext(data: nil,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw StitchError.invalid("图片内存分配失败。") }
            c.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
            guard let result = c.makeImage() else { throw StitchError.invalid("图片生成失败。") }; return result
        }
        private func small(_ image: CGImage) throws -> CGImage {
            let w = min(200,image.width), h = max(1,Int((Double(image.height)*Double(w)/Double(image.width)).rounded()))
            guard let c = CGContext(data: nil,width: w,height: h,bitsPerComponent: 8,bytesPerRow: w*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw StitchError.invalid("预览内存不足。") }
            c.draw(image,in: CGRect(x: 0,y: 0,width: w,height: h)); return c.makeImage()!
        }
        func preview() -> CGImage? {
            guard width > 0 else { return nil }
            let ratio = min(200/Double(width),900/Double(height))
            let w = max(1,Int(Double(width)*ratio)), h = max(1,Int(Double(height)*ratio))
            guard let c = CGContext(data: nil,width: w,height: h,bitsPerComponent: 8,bytesPerRow: w*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            var y = Double(h)
            for (index,piece) in pieces.enumerated() {
                let ph = Double(piece.height)*ratio; y -= ph
                c.draw(thumbnails[index],in: CGRect(x: 0,y: y,width: Double(w),height: ph))
            }
            return c.makeImage()
        }
        func image() throws -> CGImage {
            guard width > 0, let c = CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw StitchError.invalid("没有可生成的长图。") }
            var y = height
            for piece in pieces { y -= piece.height; c.draw(piece,in: CGRect(x: 0,y: y,width: width,height: piece.height)) }
            if bottomInset > 0, let frontier, let footer = frontier.cropping(to: CGRect(x: 0,y: frontier.height-bottomInset,width: width,height: bottomInset)) {
                c.draw(footer,in: CGRect(x: 0,y: 0,width: width,height: bottomInset))
            }
            guard let image = c.makeImage() else { throw StitchError.invalid("生成长图失败。") }; return image
        }
    }

    private static func stableInsets(_ a: Pixels,_ b: Pixels) -> (Int,Int) {
        func row(_ y: Int) -> (stable: Bool,textured: Bool) {
            var delta = 0, texture = 0
            for x in 0..<64 {
                delta += abs(Int(a.gray[y*64+x])-Int(b.gray[y*64+x]))
                if x > 0 { texture += abs(Int(a.gray[y*64+x])-Int(a.gray[y*64+x-1])) }
            }
            return (delta <= 16,texture > 64)
        }
        func band(bottom: Bool) -> Int {
            let cap = a.height/3
            var length = 0, textured = false
            while length < cap {
                let sample = row(bottom ? a.height-length-1 : length)
                if !sample.stable { break }; textured = textured || sample.textured; length += 1
            }
            return length >= 8 && length < cap && textured ? length : 0
        }
        return (band(bottom:false),band(bottom:true))
    }

    private static func isDuplicate(_ previous: Pixels, _ next: Pixels) -> Bool {
        guard difference(previous, next, offset: 0) < 1.6 else { return false }
        // A low mean on a mostly white page alone does not establish identity.
        // Require almost all sampled pixels to agree, so sparse moved text survives.
        var changed = 0
        let left = previous.width * 12 / 100, right = previous.width * 88 / 100
        for y in 0..<previous.height {
            for x in stride(from: left, to: right, by: 2) {
                let index = (y * previous.width + x) * 4
                for channel in 0..<3 {
                    if abs(Int(previous.rgba[index + channel]) - Int(next.rgba[index + channel])) > 6 {
                        changed += 1
                        if changed > 2 { return false }
                    }
                }
            }
        }
        return true
    }

    /// Mean absolute luminance difference. Bounded sampling keeps work O(frame height).
    private static func difference(_ previous: Pixels, _ next: Pixels, offset: Int) -> Double {
        let overlap = min(previous.height - offset, next.height)
        let rowStep = max(1, overlap / 80)
        var error = 0, count = 0
        for y in stride(from: 0, to: overlap, by: rowStep) {
            for x in 0..<64 {
                error += abs(Int(previous.gray[(y + offset) * 64 + x]) - Int(next.gray[y * 64 + x]))
                count += 1
            }
        }
        return Double(error) / Double(max(1, count))
    }
    /// Verify finalists at every row and every second interior pixel. White page
    /// margins do not dilute the error: only pairs with visible content contribute.
    private static func denseDifference(_ previous: Pixels, _ next: Pixels, offset: Int) -> Double {
        let overlap = previous.height-offset
        let left = previous.width*12/100, right = previous.width*88/100
        var errors = [Int](repeating:0,count:3), counts = [Int](repeating:0,count:3)
        for y in 0..<overlap {
            for x in stride(from:left,to:right,by:2) {
                let a = ((y+offset)*previous.width+x)*4, b = (y*next.width+x)*4
                let av = (Int(previous.rgba[a])*77+Int(previous.rgba[a+1])*150+Int(previous.rgba[a+2])*29)>>8
                let bv = (Int(next.rgba[b])*77+Int(next.rgba[b+1])*150+Int(next.rgba[b+2])*29)>>8
                if av < 245 || bv < 245 {
                    let band = min(2,(x-left)*3/max(1,right-left))
                    errors[band] += abs(av-bv); counts[band] += 1
                }
            }
        }
        let scores = (0..<3).map { counts[$0] >= max(24,overlap/6) ? Double(errors[$0])/Double(counts[$0]) : Double.infinity }.sorted()
        // Validate every available text band. Narrow text columns must not be
        // rejected because the remaining page is white. With three populated
        // bands a single animation/sidebar may be excluded.
        let populated = scores.filter { $0.isFinite }
        guard !populated.isEmpty else { return .infinity }
        if populated.count < 3 { return populated.reduce(0,+)/Double(populated.count) }
        return scores[2] < 8 ? scores.reduce(0,+)/3 : scores[1]
    }
    private static func align(_ previous: Pixels, _ next: Pixels) throws -> Int { try alignment(previous,next).0 }
    private static func alignment(_ previous: Pixels, _ next: Pixels) throws -> (Int,Double) {
        let minimumOverlap = max(64, previous.height * 12 / 100)
        let lastOffset = previous.height - minimumOverlap
        guard lastOffset >= 1 else { throw StitchError.invalid("截图高度不足以匹配重叠区域。") }
        // Search every vertical pixel with bounded sparse rows/columns. Skipping
        // offsets would miss exact alignment on high-frequency content.
        var candidates = (1...lastOffset).map { ($0, difference(previous, next, offset: $0)) }
        candidates.sort { $0.1 < $1.1 }
        // Include every coarse near-tie (up to 64) rather than trusting the
        // sparse winner. Repeated paragraphs may differ by just one digit.
        let coarseBest = candidates[0].1
        let finalists = candidates.filter { $0.1 <= coarseBest + 2.0 }.prefix(64)
        let ranked = finalists.map { ($0.0, denseDifference(previous, next, offset: $0.0)) }.sorted { $0.1 < $1.1 }
        guard let best = ranked.first, best.1 < 8.0 else {
            throw StitchError.invalid("相邻截图没有足够重叠，或内容已改变。请每次向下滚动不超过区域高度的 80%。")
        }
        let runner = ranked.first { abs($0.0 - best.0) > 4 }
        // Exact matches are strong evidence even when another paragraph is
        // almost the same. Truly periodic content still has multiple zero scores.
        let ambiguityMargin = best.1 < 0.02 ? 0.02 : max(0.3, best.1 * 0.35)
        if let runner, runner.1 <= best.1 + ambiguityMargin {
            throw StitchError.invalid("重叠区域过于相似，无法确定拼接位置。请增加文字或图像内容，避开大块空白和重复背景。")
        }
        // An all-white overlap can score perfectly at a spurious boundary.
        let overlap = previous.height - best.0
        var texture = 0, samples = 0
        for y in stride(from: 1, to: overlap, by: max(1, overlap / 80)) {
            for x in 0..<64 {
                texture += abs(Int(next.gray[y * 64 + x]) - Int(next.gray[(y - 1) * 64 + x]))
                samples += 1
            }
        }
        guard Double(texture) / Double(max(samples, 1)) > 0.15 else {
            throw StitchError.invalid("重叠区域缺少可匹配细节，无法可靠拼接。")
        }
        return best
    }

    /// Deterministic real-pixel tests, callable from the application's CLI self-test.
    static func selfTest() throws {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw StitchError.invalid("拼接自测失败：" + message) }
        }
        func make(_ width: Int, _ height: Int, seed: UInt64 = 7) -> CGImage {
            var state = seed
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                state = state &* 6364136223846793005 &+ 1
                let v = UInt8((state >> 32) % 200 + 20)
                let i = (y * width + x) * 4
                bytes[i] = v; bytes[i+1] = v; bytes[i+2] = v
            } }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        let original = make(180, 1620)
        let frames = [0, 300, 600, 900].map { original.cropping(to: CGRect(x: 0, y: $0, width: 180, height: 720))! }
        let result = try stitch(frames)
        try require(result.width == 180 && result.height == 1620, "完整长图尺寸")
        try require(try Pixels(result).rgba == Pixels(original).rgba, "拼接后每个像素均与原图相同，无重复行或倒置")
        let sameHint = advanceHint(frames[0],frames[0])
        let smallFrame = original.cropping(to: CGRect(x: 0,y: 60,width: 180,height: 720))!
        let smallHint = advanceHint(frames[0],smallFrame)
        try require(sameHint == 0, "静止画面不占用采集预算")
        // High-frequency random pixels may intentionally return nil (retain the frame).
        try require(smallHint == nil || abs(smallHint! - 60) <= 5, "采集位移估计")
        let denseFrames = stride(from: 0,through: 900,by: 60).map { original.cropping(to: CGRect(x: 0,y: $0,width: 180,height: 720))! }
        let denseResult = try stitch(denseFrames)
        try require(try Pixels(denseResult).rgba == Pixels(original).rgba, "连续滚动密集帧无漏行")
        let session = Session()
        for frame in frames { try session.append(frame) }
        let incremental = try session.image()
        try require(try Pixels(incremental).rgba == Pixels(original).rgba, "增量拼接与原图逐像素一致")
        try session.append(frames.last!)
        try require(session.height == 1620, "增量重复帧不增长")
        do { try session.append(make(180,720,seed: 937)) } catch {}
        try require(session.height == 1620, "失败帧不得破坏已有长图")
        let rollback = Session()
        for index in [0,1,2,1,2,3] { _ = try rollback.update(frames[index]) }
        try require(try Pixels(rollback.image()).rgba == Pixels(original).rgba,"回滚后重接逐像素无重复")
        let pinned = Session(), header = try Pixels(frames[0]).rgba
        func pinnedFrame(_ offset: Int) throws -> CGImage {
            let content = try Pixels(original.cropping(to: CGRect(x:0,y:offset,width:180,height:632))!).rgba
            var data = Array(header[0..<(48*180*4)])
            data += content; data += Array(header[((720-40)*180*4)..<(720*180*4)])
            return CGImage(width:180,height:720,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:720,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),provider:CGDataProvider(data:Data(data) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        }
        for offset in [0,300,600,900] { try pinned.append(pinnedFrame(offset)) }
        var expected = Array(header[0..<(48*180*4)])
        expected += try Pixels(original.cropping(to:CGRect(x:0,y:0,width:180,height:1532))!).rgba
        expected += Array(header[((720-40)*180*4)..<(720*180*4)])
        try require(pinned.topInset == 48 && pinned.bottomInset == 40,"固定页头页尾检测")
        try require(try Pixels(pinned.image()).rgba == expected,"固定栏只保留一次且正文无漏行")
        try require(pinned.preview()!.height <= 900,"预览保持有界尺寸")
        let duplicate = try stitch([frames[0], frames[0], frames[1], frames[1]])
        try require(duplicate.height == 1020, "重复帧应忽略")
        func mustReject(_ images: [CGImage], _ message: String) throws {
            do { _ = try stitch(images) } catch { return }
            throw StitchError.invalid("拼接自测失败：未拒绝" + message)
        }
        try mustReject([frames[0], make(180, 720, seed: 937)], "无重叠图片")
        try mustReject([frames[0], make(190, 720)], "不同宽度")
        try mustReject([], "空序列")
        // Simulated animated right scrollbar + luminance noise on the second frame.
        let base = try Pixels(frames[1])
        var noisy = base.rgba
        for y in 0..<base.height { for x in 0..<base.width {
            let i = (y * base.width + x) * 4
            for channel in 0..<3 { noisy[i + channel] = x > base.width - 14 ? UInt8(y % 255) : UInt8(clamping: Int(noisy[i + channel]) + (y % 3 - 1)) }
        } }
        let noisyFrame = CGImage(width: base.width, height: base.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: base.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(noisy) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        // Two shifted but periodic textures have many equally valid alignments.
        func repeatingFrame(shift: Int) -> CGImage {
            var repeated = base.rgba
            for y in 0..<base.height {
                let sourceRow = (y + shift) % 20
                repeated.replaceSubrange((y * base.width * 4)..<((y + 1) * base.width * 4),
                    with: base.rgba[(sourceRow * base.width * 4)..<((sourceRow + 1) * base.width * 4)])
            }
            return CGImage(width: base.width, height: base.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: base.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: CGDataProvider(data: Data(repeated) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        try mustReject([repeatingFrame(shift: 0), repeatingFrame(shift: 7)], "重复纹理歧义")
        let noisyResult = try stitch([frames[0], noisyFrame])
        try require(noisyResult.height == 1020, "轻微噪声与滚动条不影响拼接位置")
        print("PASS: exact pixels, rollback/rejoin, pinned header/footer once, bounded preview, duplicates, noise/scrollbar, no overlap, ambiguous texture, dimensions")
        fflush(stdout)
    }
}
