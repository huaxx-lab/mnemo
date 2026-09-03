import AppKit
import ImageIO
import PDFKit
import MnemoCore

private struct DecodedThumbnail: @unchecked Sendable {
    let image: NSImage
}

/// 缩略图只在可见卡片请求时生成。解码在 utility 线程完成，缓存有硬上限，
/// 避免大图完整解码与无限增长同时伤害交互帧和内存。
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 160
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    func image(item: Item, url: URL?, logicalSize: CGFloat) async -> NSImage? {
        guard let url else { return nil }
        // 卡片是裁剪填充：`kCGImageSourceThumbnailMaxPixelSize` 限制的是**长边**，
        // 而填充要靠短边盖满。一张宽图按长边取到 144px，短边可能只有 80px，
        // 铺进 52pt（104px）的方格里就是在放大——这正是缩略图发糊的原因。
        // 小尺寸多取一档；大图仍按 2 倍，否则单张就要吃掉几十 MB 缓存。
        let oversample: CGFloat = logicalSize <= 200 ? 3 : 2
        let pixelSize = max(64, Int(ceil(logicalSize * oversample)))
        let key = cacheKey(item: item, url: url, pixelSize: pixelSize) as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let trace = PerformanceTrace.begin("ThumbnailDecode")
        defer { PerformanceTrace.end("ThumbnailDecode", id: trace) }

        let decoded: DecodedThumbnail?
        switch item.kind {
        case .image:
            decoded = await Task.detached(priority: .utility) {
                autoreleasepool {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(
                            source,
                            0,
                            [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                                kCGImageSourceShouldCacheImmediately: true,
                            ] as CFDictionary
                          ) else { return nil }
                    return DecodedThumbnail(image: NSImage(cgImage: image, size: .zero))
                }
            }.value
        case .pdf:
            decoded = await Task.detached(priority: .utility) {
                autoreleasepool {
                    guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
                    return DecodedThumbnail(image: page.thumbnail(
                        of: CGSize(width: pixelSize, height: pixelSize),
                        for: .cropBox
                    ))
                }
            }.value
        default:
            decoded = DecodedThumbnail(image: NSWorkspace.shared.icon(forFile: url.path))
        }
        guard let image = decoded?.image else { return nil }
        cache.setObject(image, forKey: key, cost: pixelSize * pixelSize * 4)
        return image
    }

    private func cacheKey(item: Item, url: URL, pixelSize: Int) -> String {
        let version = item.sourceModificationDate?.timeIntervalSince1970.description
            ?? item.contentHash
            ?? "immutable"
        return "\(item.id.uuidString)|\(url.path)|\(version)|\(pixelSize)"
    }
}
