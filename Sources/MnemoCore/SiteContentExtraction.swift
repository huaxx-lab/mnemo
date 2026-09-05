import Foundation
import SwiftSoup

/// 有些站点的正文根本不在静态 HTML 里，但它们**自己提供了结构化出口**。
///
/// 通用抽取器对这类站点是无解的：它按 DOM 找正文，而服务器返回的就是一个
/// 空壳。此前 linux.do、小红书的卡片一律显示"无法访问该链接内容"——实测下来
/// 两者既没有拦爬虫、也不需要登录（linux.do 的 topic 页匿名返回 200，小红书
/// 整篇笔记就写在 meta description 里），纯粹是我们没去它们各自的出口取。
///
/// 判据一律客观：URL 形状 + 页面自报的 generator / 内嵌状态，不猜。
public enum SiteContentExtraction {

    // MARK: - Discourse（linux.do 及所有 Discourse 论坛）

    /// Discourse 的话题页是 Ember 单页应用，服务器返回的 HTML 里**一个帖子
    /// 正文都没有**（实测 52KB 里 `post` 节点为 0），但同一个地址加 `.json`
    /// 就能匿名拿到整串楼层。这是 Discourse 自己的公开接口，不是绕过什么。
    public enum Discourse {
        /// 话题页的形状：`/t/<slug>/<id>` 或 `/t/topic/<id>`，后面可带楼层号。
        public static func topicJSONURL(for url: URL) -> URL? {
            let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 3, parts[0] == "t",
                  parts.dropFirst().contains(where: { Int($0) != nil }) else { return nil }
            // 只保留到话题 id 为止：`/t/slug/123/45` 的 `.json` 要挂在 123 上，
            // 带着楼层号请求会 404。
            guard let idIndex = parts.indices.dropFirst().first(where: { Int(parts[$0]) != nil })
            else { return nil }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            components?.fragment = nil
            components?.path = "/" + parts[0...idIndex].joined(separator: "/") + ".json"
            return components?.url
        }

        /// 页面自己声明的。不靠域名白名单——任何 Discourse 论坛都该同样受益。
        public static func isDiscoursePage(_ html: String) -> Bool {
            guard let document = try? SwiftSoup.parse(html) else { return false }
            if let element = try? document.select("meta[name=generator]").first(),
               let generator = try? element.attr("content"),
               generator.localizedCaseInsensitiveContains("discourse") {
                return true
            }
            // 没有 generator 也可能是 Discourse：它总会往页面里塞这个配置节点。
            let setup = try? document.select("#data-discourse-setup").first()
            return setup ?? nil != nil
        }

        private struct Payload: Decodable {
            struct Stream: Decodable { var posts: [Post]? }
            struct Post: Decodable {
                var cooked: String?
                var username: String?
                var post_number: Int?
            }
            var title: String?
            var post_stream: Stream?
        }

        /// 把整串楼层拼成可检索的正文。楼层之间标出楼号和作者——检索命中时
        /// 能看出这句话是谁在第几楼说的，比糊成一片有用。
        public static func extract(fromTopicJSON data: Data) -> LinkTextExtraction.Extracted? {
            guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
                return nil
            }
            let posts = payload.post_stream?.posts ?? []
            guard !posts.isEmpty else { return nil }
            var blocks: [String] = []
            for post in posts {
                guard let cooked = post.cooked,
                      let text = try? SwiftSoup.parse(cooked).text(),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let head = [post.post_number.map { "#\($0)" }, post.username]
                    .compactMap { $0 }
                    .joined(separator: " ")
                blocks.append(head.isEmpty ? text : "\(head)：\(text)")
            }
            guard !blocks.isEmpty else { return nil }
            let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let topic = title?.isEmpty == false ? title : nil
            // 每一层楼都带上主题名：检索召回的是单独一块，没有标题它就不知道
            // 自己属于哪个帖子，答案里也无从交代出处。
            let segments = topic.map { name in blocks.map { "《\(name)》\n\($0)" } } ?? blocks
            return LinkTextExtraction.Extracted(
                title: topic,
                text: LinkTextExtraction.clamp(blocks.joined(separator: "\n\n")),
                segments: segments
            )
        }
    }

    // MARK: - 小红书

    /// 笔记正文写在 `window.__INITIAL_STATE__` 里的 `desc` 字段。
    ///
    /// meta description 也有一份，但会被截断（实测 206 字 vs 432 字），而且
    /// 丢掉了换行。这里优先取完整的那份，取不到再由通用的 meta 兜底。
    public enum Xiaohongshu {
        /// 小红书登录墙的稳定指纹。至少命中两项才判定，避免普通正文恰好
        /// 提到“登录”或“隐私政策”就被误杀。
        public static func isLoginWall(_ text: String) -> Bool {
            let markers = ["扫码", "手机号登录", "用户协议", "隐私政策", "新用户可直接"]
            return markers.reduce(0) { $0 + (text.contains($1) ? 1 : 0) } >= 2
        }

        /// 从一份页面快照一次抽出目标笔记的标题、正文和所有配图。
        ///
        /// 优先解 `__INITIAL_STATE__` 的 JSON。这里不用“全页找第一个 title/desc/
        /// imageList”：同一页还有推荐流、评论、登录态等模块，它们也会出现这些键，
        /// 三个独立扫描器早晚会各自命中不同记录。现在先根据 URL 的 note id 定位
        /// `noteDetailMap[id]`，没有 URL 才在恰好只有一条记录时安全回退。
        ///
        /// 页面状态是 JavaScript，不是严格 JSON，值里偶尔会出现裸 `undefined`。
        /// 只在**字符串外**把它替换成 null，再交给 JSONSerialization；不能简单做
        /// 全文 replace，否则作者正文里真的写了 “undefined” 也会被改坏。
        public static func note(
            fromHTML html: String,
            url: URL? = nil,
            imageLimit: Int = 6
        ) -> XiaohongshuNoteExtraction? {
            guard let state = initialStateJSON(in: html),
                  let object = try? JSONSerialization.jsonObject(with: Data(state.utf8)),
                  let root = object as? [String: Any],
                  // 线上结构是 note.noteDetailMap；早期页面与已有归档样本把
                  // noteDetailMap 直接放根上。两种都是平台真实出现过的结构，
                  // 统一入口必须都认，不能为了“更严格”把旧页面全部判坏。
                  let map = ((root["note"] as? [String: Any])?["noteDetailMap"]
                        ?? root["noteDetailMap"]) as? [String: Any],
                  let record = selectedRecord(in: map, url: url),
                  let rawNote = record["note"] as? [String: Any]
            else { return fallbackNote(fromHTML: html, url: url, imageLimit: imageLimit) }

            let body = cleaned(rawNote["desc"] as? String ?? "")
            let authoredTitle = cleaned(rawNote["title"] as? String ?? "")
            let resolvedTitle = authoredTitle.isEmpty ? leadingSentence(of: body) : authoredTitle
            let images = imageURLs(from: rawNote["imageList"], limit: imageLimit)
            let lines = body
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return XiaohongshuNoteExtraction(
                title: resolvedTitle,
                text: body,
                imageURLs: images,
                segments: lines.count > 1 ? lines : nil
            )
        }

        /// 兼容原有调用方的窄出口。新代码应优先调用 `note(fromHTML:url:)`，避免
        /// 同一份 HTML 被解三遍；这些出口保留给核心层行为测试和简单调用。
        public static func noteImageURLs(fromHTML html: String, limit: Int = 6) -> [URL] {
            note(fromHTML: html, imageLimit: limit)?.imageURLs ?? []
        }

        public static func noteImageURL(fromHTML html: String) -> URL? {
            noteImageURLs(fromHTML: html, limit: 1).first
        }

        public static func title(fromHTML html: String) -> String? {
            note(fromHTML: html)?.title
        }

        public static func extract(fromHTML html: String) -> String? {
            let text = note(fromHTML: html)?.text ?? ""
            return text.isEmpty ? nil : text
        }

        public static func bodySegments(fromHTML html: String) -> [String]? {
            note(fromHTML: html)?.segments
        }

        /// 话题标记。原文写作 `#考研人[话题]#`，`[话题]#` 是平台内部记号，
        /// 不是作者正文。词本身保留，平台记号去掉。
        public static func cleaned(_ text: String) -> String {
            text.replacingOccurrences(
                of: #"\[话题\]#"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func selectedRecord(
            in map: [String: Any],
            url: URL?
        ) -> [String: Any]? {
            if let id = noteID(from: url), let record = map[id] as? [String: Any] {
                return record
            }
            guard map.count == 1 else { return nil }
            return map.values.first as? [String: Any]
        }

        private static func noteID(from url: URL?) -> String? {
            guard let url else { return nil }
            let parts = url.pathComponents.filter { $0 != "/" }
            guard let marker = parts.firstIndex(where: { $0 == "explore" || $0 == "discovery" }),
                  parts.indices.contains(marker + 1) else { return nil }
            let id = parts[marker + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : id
        }

        private static func imageURLs(from value: Any?, limit: Int) -> [URL] {
            guard limit > 0, let records = value as? [[String: Any]] else { return [] }
            var seen: Set<String> = []
            var result: [URL] = []
            for record in records {
                let info = record["infoList"] as? [[String: Any]] ?? []
                let raw = (record["urlDefault"] as? String)
                    ?? info.first(where: { ($0["imageScene"] as? String) == "WB_DFT" })?["url"] as? String
                    ?? (record["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? info.compactMap { $0["url"] as? String }.first
                guard let raw, !raw.isEmpty,
                      var components = URLComponents(string: raw),
                      seen.insert(raw).inserted else { continue }
                if components.scheme?.lowercased() == "http" { components.scheme = "https" }
                guard let url = components.url else { continue }
                result.append(url)
                if result.count >= limit { break }
            }
            return result
        }

        private static func initialStateJSON(in html: String) -> String? {
            guard let marker = html.range(of: "__INITIAL_STATE__") else { return nil }
            var index = marker.upperBound
            while index < html.endIndex, html[index] != "=" { index = html.index(after: index) }
            guard index < html.endIndex else { return nil }
            index = html.index(after: index)
            while index < html.endIndex, html[index].isWhitespace { index = html.index(after: index) }
            guard index < html.endIndex, html[index] == "{" else { return nil }

            let start = index
            var depth = 0
            var inString = false
            var escaped = false
            while index < html.endIndex {
                let character = html[index]
                if inString {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { inString = false }
                } else {
                    switch character {
                    case "\"": inString = true
                    case "{": depth += 1
                    case "}":
                        depth -= 1
                        if depth == 0 {
                            let literal = String(html[start...index])
                            return replacingUndefinedOutsideStrings(in: literal)
                        }
                    default: break
                    }
                }
                index = html.index(after: index)
            }
            return nil
        }

        private static func replacingUndefinedOutsideStrings(in text: String) -> String {
            var result = ""
            var index = text.startIndex
            var inString = false
            var escaped = false
            while index < text.endIndex {
                let character = text[index]
                if inString {
                    result.append(character)
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { inString = false }
                    index = text.index(after: index)
                    continue
                }
                if character == "\"" {
                    inString = true
                    result.append(character)
                    index = text.index(after: index)
                    continue
                }
                let previous = index > text.startIndex ? text[text.index(before: index)] : nil
                let afterUndefined = text.index(index, offsetBy: "undefined".count, limitedBy: text.endIndex)
                let next = afterUndefined.flatMap { $0 < text.endIndex ? text[$0] : nil }
                let isIdentifier: (Character?) -> Bool = { character in
                    character.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" } ?? false
                }
                if text[index...].hasPrefix("undefined"),
                   !isIdentifier(previous), !isIdentifier(next),
                   let afterUndefined {
                    result.append("null")
                    index = afterUndefined
                } else {
                    result.append(character)
                    index = text.index(after: index)
                }
            }
            return result
        }

        /// 平台自己的通用兜底标题/标语。整个网站在拿不到具体笔记时（被限流、
        /// 需要登录、笔记被删、临时风控……）都会回落到这一句，og:title 和
        /// `<title>` 完全一致，跟任何一条真实笔记都无关。
        ///
        /// 这不是某一条笔记的兜底文案，是**整个域名**的默认页标题——用户实报：
        /// 一次后台批量迁移撞上这种响应，五条毫不相关的笔记被同时写成一模
        /// 一样的"小红书 - 你的生活兴趣社区"，还带着 titleOrigin=page 的权威
        /// 标记，把之前抓对的真标题顶掉了。必须在写回前识别并拒绝，而不是
        /// 事后指望下一次迁移侥幸修正。
        private static let genericSiteTaglines = ["你的生活兴趣社区"]

        /// 公开这条判据：任何把小红书 og:title / `<title>` 当候选标题的地方
        /// （不只是这个文件内部的 JSON-LD 兜底）都必须先过一遍这道闸，不能
        /// 各自维护一份、迟早漏一处。
        public static func isGenericSiteTitle(_ title: String) -> Bool {
            genericSiteTaglines.contains { title.contains($0) }
        }

        /// 极少数页面把状态拆成平台暂时无法解码的 JS 表达式时，用 JSON-LD / meta
        /// 保住标题、正文、首图。这个兜底不扫 DOM 登录框，不会把登录墙写进 RAG。
        private static func fallbackNote(
            fromHTML html: String,
            url: URL?,
            imageLimit: Int
        ) -> XiaohongshuNoteExtraction? {
            guard let document = try? SwiftSoup.parse(html, url?.absoluteString ?? "") else { return nil }
            let rawTitle = (try? document.select("meta[property=og:title]").first()?.attr("content"))
                .flatMap(titleFromDocumentTitle)
                ?? (try? document.title()).flatMap(titleFromDocumentTitle)
            // og:title / <title> 命中整站默认标语，说明这整份响应根本不是这条
            // 笔记（限流/需要登录/笔记被删），而是网站自己的通用页——不只标题
            // 不可信，og:description、og:image 大概率也是同一份通用页的内容，
            // 不是这条笔记的。整份响应当场判失败，不逐字段各自决定要不要信，
            // 那样迟早会有一个字段被漏判成"看着还行"。
            guard rawTitle.map({ !isGenericSiteTitle($0) }) ?? true else { return nil }
            let title = rawTitle
            let text = [
                try? document.select("meta[property=og:description]").first()?.attr("content"),
                try? document.select("meta[name=description]").first()?.attr("content"),
            ].compactMap { $0 }
                .map(cleaned)
                .first(where: { !$0.isEmpty && !isLoginWall($0) }) ?? ""
            var images: [URL] = []
            if imageLimit > 0,
               let image = LinkTextExtraction.metaImageURL(html: html, baseURL: url) {
                var components = URLComponents(url: image, resolvingAgainstBaseURL: true)
                if components?.scheme?.lowercased() == "http" { components?.scheme = "https" }
                if let resolved = components?.url { images = [resolved] }
            }
            guard title != nil || !text.isEmpty || !images.isEmpty else { return nil }
            let lines = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return XiaohongshuNoteExtraction(
                title: title ?? leadingSentence(of: text),
                text: text,
                imageURLs: Array(images.prefix(imageLimit)),
                segments: lines.count > 1 ? lines : nil
            )
        }

        private static func titleFromDocumentTitle(_ raw: String) -> String? {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            for suffix in [" - 小红书", " | 小红书", " · 小红书"] where value.hasSuffix(suffix) {
                value.removeLast(suffix.count)
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        /// 正文首句，用作作者没有填标题时的替代。
        static func leadingSentence(of text: String) -> String? {
            guard let line = text
                .split(whereSeparator: \.isNewline)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty })
            else { return nil }
            if line.count <= 50 { return line }
            let breaks: Set<Character> = ["。", "！", "？", "，", "；", "、", ".", "!", "?", ","]
            let head = line.prefix(50)
            if let cut = head.lastIndex(where: { breaks.contains($0) }),
               head.distance(from: head.startIndex, to: cut) >= 12 {
                return String(head[..<cut])
            }
            return String(head)
        }
    }

    /// GitHub 仓库页。
    ///
    /// 通用正文抽取在这里几乎没用：页面主体是文件树、导航和一堆按钮，
    /// 真正有检索价值的 README 藏在 `article.markdown-body` 里，而标题
    /// `GitHub - owner/repo: 描述 · GitHub` 前后各挂着一段平台样板。
    ///
    /// 不打 api.github.com：匿名 API 每小时只有 60 次，而 README 本来就
    /// 随 HTML 一起发过来了，多一次请求既慢又会在批量补抓时撞限流。
    public enum GitHub {
        /// 是不是一个仓库主页。`/owner/repo`，两段路径，且第一段不是平台
        /// 自己的功能页（settings、features、explore 之类）。
        public static func isRepositoryPage(_ url: URL) -> Bool {
            guard url.host()?.lowercased().hasSuffix("github.com") == true else { return false }
            let parts = url.path().split(separator: "/").map(String.init)
            guard parts.count == 2 else { return false }
            let reserved: Set<String> = [
                "settings", "features", "explore", "topics", "trending", "collections",
                "events", "sponsors", "marketplace", "pricing", "about", "notifications",
                "orgs", "users", "search", "login", "join", "apps", "codespaces",
            ]
            return !reserved.contains(parts[0].lowercased())
        }

        /// 仓库页的可检索内容 = 标题 + 描述 + README。
        ///
        /// README 按标题/段落/列表项切成 segments，让分块沿语义边界走：
        /// 命中"怎么安装"时给回的是安装那一节，而不是横跨简介和许可证的
        /// 一刀。找不到 README 时仍然返回描述——一个仓库连描述都没有的
        /// 情况下，通用抽取给出的也只会是导航噪音。
        public static func extract(fromHTML html: String, url: URL) -> LinkTextExtraction.Extracted? {
            guard isRepositoryPage(url),
                  let document = try? SwiftSoup.parse(html, url.absoluteString) else { return nil }
            let heading = (try? document.title()).flatMap(title(fromDocumentTitle:))
            let description = (try? document.select("meta[property=og:description]").first()?
                .attr("content"))?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? nil
            // og:description 后面挂着一句固定的招募语，对检索毫无价值，
            // 而且每个仓库都一样——留着会让所有 GitHub 链接的向量互相靠拢。
            let cleanedDescription = description.map { value -> String in
                guard let range = value.range(of: "Contribute to ") else { return value }
                return String(value[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            var segments: [String] = []
            if let cleanedDescription, !cleanedDescription.isEmpty {
                segments.append(cleanedDescription)
            }
            if let readme = try? document.select("article.markdown-body").first() {
                let blocks = (try? readme.select("h1, h2, h3, h4, p, li, pre")) ?? Elements()
                for element in blocks.array() {
                    guard let text = try? element.text()
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !text.isEmpty else { continue }
                    segments.append(text)
                }
            }
            guard !segments.isEmpty else { return nil }
            return LinkTextExtraction.Extracted(
                title: heading,
                text: LinkTextExtraction.clamp(segments.joined(separator: "\n\n")),
                summary: cleanedDescription,
                segments: segments
            )
        }

        /// 从仓库页标题里剥掉平台样板，留下 `owner/repo：描述`。
        public static func title(fromDocumentTitle raw: String) -> String? {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            for suffix in [" · GitHub", " - GitHub"] where value.hasSuffix(suffix) {
                value = String(value.dropLast(suffix.count))
            }
            for prefix in ["GitHub - "] where value.hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }
}
