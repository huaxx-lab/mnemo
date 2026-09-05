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
        /// 内容天然的分段（论坛的一层楼）。有就按它切块，没有就按字数切。
        var segments: [String]?
    }

    /// 站点各自的结构化出口。全部是这些站点**自己公开的**接口或内嵌状态，
    /// 判据也来自页面自报的身份，不做域名硬编码之外的猜测。
    private static func structuredExtraction(
        html: String, url: URL, request: URLRequest
    ) async -> LinkTextExtraction.Extracted? {
        // Discourse：话题页是 Ember 空壳，同一个地址加 `.json` 就是整串楼层。
        // linux.do 是已知 Discourse；即便 HTML 恰好是 Cloudflare challenge，
        // 仍直接尝试官方 topic JSON。其他论坛继续靠 generator 自报识别。
        if (LinkPlatform.resolve(url) == .linuxdo
                || SiteContentExtraction.Discourse.isDiscoursePage(html)),
           let jsonURL = SiteContentExtraction.Discourse.topicJSONURL(for: url) {
            var jsonRequest = request
            jsonRequest.url = jsonURL
            if let (data, _) = await load(jsonRequest),
               let extracted = SiteContentExtraction.Discourse.extract(fromTopicJSON: data) {
                return extracted
            }
        }
        // 小红书：标题、正文、配图都从同一条 noteDetailMap[id] 记录一次解出。
        // 不再对同一份 HTML 独立扫三遍“第一个同名字段”——页面里还有推荐流、
        // 评论等同名键，独立扫描迟早会串到别的记录。
        if LinkPlatform.resolve(url) == .xiaohongshu,
           let note = SiteContentExtraction.Xiaohongshu.note(fromHTML: html, url: url),
           !note.text.isEmpty || note.title != nil {
            return LinkTextExtraction.Extracted(
                title: note.title,
                text: LinkTextExtraction.clamp(note.text.isEmpty ? note.title ?? "" : note.text),
                // 清单体正文按作者换的行分段，分块不再把相邻条目拦腰切断。
                segments: note.segments
            )
        }
        // GitHub 仓库页：正文是文件树和导航，真正有检索价值的 README 在
        // article.markdown-body 里，通用抽取拿不到。
        if let repository = SiteContentExtraction.GitHub.extract(fromHTML: html, url: url) {
            return repository
        }
        return nil
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

        // linux.do 已知是 Discourse，直接走官方 topic JSON：少一次 Ember 空壳
        // HTML 请求，也不依赖 HTML 的 generator 是否被 Cloudflare challenge 替换。
        if LinkPlatform.resolve(url) == .linuxdo,
           let jsonURL = SiteContentExtraction.Discourse.topicJSONURL(for: url) {
            var jsonRequest = standardRequest(for: jsonURL)
            jsonRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            if let (data, response) = await load(jsonRequest),
               let extracted = SiteContentExtraction.Discourse.extract(fromTopicJSON: data) {
                return Fetched(
                    title: extracted.title,
                    text: extracted.text,
                    kind: .webPage,
                    finalURL: response.url ?? url,
                    segments: extracted.segments
                )
            }
            // JSON 临时失败才退回通用网页路径；旧 RAG 在整个刷新失败时仍保留。
        }

        var request = standardRequest(for: url)
        guard let (data, response) = await load(request) else { return nil }
        let finalURL = response.url ?? url
        let mime = (response.mimeType ?? "").lowercased()

        switch LinkContentKind.of(mimeType: mime, url: finalURL) {
        case .webPage:
            guard let html = decodeText(data, response: response) else { return nil }
            let generic = LinkTextExtraction.fromHTML(html, baseURL: finalURL)

            // 站点自己提供的结构化正文优先于通用 DOM。
            //
            // 旧顺序是「通用结果太短才尝试结构化」：小红书登录框 + 评论区很容易
            // 凑出一段超过 120 字，于是它被误判成正文，真正的 __INITIAL_STATE__
            // 永远没有机会执行。结构化出口是页面自己的权威数据，不能拿噪音长度
            // 跟它竞赛。linux.do 同理：Discourse JSON 才是帖子正文，Ember 外壳不是。
            var extracted: LinkTextExtraction.Extracted
            if let structured = await structuredExtraction(
                html: html, url: finalURL, request: request
            ) {
                extracted = structured
            } else if LinkPlatform.resolve(finalURL) == .xiaohongshu {
                // 结构化解析（含它内部的 JSON-LD/meta 兜底）都失败了才会走到这里——
                // 通常意味着这次响应根本不是这条笔记，而是被限流/风控时的通用页。
                // 那种页面的 og:title 就是网站自己的标语"小红书 - 你的生活兴趣
                // 社区"，绝不能当作笔记标题写回；summary 同理可能只是通用摘要，
                // 不是登录墙也不是这条笔记的内容，写进 RAG 只会污染检索。
                guard let summary = generic.summary,
                      !SiteContentExtraction.Xiaohongshu.isLoginWall(summary) else { return nil }
                let title = generic.title.flatMap {
                    SiteContentExtraction.Xiaohongshu.isGenericSiteTitle($0) ? nil : $0
                }
                extracted = LinkTextExtraction.Extracted(
                    title: title,
                    text: summary,
                    summary: summary
                )
            } else {
                extracted = generic
                // 普通前端站点没有结构化出口时，静态 DOM 太稀才启动 WebKit。
                if extracted.longestParagraph < LinkTextExtraction.proseParagraphLength,
                   !Task.isCancelled,
                   let rendered = await HeadlessPageRenderer.renderedHTML(of: finalURL) {
                    let second = LinkTextExtraction.fromHTML(rendered, baseURL: finalURL)
                    if second.longestParagraph > extracted.longestParagraph
                        || (second.longestParagraph == extracted.longestParagraph
                            && second.text.count > extracted.text.count) {
                        extracted = second
                    }
                }
            }

            // 最后的兜底：页面自报的摘要。对没有专用结构化出口的 SPA，
            // 它可能是唯一能匿名拿到的内容。
            if extracted.longestParagraph < LinkTextExtraction.proseParagraphLength,
               let summary = extracted.summary ?? generic.summary,
               summary.count > extracted.text.count {
                extracted = LinkTextExtraction.Extracted(
                    title: extracted.title ?? generic.title,
                    text: summary,
                    summary: summary
                )
            }

            guard !extracted.isEmpty else { return nil }
            if LinkPlatform.resolve(finalURL) == .xiaohongshu,
               SiteContentExtraction.Xiaohongshu.isLoginWall(extracted.text) {
                return nil
            }
            return Fetched(
                title: extracted.title,
                text: extracted.text,
                kind: .webPage,
                finalURL: finalURL,
                segments: extracted.segments
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

    private static func standardRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        // 统一请求头画像见 `BrowserRequestHeaders`；之前这里用的是自报家门的
        // `Mnemo/1.0 (+link preview)`，对有风控的站点是最简单的机器人特征。
        BrowserRequestHeaders.apply(.document, to: &request)
        return request
    }

    // MARK: - 读取

    /// 流式读取并在超出上限时立刻中断。
    /// 被限流时最多退让重试几次。
    ///
    /// 批量重抓时同一个站点会连着来好几条（用户收藏的往往就集中在几个站），
    /// 429 是必然会撞上的。之前撞上就当作"这条抓不到"永久放弃——而它只是
    /// 让我们等一会儿。这条路径跑在后台索引里，等几秒不挡任何交互。
    private static let rateLimitRetries = 2

    private static func load(_ request: URLRequest, attempt: Int = 0) async -> (Data, URLResponse)? {
        guard let url = request.url else { return nil }
        // 租约覆盖“发请求 + 把响应流读完”整个周期，不只是错开发车时刻。
        let lease = await LinkFetchScheduler.acquire(for: url)
        let loaded: (Data, URLResponse)?
        do {
            let (stream, response) = try await URLSession.shared.bytes(for: request)
            var data = Data()
            data.reserveCapacity(min(maximumBytes, 512 * 1024))
            for try await byte in stream {
                data.append(byte)
                if data.count >= maximumBytes { break }
                if Task.isCancelled { throw CancellationError() }
            }
            loaded = (data, response)
        } catch {
            loaded = nil
        }
        await LinkFetchScheduler.release(lease)
        guard let (data, response) = loaded else { return nil }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // 429 / 503 是“稍后再来”，不是“没有这个东西”。重试会重新排队，
            // 不会在等待 Retry-After 时霸占全局通道。
            if [429, 503].contains(http.statusCode), attempt < rateLimitRetries {
                let advised = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let wait = min(max(advised ?? Double(attempt + 1) * 3, 1), 15)
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return nil }
                return await load(request, attempt: attempt + 1)
            }
            return nil
        }
        return (data, response)
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
