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

    nonisolated private static var directory: URL {
        let support = ProcessInfo.processInfo.environment["MNEMO_DATA_ROOT"].map {
            URL(filePath: $0, directoryHint: .isDirectory)
        } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Pinland", directoryHint: .isDirectory)
        let root = support.appending(path: "link-covers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 纯路径计算，没有任何可变状态——索引那条并发链路要用它去读缓存好的
    /// 封面文件，没必要为此跳一次主线程。
    nonisolated static func url(for itemID: UUID) -> URL {
        directory.appending(path: "\(itemID.uuidString).png")
    }

    static func cachedImage(for itemID: UUID) -> NSImage? {
        let file = url(for: itemID)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return NSImage(contentsOf: file)
    }

    /// 卡片封面和检索用配图是同一族文件，删条目时一起清。
    static func remove(_ itemID: UUID) {
        let prefix = itemID.uuidString
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    struct Preview {
        var title: String?
        var cover: NSImage?
        var ocrImages: [NSImage]
        /// 页面结构化状态真的取到了。图片下载失败不能反过来把“正文解析成功”
        /// 抹成失败；调用方用它区分“没有图”与“整页都没解析出来”。
        var pageParsed: Bool
    }

    /// 抓标题与封面。两者都可能拿不到，各自独立。
    ///
    /// `ocrImages` 是检索用的**全分辨率**配图：卡片封面落盘前会缩到 240px，
    /// 而"信息写在图上"的配图恰恰需要看清小字——喂给 OCR 的不能是卡片尺寸。
    static func fetch(for target: URL) async -> Preview {
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

        var title = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var cover: NSImage?
        var ocrImages: [NSImage] = []
        var pageParsed = metadata != nil

        // 小红书必须先读 imageList：LPMetadataProvider / og:image 经常给的是
        // 平台静态 logo，不是这条笔记的配图。用户要求是「真实配图优先，拿不到
        // 才用 logo」，所以这里不能先信 metadata。图单一次取回：第一张当封面，
        // 整单进检索——清单 / 攻略类笔记的内容分布在好几张图上。
        if platform == .xiaohongshu {
            let note = await noteImages(for: target)
            title = note.title
            cover = note.images.first
            ocrImages = note.images
            pageParsed = note.pageParsed
        }
        // 其他站点优先系统元数据；视频封面常在 videoProvider。
        if cover == nil, let source = metadata?.imageProvider ?? metadata?.videoProvider {
            cover = await loadImage(from: source)
        }
        if cover == nil, platform != .xiaohongshu {
            cover = await openGraphImage(for: target)
        }
        // 走到这一步拿到的都是页面真实配图，进检索；站点 logo 只是卡片占位，
        // 不给 OCR——一张红色 logo 识别出的"文字"只会污染检索。
        if ocrImages.isEmpty, let cover { ocrImages = [cover] }
        // 小红书不用站点 logo 兜底封面。卡片右下角本来就有一枚小红书平台徽标，
        // 再把整张封面也画成同一个红色大图标纯属重复；更要命的是
        // `refreshForIndex` 只要 cover 非 nil 就会**无条件**把它写盘覆盖旧文件——
        // 用户实报：一次被限流/风控的重新抓取，页面解析彻底失败（pageParsed
        // 还是 false），却因为这里兜底出一张 logo，把之前抓对的真实封面
        // 覆盖成了红色 logo。cover 留空时 refreshForIndex 不会碰旧文件，
        // UI 也有域名色块兜底，不会露出裸占位符。
        if cover == nil, platform != .xiaohongshu { cover = await siteIcon(for: target) }
        return Preview(
            title: title.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) },
            cover: cover,
            ocrImages: ocrImages,
            pageParsed: pageParsed
        )
    }

    static func refreshForIndex(
        _ target: URL, itemID: UUID
    ) async -> (title: String?, hasImages: Bool, coverChanged: Bool, pageParsed: Bool) {
        let preview = await fetch(for: target)
        guard !Task.isCancelled else { return (nil, false, false, false) }
        let coverChanged = preview.cover.map { store($0, for: itemID) } ?? false
        let stored = !preview.ocrImages.isEmpty && storeOCRSources(preview.ocrImages, for: itemID)
        return (preview.title, stored, coverChanged, preview.pageParsed)
    }

    /// 小红书笔记的整单配图。抓一次 HTML，把 imageList 里前几张都取回来。
    private static func noteImages(
        for target: URL
    ) async -> (title: String?, images: [NSImage], pageParsed: Bool) {
        var request = URLRequest(url: target, timeoutInterval: 10)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) Mnemo/1.0 (+link preview)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = await loadData(request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .init(rawValue: 0x80000632))
        else { return (nil, [], false) }
        guard let note = SiteContentExtraction.Xiaohongshu.note(fromHTML: html, url: target) else {
            return (nil, [], false)
        }
        var images: [NSImage] = []
        // 每张图独立成功：一张 CDN 图临时失败不应该把前面已经拿到的封面和
        // OCR 图源全部丢掉，更不能把正文/标题“解析成功”降级成整页失败。
        for imageURL in note.imageURLs {
            var imageRequest = URLRequest(url: imageURL, timeoutInterval: 10)
            imageRequest.setValue(target.absoluteString, forHTTPHeaderField: "Referer")
            guard let (imageData, imageResponse) = await loadData(imageRequest),
                  (imageResponse as? HTTPURLResponse)
                    .map({ (200..<300).contains($0.statusCode) }) == true,
                  let image = NSImage(data: imageData), image.size.width > 0 else { continue }
            images.append(image)
        }
        return (note.title, images, true)
    }

    @discardableResult
    static func store(_ image: NSImage, for itemID: UUID) -> Bool {
        guard let scaled = resized(image, maxPixel: maximumPixelSize),
              let png = bitmapData(scaled, type: .png) else { return false }
        return (try? png.write(to: url(for: itemID), options: .atomic)) != nil
    }

    /// 先写完整新一代，再换清单；失败保留上一代图源。
    @discardableResult
    static func storeOCRSources(_ images: [NSImage], for itemID: UUID) -> Bool {
        guard !images.isEmpty else { return false }
        let prefix = "\(itemID.uuidString).ocr-"
        let generation = UUID().uuidString
        let manifest = directory.appending(path: "\(itemID.uuidString).ocr.json")
        let old = ocrSourceURLs(for: itemID)
        var written: [URL] = []
        do {
            for (index, image) in images.enumerated() {
                guard let scaled = resized(image, maxPixel: ocrMaximumPixelSize),
                      let data = bitmapData(scaled, type: .jpeg, quality: 0.85) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let url = directory.appending(path: "\(prefix)\(generation)-\(index).jpg")
                try data.write(to: url, options: .atomic)
                written.append(url)
            }
            let data = try JSONEncoder().encode(written.map(\.lastPathComponent))
            try data.write(to: manifest, options: .atomic)
            for url in old { try? FileManager.default.removeItem(at: url) }
            return true
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            return false
        }
    }

    /// 已缓存的检索用配图，按下标顺序；空数组时调用方退回卡片封面。
    ///
    /// 纯路径与目录枚举，没有任何可变状态——索引那条并发链路要用它去读缓存
    /// 好的文件，没必要为此跳一次主线程。
    nonisolated static func ocrSourceURLs(for itemID: UUID) -> [URL] {
        let prefix = "\(itemID.uuidString).ocr-"
        let manifest = directory.appending(path: "\(itemID.uuidString).ocr.json")
        if let data = try? Data(contentsOf: manifest),
           let files = try? JSONDecoder().decode([String].self, from: data) {
            return files.filter { $0.hasPrefix(prefix) && !$0.contains("/") }
                .map { directory.appending(path: $0) }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        // 下标是个位数（图单有上限），字典序即数值序。
        return names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".jpg") }
            .sorted()
            .map { directory.appending(path: $0) }
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

    /// OCR 输入的上限。1,600px 对图文混排的识别已经足够，再大只是磁盘和解码时间。
    private static let ocrMaximumPixelSize: CGFloat = 1_600

    /// 缩到目标尺寸。og:image 动辄 1200×630 往上，原样存下来每张几百 KB，
    /// 解码也慢。
    private static func resized(_ image: NSImage, maxPixel: CGFloat) -> NSImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxPixel / max(size.width, size.height))
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
        return output
    }

    private static func bitmapData(
        _ image: NSImage,
        type: NSBitmapImageRep.FileType,
        quality: Double? = nil
    ) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        var properties: [NSBitmapImageRep.PropertyKey: Any] = [:]
        if let quality { properties[.compressionFactor] = quality }
        return bitmap.representation(using: type, properties: properties)
    }
}
