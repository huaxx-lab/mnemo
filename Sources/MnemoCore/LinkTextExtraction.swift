import Foundation
import SwiftSoup
import UniformTypeIdentifiers

/// 链接指向的东西是什么。
///
/// 按**响应的 Content-Type** 判定，不按 URL 后缀猜——后缀经常撒谎
/// （`/download?id=123` 可能是 PDF，`/photo` 可能返回 HTML），
/// Content-Type 是服务器自己声明的，只有它缺失时才退回后缀。
public enum LinkContentKind: String, Sendable, Equatable {
    case webPage, pdf, image, video, plainText

    public static func of(mimeType: String, url: URL) -> LinkContentKind? {
        let mime = mimeType.lowercased()
        if mime.contains("html") || mime.contains("xhtml") { return .webPage }
        if mime.contains("pdf") { return .pdf }
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("video/") || mime.hasPrefix("audio/") { return .video }
        if mime.hasPrefix("text/") || mime.contains("json") || mime.contains("xml") {
            return .plainText
        }
        // 服务器没给类型，或者给了个 application/octet-stream 时才退回后缀。
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .audio) { return .video }
        if type.conforms(to: .html) { return .webPage }
        if type.conforms(to: .text) { return .plainText }
        return nil
    }
}

/// 从 HTML 里取标题和正文。
///
/// 解析交给 SwiftSoup（写一个正确的 HTML 解析器是别人已经做好、且做得比我们
/// 好的事），取舍规则留在这里，因为它决定检索质量：
///
/// 1. **先扔掉整棵不可能是正文的子树**（脚本、样式、导航、页脚、评论、广告）。
///    这一步比"挑正文"更重要——导航和页脚在同一个站点的每一页上都一样，
///    留着会让所有页面的向量互相靠拢，检索时一搜全中。
/// 2. 再按 `article` → `main` → `[role=main]` → `#content` → `body` 挑子树。
/// 3. 块级元素之间补换行，否则整页挤成一行，分块会切在句子中间，
///    检索出来的片段读着是断的。
public enum LinkTextExtraction {

    /// 正文上限。分块本身有重叠切分，再长也只是让 Embedding 变贵而检索质量不变。
    public static let maximumTextLength = 40_000
    /// 认定"这一棵子树确实是正文"的最小字数。太短说明挑错了，继续往下退。
    public static let minimumBodyLength = 200

    public struct Extracted: Sendable, Equatable {
        public var title: String?
        public var text: String
        /// 页面自报的摘要（`og:description` / `meta[name=description]`）。
        ///
        /// 对前端渲染的站点这经常是**唯一**能匿名拿到的正文。实测小红书的
        /// 笔记全文就写在这里，而 DOM 里一个字都没有——不读它，这类链接
        /// 永远停在"无法获取内容"。
        public var summary: String?
        /// 内容天然的分段（论坛的一层楼、一条评论）。
        ///
        /// 有了它，切块就能按**语义边界**走而不是按字数：一层楼一块，检索命中
        /// 时指向的是具体某个人说的某句话，而不是横跨两条不相干回复的片段。
        public var segments: [String]?

        public init(
            title: String?, text: String, summary: String? = nil, segments: [String]? = nil
        ) {
            self.title = title
            self.text = text
            self.summary = summary
            self.segments = segments
        }

        public var isEmpty: Bool { text.isEmpty }

        /// 最长的一个自然段有多少字。
        ///
        /// 判"这页有没有正文"不能只看总字数：一屏导航菜单轻松几百字，但
        /// 每一条都是两三个词。实测阿里云控制台静态抽取拿到 292 字，全是
        /// 左侧菜单项，于是"字数够了"这个闸门放行，真正的正文再也没机会抓。
        /// 正文的特征是**至少有一个成段的句子**，导航永远没有。
        public var longestParagraph: Int {
            text.split(whereSeparator: \.isNewline).map(\.count).max() ?? 0
        }
    }

    /// 一个自然段至少这么长才算正文。低于它就认为整页还是空壳 / 导航。
    public static let proseParagraphLength = 120

    private static let noiseSelectors = [
        "script", "style", "noscript", "template", "svg", "canvas", "iframe",
        "nav", "header", "footer", "aside", "form", "button", "select",
        "[role=navigation]", "[role=banner]", "[role=contentinfo]", "[aria-hidden=true]",
        ".nav", ".navbar", ".menu", ".sidebar", ".footer", ".header", ".breadcrumb",
        ".comment", ".comments", ".advertisement", ".ad", ".ads", ".cookie", ".popup",
    ]

    private static let bodySelectors = [
        "article", "main", "[role=main]", "#content", ".content", ".post", ".article", "body",
    ]

    /// 块级标签之间补换行用的选择器。
    private static let blockSelectors =
        "p, div, li, tr, h1, h2, h3, h4, h5, h6, br, section, blockquote, pre, dd, dt"

    public static func fromHTML(_ html: String, baseURL: URL? = nil) -> Extracted {
        guard let document = try? SwiftSoup.parse(html, baseURL?.absoluteString ?? "") else {
            return Extracted(title: nil, text: "")
        }
        let rawTitle = (try? document.title())?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle?.isEmpty == false ? rawTitle : nil
        // 摘要要在删噪音之前取：head 里的 meta 不该受正文选择器影响。
        let summary = metaSummary(document)

        for selector in noiseSelectors {
            try? document.select(selector).remove()
        }

        var chosen: Element?
        for selector in bodySelectors {
            guard let element = try? document.select(selector).first(),
                  let text = try? element.text(),
                  text.count >= minimumBodyLength else { continue }
            chosen = element
            break
        }
        guard let root = chosen ?? document.body() else {
            return Extracted(title: title, text: "", summary: summary)
        }

        if let elements = try? root.select(blockSelectors) {
            for element in elements.array() {
                try? element.after("\n")
            }
        }

        let raw = (try? root.text(trimAndNormaliseWhitespace: false)) ?? ""
        return Extracted(title: title, text: clamp(normalize(raw)), summary: summary)
    }

    /// 页面自报的配图地址。相对地址按页面地址补全。
    public static func metaImageURL(html: String, baseURL: URL?) -> URL? {
        guard let document = try? SwiftSoup.parse(html, baseURL?.absoluteString ?? "") else {
            return nil
        }
        for query in ["meta[property=og:image]", "meta[name=twitter:image]", "meta[itemprop=image]"] {
            guard let element = try? document.select(query).first(),
                  let raw = try? element.attr("content") else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let absolute = URL(string: trimmed), absolute.scheme != nil { return absolute }
            if let base = baseURL, let relative = URL(string: trimmed, relativeTo: base) {
                return relative.absoluteURL
            }
        }
        return nil
    }

    /// 页面自报的摘要。`og:description` 优先——它是给分享卡片准备的，通常比
    /// SEO 用的 `description` 更贴近正文。
    private static let summaryQueries = [
        "meta[property=og:description]",
        "meta[name=description]",
        "meta[name=twitter:description]",
    ]

    static func metaSummary(_ document: Document) -> String? {
        for query in summaryQueries {
            guard let element = try? document.select(query).first(),
                  let content = try? element.attr("content") else { continue }
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            return normalize(text)
        }
        return nil
    }

    /// 压掉连续空白与空行。
    ///
    /// 网页里的缩进会在正文里留下大片空洞：既占分块预算，又让同一段话被切成
    /// 好几块，每一块都拿不到完整语义。
    public static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\u{200b}", with: "")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n[ \t]*"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 旧抓取失败时误存成卡片标题的状态文案。无论 `titledLocally` 历史值
    /// 是什么，它们都不是用户标题，抓到真实网页标题后必须允许替换。
    public static func isFailurePlaceholderTitle(_ title: String) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "无法访问链接内容",
            "无法访问该链接内容",
            "无法获取内容",
            "Loading...",
            "Loading…",
        ].contains(value)
    }

    public static func clamp(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumTextLength else { return trimmed }
        return String(trimmed.prefix(maximumTextLength))
    }
}
