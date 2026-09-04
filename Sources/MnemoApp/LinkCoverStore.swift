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
        let platform = LinkPlatform.resolve(target)
        let metadata: LPLinkMetadata?
        if platform == .xiaohongshu {
            // 小红书的 LP 元数据常给平台 logo 或直接失败；我们自己的静态 HTML
            // 同时有真实标题、正文和 imageList，跳过一次没有收益的请求。
            metadata = nil
        } else {
            let provider = LPMetadataProvider()
            provider.timeout = 8
            let lease = await LinkFetchScheduler.acquire(for: target)
            do {
                metadata = try await withTaskCancellationHandler {
                    try await provider.startFetchingMetadata(for: target)
                } onCancel: {
                    provider.cancel()
                }
            } catch {
                // 元数据失败不代表页面没有配图，继续走 og:image / logo。
                metadata = nil
            }
            await LinkFetchScheduler.release(lease)
        }

        let title = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var cover: NSImage?

        // 小红书必须先读 imageList：LPMetadataProvider / og:image 经常给的是
        // 平台静态 logo，不是这条笔记的配图。用户要求是「真实配图优先，拿不到
        // 才用 logo」，所以这里不能先信 metadata。
        if platform == .xiaohongshu {
            cover = await openGraphImage(for: target)
        }
        // 其他站点优先系统元数据；视频封面常在 videoProvider。
        if cover == nil, let source = metadata?.imageProvider ?? metadata?.videoProvider {
            cover = await loadImage(from: source)
        }
        if cover == nil, platform != .xiaohongshu {
            cover = await openGraphImage(for: target)
        }
        // 真配图、og:image 都没有，最后才退回站点 logo。
        if cover == nil { cover = await siteIcon(for: target) }
        return (title.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }, cover)
    }

    @discardableResult
    static func store(_ image: NSImage, for itemID: UUID) -> Bool {
        guard let png = downscaled(image) else { return false }
        return (try? png.write(to: url(for: itemID), options: .atomic)) != nil
    }

    /// URLSession 请求也走同一租约；数据留在 MainActor 上，不跨 actor 传递。
    private static func loadData(_ request: URLRequest) async -> (Data, URLResponse)? {
        guard let url = request.url else { return nil }
        let lease = await LinkFetchScheduler.acquire(for: url)
        let result = try? await URLSession.shared.data(for: request)
        await LinkFetchScheduler.release(lease)
        return result
    }

    /// 页面自己声明的配图（og:image / twitter:image）。
    ///
    /// LPMetadataProvider 拿不到不等于页面没有：它带的是自己那套请求头，
    /// 在有风控的站点上会被挡掉。我们抓正文那条路能拿到 HTML，配图地址就
    /// 写在同一份 HTML 的 meta 里。
    private static func openGraphImage(for target: URL) async -> NSImage? {
        var request = URLRequest(url: target, timeoutInterval: 10)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) Mnemo/1.0 (+link preview)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = await loadData(request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .init(rawValue: 0x80000632)),
              let imageURL = SiteContentExtraction.Xiaohongshu.noteImageURL(fromHTML: html)
                ?? LinkTextExtraction.metaImageURL(html: html, baseURL: target)
        else { return nil }

        var imageRequest = URLRequest(url: imageURL, timeoutInterval: 10)
        imageRequest.setValue(target.absoluteString, forHTTPHeaderField: "Referer")
        guard let (imageData, imageResponse) = await loadData(imageRequest),
              (imageResponse as? HTTPURLResponse)
                .map({ (200..<300).contains($0.statusCode) }) == true,
              let image = NSImage(data: imageData), image.size.width > 0 else { return nil }
        return image
    }

    /// 站点图标兜底。先试 apple-touch-icon（通常是 180px 的实心图标），
    /// 再退到 favicon.ico。
    private static func siteIcon(for target: URL) async -> NSImage? {
        // 已知平台的 logo 已随应用打包：直接读本地，不为同一张图再发三次
        // apple-touch-icon/favicon 请求。linux.do 的黑白黄圆标、小红书红色标
        // 都走这里；这正是“拿不到真正配图就用 logo”。
        if let name = LinkPlatform.resolve(target)?.iconResourceName {
            for ext in ["jpg", "png"] {
                if let file = Bundle.module.url(
                    forResource: name,
                    withExtension: ext,
                    subdirectory: "ServiceIcons"
                ), let image = NSImage(contentsOf: file) {
                    return image
                }
            }
        }
        guard let host = target.host() else { return nil }
        let candidates = [
            "https://\(host)/apple-touch-icon.png",
            "https://\(host)/apple-touch-icon-precomposed.png",
            "https://\(host)/favicon.ico",
        ].compactMap(URL.init(string:))

        for candidate in candidates {
            var request = URLRequest(url: candidate)
            request.timeoutInterval = 5
            guard let (data, response) = await loadData(request),
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
