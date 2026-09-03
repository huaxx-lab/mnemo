import Foundation
import PDFKit
import MnemoCore
import UniformTypeIdentifiers

/// 把一条链接变成可检索的文字。
///
/// 在这之前，链接条目的"内容"就是那串 URL 本身——语义索引里存的也是它，
/// 所以自然语言永远搜不到链接里讲了什么，更谈不上对它提问。这个工具补上
/// 中间那一步：**取回链接指向的东西，抽出文字**，之后的分块、Embedding、
/// 问答和截图那条路完全一样。
///
/// 链接指向什么不一定：网页、PDF、一张图、一段视频。所以分流按
/// **响应的 Content-Type** 走，而不是按 URL 后缀猜——后缀经常撒谎
/// （`/download?id=123` 可能是 PDF），而 Content-Type 是服务器自己说的。
@MainActor
enum LinkContentFetcher {

    /// 抓回来的东西。
    struct Fetched: Sendable {
        /// 页面标题。抓不到时为 nil，由调用方决定要不要保留原有标题。
        var title: String?
        /// 可检索的正文。
        var text: String
        /// 这条链接实际指向什么。写进分块摘要，检索结果里能看出来源类型。
        var kind: LinkContentKind
        /// 跟随重定向之后的最终地址。
        var finalURL: URL
    }

    /// 下载上限。超过就中断连接，不是读完再丢——一个几百 MB 的视频链接
    /// 会把内存和流量一起吃掉。
    static let maximumBytes = 8 * 1024 * 1024
    /// 抓取超时。
    ///
    /// 原来是 20 秒，实测不够：labuladong.online 这类文档站单页两百多 KB，
    /// 二十秒收到 235KB 还没传完，于是整条抓取失败、一个字都进不了索引，
    /// 而失败是静默的——用户只看到"模型说只有元信息"。
    ///
    /// 放宽不影响手感：这条路径跑在固定之后的后台索引里，不挡任何交互。
    static let timeout: TimeInterval = 45

    /// 只抓 http(s)。
    ///
    /// `file://` 会让"打开一个链接"变成读本地磁盘，`data:` / `javascript:`
    /// 更不该在这条路径上出现。协议白名单写死在这里，不给上层留传参的口子。
    nonisolated static func isFetchable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func fetch(_ url: URL) async -> Fetched? {
        guard isFetchable(url) else { return nil }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        // 表明身份。匿名抓取容易被当成爬虫拦掉，而且对站点不礼貌。
        // 表明身份。匿名抓取容易被当成爬虫拦掉，而且对站点不礼貌。
        //
        // 试过换成真实 Safari UA，实测更差：知乎完全没变化（它拦的不是 UA，
        // 是没有 Cookie 的裸请求），而 B 站直接从 3400 字节掉到 71 字节——
        // 伪装成浏览器反而触发了更严的风控。真正能翻过这类墙的是下面那步
        // headless 渲染：那是货真价实的 WebKit，不是伪装。
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) Mnemo/1.0 (+link preview)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        guard let (data, response) = await load(request) else { return nil }
        let finalURL = response.url ?? url
        let mime = (response.mimeType ?? "").lowercased()

        switch LinkContentKind.of(mimeType: mime, url: finalURL) {
        case .webPage:
            guard let html = decodeText(data, response: response) else { return nil }
            var extracted = LinkTextExtraction.fromHTML(html, baseURL: finalURL)

            // 静态 HTML 里没有正文，说明这是一张前端渲染的空壳页。
            //
            // 这类站点现在很常见：实测 Apple 的 HIG 页面静态抽取正文是 0 字，
            // 而维基百科同样的代码能拿到五千多字。不补这一步，"链接可以被
            // 自然语言检索"在这类站点上就是一句空话。
            //
            // 闸门是客观的——真的取到了零字，不是猜"这页可能是 SPA"。
            // 渲染一次要起 WebKit、跑页面脚本、等它加载完，秒级开销；
            // 而它挂在链接被固定之后的索引路径上，一条链接一辈子只跑一次。
            // 闸门看的是"有没有成段的正文"，不是"有多少字"。
            // 旧写法用总字数，结果一屏导航菜单就能凑够 200 字把兜底挡掉。
            if extracted.longestParagraph < LinkTextExtraction.proseParagraphLength,
               !Task.isCancelled,
               let rendered = await HeadlessPageRenderer.renderedHTML(of: finalURL) {
                let second = LinkTextExtraction.fromHTML(rendered, baseURL: finalURL)
                // 同样按正文密度取胜者：渲染后总字数可能反而更少（噪音被去掉了），
                // 但只要它有成段的正文，它就是更好的那一份。
                if second.longestParagraph > extracted.longestParagraph
                    || (second.longestParagraph == extracted.longestParagraph
                        && second.text.count > extracted.text.count) {
                    extracted = second
                }
            }

            guard !extracted.isEmpty else { return nil }
            return Fetched(
                title: extracted.title,
                text: extracted.text,
                kind: .webPage,
                finalURL: finalURL
            )

        case .pdf:
            guard let document = PDFDocument(data: data) else { return nil }
            var pages: [String] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index)?.string else { continue }
                pages.append(page)
                if pages.joined().count > LinkTextExtraction.maximumTextLength { break }
            }
            let text = LinkTextExtraction.clamp(pages.joined(separator: "\n\n"))
            guard !text.isEmpty else { return nil }
            return Fetched(
                title: document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
                text: text,
                kind: .pdf,
                finalURL: finalURL
            )

        case .image:
            // 图片链接和截图走同一条路：本机认字。链接指向一张海报、一份
            // 课表截图时，能读的就是上面那些字。
            let text = await SemanticContentExtractor.recognizeText(in: data)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Fetched(title: nil, text: LinkTextExtraction.clamp(text), kind: .image, finalURL: finalURL)

        case .video:
            // 视频本身没有可抽的文字，抓下来也只是浪费流量。这一步已经因为
            // 体积上限中断了下载；能检索的只有站点给出的标题和描述，
            // 那些由 `LinkCoverStore` 那条元数据路径负责。
            return nil

        case .plainText:
            guard let text = decodeText(data, response: response) else { return nil }
            let trimmed = LinkTextExtraction.clamp(text)
            guard !trimmed.isEmpty else { return nil }
            return Fetched(title: nil, text: trimmed, kind: .plainText, finalURL: finalURL)

        case nil:
            return nil
        }
    }

    // MARK: - 读取

    /// 流式读取并在超出上限时立刻中断。
    private static func load(_ request: URLRequest) async -> (Data, URLResponse)? {
        do {
            let (stream, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            var data = Data()
            data.reserveCapacity(min(maximumBytes, 512 * 1024))
            for try await byte in stream {
                data.append(byte)
                if data.count >= maximumBytes { break }
                if Task.isCancelled { return nil }
            }
            return (data, response)
        } catch {
            return nil
        }
    }

    /// 按响应声明的编码解码；没声明就先试 UTF-8，再试 GB18030。
    ///
    /// 国内不少站点仍在发 GBK 系列编码，只试 UTF-8 的话会整页变成乱码，
    /// 而乱码进了 Embedding 比没有内容更糟——它会污染检索结果。
    private static func decodeText(_ data: Data, response: URLResponse) -> String? {
        if let name = response.textEncodingName {
            let encoding = CFStringConvertEncodingToNSStringEncoding(
                CFStringConvertIANACharSetNameToEncoding(name as CFString)
            )
            if encoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) {
                return text
            }
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        return String(data: data, encoding: String.Encoding(rawValue: gb18030))
    }
}
