import AppKit
import ImageIO

/// Manual sequence composition, deliberately independent of scroll matching.
enum ImageSequence {
    static func compose(_ urls: [URL]) throws -> CGImage {
        guard urls.count >= 2 else { throw ReShotError(message: "请至少选择两张图片。") }
        var width = 0, height = 0
        var dimensions: [(Int,Int)] = []
        for url in urls {
            guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                  let w = properties[kCGImagePropertyPixelWidth] as? Int,
                  let h = properties[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0, h <= 60_000-height else { throw ReShotError(message: "图片无法读取或成图超过 60000 像素高：\(url.lastPathComponent)") }
            width = max(width,w); height += h; dimensions.append((w,h))
        }
        guard width <= (192*1024*1024/4)/height,
              let context = CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ReShotError(message: "拼接后图片过大，请分批拼接。")
        }
        var y = height
        for (url,(w,h)) in zip(urls,dimensions) {
            try autoreleasepool {
                let image = try ImageFiles.read(url)
                guard image.width == w, image.height == h else { throw ReShotError(message: "拼接期间图片尺寸发生变化：\(url.lastPathComponent)") }
                y -= h
                context.draw(image,in: CGRect(x: (width-w)/2,y: y,width: w,height: h))
            }
        }
        guard let image = context.makeImage() else { throw ReShotError(message: "无法生成序列长图。") }
        return image
    }

    static func selfTest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReShot-sequence-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        func frame(_ w: Int,_ h: Int,_ color: CGColor) throws -> URL {
            let context = CGContext(data: nil,width: w,height: h,bitsPerComponent: 8,bytesPerRow: w*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(color); context.fill(CGRect(x: 0,y: 0,width: w,height: h))
            return try CaptureStorage.save(ImageFiles.png(context.makeImage()!),folder: folder)
        }
        let red = try frame(40,21,CGColor(red: 1,green: 0,blue: 0,alpha: 1))
        let blue = try frame(20,18,CGColor(red: 0,green: 0,blue: 1,alpha: 1))
        let bitmap = NSBitmapImageRep(cgImage: try compose([blue,red,blue]))
        func pixel(_ x: Int,_ y: Int) -> NSColor { bitmap.colorAt(x: x,y: y)!.usingColorSpace(.deviceRGB)! }
        guard bitmap.pixelsWide == 40, bitmap.pixelsHigh == 57,
              pixel(20,0).blueComponent > 0.9, pixel(20,17).blueComponent > 0.9,
              pixel(20,18).redComponent > 0.9, pixel(20,38).redComponent > 0.9,
              pixel(20,39).blueComponent > 0.9, pixel(20,56).blueComponent > 0.9,
              pixel(0,0).alphaComponent == 0, pixel(0,25).alphaComponent == 1 else { throw ReShotError(message: "任意截图拼接顺序、尺寸或透明边距错误") }
        print("PASS: arbitrary nonoverlapping images, explicit order, duplicate preservation, mixed widths, exact boundary rows")
    }
}

final class SequenceOrder: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var urls: [URL]
    private let table = NSTableView()
    init(_ urls: [URL]) { self.urls = urls; super.init() }
    func run() -> [URL]? {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("frame")); column.width = 415
        table.frame = CGRect(x: 0,y: 0,width: 415,height: 207); table.autoresizingMask = [.width]
        table.addTableColumn(column); table.headerView = nil; table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self; table.delegate = self; table.allowsEmptySelection = false
        let view = NSView(frame: CGRect(x: 0,y: 0,width: 430,height: 245))
        let scroll = NSScrollView(frame: CGRect(x: 0,y: 38,width: 430,height: 207)); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; view.addSubview(scroll)
        for (index,title) in ["上移","下移"].enumerated() {
            let button = NSButton(title: title,target: self,action: #selector(move(_:))); button.tag = index == 0 ? -1 : 1
            button.frame = CGRect(x: index*86,y: 0,width: 80,height: 30); view.addSubview(button)
        }
        table.reloadData(); table.selectRowIndexes(IndexSet(integer: 0),byExtendingSelection: false)
        let alert = NSAlert(); alert.messageText = "安排拼接顺序"
        alert.informativeText = "按列表从上到下原尺寸拼接；窄图居中，不需要重叠。"
        alert.accessoryView = view; alert.addButton(withTitle: "拼接"); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn ? urls : nil
    }
    func numberOfRows(in tableView: NSTableView) -> Int { urls.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        let label = NSTextField(labelWithString: "\(row+1).  \(urls[row].lastPathComponent)")
        label.lineBreakMode = .byTruncatingMiddle; label.toolTip = urls[row].path; return label
    }
    @objc private func move(_ button: NSButton) {
        let row = table.selectedRow, destination = row+button.tag
        guard urls.indices.contains(row),urls.indices.contains(destination) else { return }
        urls.swapAt(row,destination); table.reloadData()
        table.selectRowIndexes(IndexSet(integer: destination),byExtendingSelection: false); table.scrollRowToVisible(destination)
    }
}
