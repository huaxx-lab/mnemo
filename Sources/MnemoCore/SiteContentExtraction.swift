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


        public static func extract(fromHTML html: String) -> String? {
            guard html.contains("__INITIAL_STATE__"),
                  let noteRange = html.range(of: "\"noteDetailMap\"") else { return nil }
            // 只在 noteDetailMap 后面找 desc。页面状态里还有 UI、推荐流等很多
            // `desc` 字段，拿全页第一个会把别的模块说明当成当前笔记正文。
            let noteState = html[noteRange.lowerBound...]
            guard let range = noteState.range(
                of: #""desc"\s*:\s*""#,
                options: .regularExpression
            ) else { return nil }
            // 手工扫到配对的引号：JSON 字符串里可以有转义引号，不能直接找下一个 "。
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
    }
}
