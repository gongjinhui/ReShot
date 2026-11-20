import AppKit
import Vision

enum OCR {
    struct Block {
        let text: String
        /// Original image pixels, origin at top left.
        let rect: CGRect
        let confidence: Float
    }
    struct Document {
        let blocks: [Block]
        var text: String { blocks.map(\.text).joined(separator: "\n") }
    }
    final class Job {
        private let lock = NSLock()
        private var stopped = false
        private var request: VNRequest?
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        func cancel() {
            lock.lock(); stopped = true; let active = request; lock.unlock()
            active?.cancel()
        }
        fileprivate func attach(_ value: VNRequest?) throws {
            lock.lock(); let cancelled = stopped; request = cancelled ? nil : value; lock.unlock()
            if cancelled { value?.cancel(); throw CancellationError() }
        }
    }
    static func recognize(_ image: CGImage,languages: [String] = ["zh-Hans","zh-Hant","en-US"]) throws -> String {
        try analyze(image,languages: languages).text
    }
    static func analyze(_ image: CGImage, languages: [String] = ["zh-Hans","zh-Hant","en-US"],
                        job: Job = Job(), progress: ((Double) -> Void)? = nil) throws -> Document {
        var blocks: [Block] = [], start = 0
        let tileHeight = 2000, overlap = 320
        defer { try? job.attach(nil) }
        while start < image.height {
            if job.isCancelled { throw CancellationError() }
            let height = min(tileHeight,image.height-start)
            guard let tile = image.cropping(to: CGRect(x: 0,y: start,width: image.width,height: height)) else { throw ReShotError(message: "无法读取图片分段") }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.minimumTextHeight = 0.001
            request.usesLanguageCorrection = true
            let supported = try request.supportedRecognitionLanguages()
            request.recognitionLanguages = languages.filter { supported.contains($0) }
            guard !request.recognitionLanguages.isEmpty else { throw ReShotError(message: "当前系统不支持所选识别语言。") }
            try job.attach(request)
            do { try VNImageRequestHandler(cgImage: tile,options: [:]).perform([request]) }
            catch { if job.isCancelled { throw CancellationError() }; throw error }
            if job.isCancelled { throw CancellationError() }
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let box = observation.boundingBox
                let rect = CGRect(x: box.minX*Double(image.width),y: Double(start)+(1-box.maxY)*Double(height),
                                  width: box.width*Double(image.width),height: box.height*Double(height))
                let block = Block(text: candidate.string,rect: rect,confidence: candidate.confidence)
                // Compare only co-located observations from the overlap. Keep the
                // version with more complete text, then confidence. Identical text
                // elsewhere in the document must survive.
                if let index = blocks.lastIndex(where: { old in
                    let intersection = old.rect.intersection(rect)
                    return !intersection.isNull && intersection.width*intersection.height > min(old.rect.width*old.rect.height,rect.width*rect.height)*0.55
                        && abs(old.rect.midY-rect.midY) < max(old.rect.height,rect.height)*0.6
                }) {
                    let old = blocks[index]
                    if block.text.count > old.text.count || (block.text.count == old.text.count && block.confidence > old.confidence) { blocks[index] = block }
                } else { blocks.append(block) }
            }
            progress?(Double(start+height)/Double(image.height))
            if start+height == image.height { break }
            start += tileHeight-overlap
        }
        return ordered(blocks)
    }
    /// Cluster rows before ordering columns; a direct fuzzy comparator is not
    /// transitive and can scramble a page when glyph heights differ.
    static func ordered(_ blocks: [Block]) -> Document {
        let sorted = blocks.sorted { $0.rect.midY < $1.rect.midY }
        var rows: [[Block]] = []
        for block in sorted {
            if let last = rows.last, let reference = last.first,
               abs(reference.rect.midY-block.rect.midY) < min(reference.rect.height,block.rect.height)*0.5 {
                rows[rows.count-1].append(block)
            } else { rows.append([block]) }
        }
        return Document(blocks: rows.flatMap { $0.sorted { $0.rect.minX < $1.rect.minX } })
    }
}

final class OCRResult: NSObject {
    let window: NSWindow
    let text = NSTextView()
    override init() {
        window = NSWindow(contentRect: CGRect(x: 0,y: 0,width: 600,height: 550),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
        super.init(); window.title = "OCR 识别结果 · 可编辑"; window.isReleasedWhenClosed = false
        let root = NSView(); window.contentView = root
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = text
        text.isRichText = false; text.font = .systemFont(ofSize: 17); text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        let copy = NSButton(title: "复制文字",target: self,action: #selector(copyText))
        let save = NSButton(title: "保存 TXT…",target: self,action: #selector(saveText))
        let merge = NSButton(title: "合并换行",target: self,action: #selector(mergeLines))
        for view in [scroll,copy,save,merge] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor,constant: 16),scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor,constant: -16),scroll.topAnchor.constraint(equalTo: root.topAnchor,constant: 16),scroll.bottomAnchor.constraint(equalTo: copy.topAnchor,constant: -12),copy.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),copy.bottomAnchor.constraint(equalTo: root.bottomAnchor,constant: -12),save.leadingAnchor.constraint(equalTo: copy.trailingAnchor,constant: 12),save.centerYAnchor.constraint(equalTo: copy.centerYAnchor),merge.leadingAnchor.constraint(equalTo: save.trailingAnchor,constant: 12),merge.centerYAnchor.constraint(equalTo: copy.centerYAnchor)])
    }
    func show(_ value: String) { text.string = value; window.center(); window.makeKeyAndOrderFront(nil) }
    @objc func mergeLines() {
        let parts = text.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        text.string = parts.joined(separator: " ")
    }
    @objc func copyText() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text.string,forType: .string) }
    @objc func saveText() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "ReShot-OCR.txt"
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            do { try self.text.string.write(to: url,atomically: true,encoding: .utf8) }
            catch { NSAlert(error: error).beginSheetModal(for: self.window) }
        }
    }
}
