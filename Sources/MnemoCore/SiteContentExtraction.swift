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

        /// 笔记自己的配图。
        ///
        /// og:image 在这里是**平台的静态资源**（fe-platform/…png），不是这条
        /// 笔记的图——照它取，一排小红书卡片会长得一模一样。真正的图写在
        /// `__INITIAL_STATE__` 的 imageList 里，路径用 \u002F 转义过。
        /// `WB_DFT` 是原图，`WB_PRV` 是预览小图，优先前者。
        public static func noteImageURL(fromHTML html: String) -> URL? {
            guard let listRange = html.range(of: "\"imageList\"") else { return nil }
            let tail = html[listRange.upperBound...].prefix(4_000)
            let pattern = #""url"\s*:\s*"((?:[^"\\]|\\.)*xhscdn(?:[^"\\]|\\.)*)""#
            let candidates = tail
                .matches(of: try! Regex(pattern))
                .compactMap { match -> String? in
                    guard let raw = match.output[1].substring else { return nil }
                    return String(raw).replacingOccurrences(of: "\\u002F", with: "/")
                }
            guard !candidates.isEmpty else { return nil }
            let preferred = candidates.first { $0.contains("nd_dft") } ?? candidates[0]
            guard var components = URLComponents(string: preferred) else { return nil }
            // 小红书状态里仍可能写 http CDN；同一个 CDN 支持 HTTPS，而 App
            // Transport Security 会拒绝明文图片。主动升级，真实配图才不会静默失败。
            if components.scheme?.lowercased() == "http" { components.scheme = "https" }
            return components.url
        }


        /// 读 `noteDetailMap` 之后第一个指定字段的 JSON 字符串值。
        ///
        /// 只在 noteDetailMap 后面找：页面状态里还有 UI、推荐流等一堆同名字段，
        /// 拿全页第一个会把别的模块说明当成当前笔记的内容。手工扫到配对的
        /// 引号，因为 JSON 字符串里可以有转义引号，不能直接找下一个 `"`。
        static func noteField(_ key: String, in html: String) -> String? {
            guard html.contains("__INITIAL_STATE__"),
                  let noteRange = html.range(of: "\"noteDetailMap\"") else { return nil }
            let noteState = html[noteRange.lowerBound...]
            guard let range = noteState.range(
                of: "\"\(key)\"\\s*:\\s*\"",
                options: .regularExpression
            ) else { return nil }
            var literal = "\""
            var index = range.upperBound
            var escaped = false
            while index < html.endIndex {
                let character = html[index]
                literal.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    break
                }
                index = html.index(after: index)
                // 一条笔记不会有这么长，越界说明匹配到的不是我们要的字段。
                if literal.count > 20_000 { return nil }
            }
            guard literal.hasSuffix("\""),
                  let data = literal.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(String.self, from: data) else {
                return nil
            }
            let text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        /// 话题标记。原文写作 `#考研人[话题]#`，`[话题]#` 是平台的内部记号，
        /// 不是用户写的字。留着它检索时会把这四个字当成正文词一起匹配，
        /// 而且读起来是坏的。词本身保留——那是这条笔记的主题。
        public static func cleaned(_ text: String) -> String {
            text.replacingOccurrences(
                of: #"\[话题\]#"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// 笔记标题。
        ///
        /// 状态里的 `title` 才是作者填的标题；`<title>` 标签在没填标题时会被
        /// 整段正文顶替（还带着 `#话题#` 和 ` - 小红书` 后缀），拿它当标题
        /// 就是一张卡片上糊着一整段话，或者干脆退化成 AI 起名。
        /// 作者没填标题时（小红书允许），按平台自己的做法取正文首句。
        public static func title(fromHTML html: String) -> String? {
            if let title = noteField("title", in: html) {
                let cleanedTitle = cleaned(title)
                if !cleanedTitle.isEmpty { return cleanedTitle }
            }
            guard let desc = extract(fromHTML: html) else { return nil }
            return leadingSentence(of: desc)
        }

        /// 正文首句，用作没有标题时的替代。
        ///
        /// 按句子边界断，不按字数硬切——切在半个词上比长一点更难看。
        /// 只有首句本身异常长时才退回在标点处收尾。
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

        public static func extract(fromHTML html: String) -> String? {
            noteField("desc", in: html).map(cleaned)
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
