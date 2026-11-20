import AppKit
import ImageIO
import UniformTypeIdentifiers

enum CaptureFormat: String, CaseIterable {
    case png, jpg, tiff

    static func selected(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: "captureImageFormat").flatMap(Self.init(rawValue:)) ?? .png
    }

    var contentType: UTType {
        switch self {
        case .png: return .png
        case .jpg: return .jpeg
        case .tiff: return .tiff
        }
    }

    func encode(_ image: CGImage) throws -> Data {
        if self == .png { return try ImageFiles.png(image) }
        var image = image
        if self == .jpg, let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(rect)
            context.draw(image, in: rect)
            guard let flattened = context.makeImage() else { throw ReShotError(message: "JPEG 背景合成失败。") }
            image = flattened
        } else if self == .jpg {
            throw ReShotError(message: "JPEG 背景合成失败。")
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        let properties: [NSBitmapImageRep.PropertyKey: Any] = self == .jpg ? [.compressionFactor: 0.92] : [:]
        guard let data = bitmap.representation(using: self == .jpg ? .jpeg : .tiff, properties: properties) else {
            throw ReShotError(message: "图片编码失败。")
        }
        return data
    }
}

enum ImageFiles {
    /// Detach pixels from the input URL before a capture's temporary file is removed.
    static func read(_ url: URL) throws -> CGImage {
        let data = try Data(contentsOf: url)
        let options: [CFString: Any] = [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true]
        guard let source = CGImageSourceCreateWithData(data as CFData,options as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source,0,options as CFDictionary),
              let context = CGContext(data: nil,width: image.width,height: image.height,bitsPerComponent: 8,
                bytesPerRow: image.width*4,space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ReShotError(message: "无法读取图片，请选择有效的 PNG、JPEG 或 TIFF 图片。")
        }
        context.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
        guard let result = context.makeImage() else { throw ReShotError(message: "图片解码失败。") }
        return result
    }
    static func png(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:]) else { throw ReShotError(message: "PNG 编码失败。") }
        return data
    }
}


enum CaptureStorage {
    static func save(_ data: Data, folder: URL, format: CaptureFormat = .png) throws -> URL {
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":",with: "-")
        let file = folder.appendingPathComponent("ReShot-"+stamp+"-"+UUID().uuidString+"."+format.rawValue)
        try data.write(to: file,options: .atomic); return file
    }
    static func selfTest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReShot-storage-test-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = CGContext(data: nil,width: 32,height: 24,bitsPerComponent: 8,bytesPerRow: 128,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = try ImageFiles.png(context.makeImage()!)
        let first = try save(data,folder: folder), second = try save(data,folder: folder)
        let decoded = try ImageFiles.read(first)
        guard first != second, decoded.width == 32, decoded.height == 24 else { throw ReShotError(message: "自动保存测试失败") }
        for format in CaptureFormat.allCases {
            let file = try save(format.encode(context.makeImage()!), folder: folder, format: format)
            let source = CGImageSourceCreateWithURL(file as CFURL, nil)
            guard file.pathExtension == format.rawValue,
                  let source, CGImageSourceGetType(source) as String? == format.contentType.identifier,
                  try ImageFiles.read(file).width == 32 else { throw ReShotError(message: "保存格式与扩展名不一致") }
        }
        print("PASS: directory creation, unique filenames, PNG/JPEG/TIFF roundtrip")
    }
}
