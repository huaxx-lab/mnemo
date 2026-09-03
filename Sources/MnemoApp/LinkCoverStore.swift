import AppKit
import Foundation
import LinkPresentation
import MnemoCore

/// 链接封面。
///
/// 链接卡片原来只有一个通用的链条图标，一排链接长得完全一样，看标题才能区分。
/// `LPMetadataProvider` 抓元数据时已经把 og:image 放进 `imageProvider` 了，
/// 顺手取下来存成本地文件即可——不额外发一次网络请求，也不需要自己解析 HTML。
@MainActor
enum LinkCoverStore {
    /// 卡片上最大也就 52pt，存 2x 足够；再大只是浪费磁盘和解码时间。
    private static let maximumPixelSize: CGFloat = 240

    private static var directory: URL {
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Pinland/link-covers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func url(for itemID: UUID) -> URL {
        directory.appending(path: "\(itemID.uuidString).png")
    }

    static func cachedImage(for itemID: UUID) -> NSImage? {
        let file = url(for: itemID)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return NSImage(contentsOf: file)
    }

    static func remove(_ itemID: UUID) {
        try? FileManager.default.removeItem(at: url(for: itemID))
    }

    /// 抓标题与封面。两者都可能拿不到，各自独立。
    static func fetch(for target: URL) async -> (title: String?, cover: NSImage?) {
        let provider = LPMetadataProvider()
        provider.timeout = 8
        let metadata: LPLinkMetadata
        do {
            metadata = try await withTaskCancellationHandler {
                try await provider.startFetchingMetadata(for: target)
            } onCancel: {
                provider.cancel()
            }
        } catch {
            return (nil, nil)
        }

        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        // 视频站点的封面常常挂在 videoProvider 上，图片站点在 imageProvider。
        var cover: NSImage?
        if let source = metadata.imageProvider ?? metadata.videoProvider {
            cover = await loadImage(from: source)
        }
        // 论坛、文档站这类页面常常没有 og:image。退回站点图标——它几乎总是
        // 存在，至少让一排链接能凭图标区分开，而不是清一色的链条。
        if cover == nil { cover = await siteIcon(for: target) }
        return (title.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }, cover)
    }

    @discardableResult
    static func store(_ image: NSImage, for itemID: UUID) -> Bool {
        guard let png = downscaled(image) else { return false }
        return (try? png.write(to: url(for: itemID), options: .atomic)) != nil
    }

    /// 站点图标兜底。先试 apple-touch-icon（通常是 180px 的实心图标），
    /// 再退到 favicon.ico。
    private static func siteIcon(for target: URL) async -> NSImage? {
        guard let host = target.host() else { return nil }
        let candidates = [
            "https://\(host)/apple-touch-icon.png",
            "https://\(host)/apple-touch-icon-precomposed.png",
            "https://\(host)/favicon.ico",
        ].compactMap(URL.init(string:))

        for candidate in candidates {
            var request = URLRequest(url: candidate)
            request.timeoutInterval = 5
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
                  let image = NSImage(data: data), image.size.width > 0 else { continue }
            return image
        }
        return nil
    }

    private static func loadImage(from provider: NSItemProvider) async -> NSImage? {
        guard provider.canLoadObject(ofClass: NSImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                continuation.resume(returning: object as? NSImage)
            }
        }
    }

    /// 缩到卡片真正需要的尺寸再落盘。og:image 动辄 1200×630，原样存下来
    /// 每张几百 KB，解码也慢。
    private static func downscaled(_ image: NSImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maximumPixelSize / max(size.width, size.height))
        let target = NSSize(width: size.width * scale, height: size.height * scale)

        let output = NSImage(size: target)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        output.unlockFocus()

        guard let tiff = output.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
