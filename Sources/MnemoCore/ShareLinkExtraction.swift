import Foundation

/// 从一段文字里认出"这其实是一条分享"。
///
/// 社交和流媒体 App 的分享从来不是一个裸链接，而是"标题 + 链接 + 一句套话"：
///
///     19 【北海道vlog】跟着我一起…… 😆 http://xhslink.com/a/xxxx，复制本条信息，打开【小红书】App查看精彩内容！
///     7.85 复制打开抖音，看看【xxx】的作品 https://v.douyin.com/xxxx/ 复制此链接，打开Dou音搜索
///     【标题】 https://b23.tv/xxxx
///
/// 旧的判定要求整段文字**不含任何空白**才算链接，所以上面这些一律被存成
/// 纯文字：卡片上没有封面、没有平台图标、点了也打不开，检索时也只是一段
/// 带 URL 的文本。
public struct SharedLink: Sendable, Equatable {
    public var url: URL
    /// 分享文案里那个标题。取不到就是 nil，由调用方退回自己的命名规则。
    public var title: String?
    /// 这段文字整体就是一条分享（可以当链接看），还是正文里恰好带了个链接。
    ///
    /// 这条界线决定要不要把 Pin 的类型从"文字"改成"链接"。判错的代价不对称：
    /// 把一篇带参考链接的笔记改判成链接，用户会发现自己的笔记"变成了一个网址"；
    /// 而漏判一条分享，最多是它继续以文字身份留在库里。所以从严。
    public var isSharePayload: Bool

    public init(url: URL, title: String? = nil, isSharePayload: Bool) {
        self.url = url
        self.title = title
        self.isSharePayload = isSharePayload
    }
}

public enum ShareLinkExtractor {
    /// 超过这个长度就不像一条分享文案了，像一篇正文。
    static let maximumShareResidue = 64

    /// 分享套话。剥掉它们之后剩下的才是标题。
    ///
    /// 只列各家**固定生成**的那几句，不做模糊匹配：这些字符串是 App 拼出来的，
    /// 逐字稳定，而"看起来像套话"的模糊判断会误伤用户自己写的话。
    static let boilerplate = [
        "复制本条信息", "打开【小红书】App查看精彩内容", "打开小红书App查看精彩内容",
        "复制此链接", "打开Dou音搜索", "打开抖音搜索", "直接观看视频",
        "复制打开抖音", "看看", "的作品", "点击链接直接打开", "点击打开",
        "长按复制此条消息", "打开哔哩哔哩", "打开B站", "手机浏览器打开",
        "分享自", "来自", "网页链接", "查看图片", "小红书", "戳这里",
    ]

    /// 那些一望即知是分享的短链域名。
    ///
    /// 它们除了分享没有别的用途——没人会在正文里引用一条 b23.tv 当参考资料，
    /// 所以命中即可判定，不必再看剩下多长。
    static let shareHosts = [
        "xhslink.com", "b23.tv", "v.douyin.com", "t.co", "vt.tiktok.com",
        "163cn.tv", "tb.cn", "3.cn", "amzn.to", "spoti.fi", "redd.it",
        "youtu.be", "doub.an", "m.tb.cn", "kuaishou.com/f",
    ]

    /// 找出这段文字里的分享链接。没有就返回 nil。
    public static func first(in text: String) -> SharedLink? {
        let urls = urls(in: text)
        guard let url = urls.first else { return nil }

        // 多个链接说明这是一段引用了若干来源的正文，不是一条分享。取第一个
        // 供界面使用，但绝不把整条 Pin 改判成链接。
        guard urls.count == 1 else {
            return SharedLink(url: url, title: nil, isSharePayload: false)
        }

        let residue = self.residue(of: text, removing: url)
        let host = url.host()?.lowercased().replacingOccurrences(of: "www.", with: "") ?? ""
        let isShortShareHost = shareHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        let isShare = isShortShareHost || residue.count <= maximumShareResidue

        return SharedLink(
            url: url,
            title: isShare ? self.title(from: text, residue: residue) : nil,
            isSharePayload: isShare
        )
    }

    /// 文本里全部 http(s) 链接，按出现顺序。
    ///
    /// 用 `NSDataDetector` 而不是自己写正则：URL 的边界规则（中文标点、
    /// 全角括号、尾随的"，"算不算链接的一部分）比看上去复杂得多，系统这套
    /// 已经在真实文本上磨过很多年。
    static func urls(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen: Set<String> = []
        var result: [URL] = []
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.host() != nil,
                  seen.insert(url.absoluteString).inserted else { continue }
            result.append(url)
        }
        return result
    }

    /// 去掉链接和套话之后还剩多少字。
    static func residue(of text: String, removing url: URL) -> String {
        var value = text.replacingOccurrences(of: url.absoluteString, with: " ")
        for phrase in boilerplate {
            value = value.replacingOccurrences(of: phrase, with: " ")
        }
        // 分享文案开头常有一串定位码（小红书的 "19"、抖音的 "7.85"）。
        value = value.replacingOccurrences(
            of: #"^[\s\d.]{1,8}"#,
            with: " ",
            options: .regularExpression
        )
        // 分隔符和标点不算"剩下的字"。用 ## 定界：字符类里本身含有 " 和 #，
        // 单层 #"…"# 会被 "# 提前终止。
        return value
            .replacingOccurrences(
                of: ##"[\s,，。！!、：:；;（）()【】\[\]"#*~—…-]+"##,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 分享文案里的标题。
    ///
    /// 【】里那段优先——各家分享都把标题放在里面，而且它是逐字的原标题，
    /// 比从整句做减法抠出来的可靠得多。
    static func title(from text: String, residue: String) -> String? {
        if let match = text.range(of: #"【[^】]{1,60}】"#, options: .regularExpression) {
            let inner = text[match].dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
            if inner.count >= 2, !boilerplate.contains(inner) { return String(inner.prefix(40)) }
        }
        guard residue.count >= 2 else { return nil }
        return String(residue.prefix(40))
    }
}

public extension Item {
    /// 这条 Pin 指向的网址。
    ///
    /// 唯一出口。以前每个调用点各自 `URL(string: inlineText)`，于是"分享文案
    /// 里夹着链接"这种情况要在七八个地方分别补一次——补漏一处就表现为
    /// "卡片上有图标但点了没反应"。
    var linkURL: URL? {
        guard case .inline(let text) = holding else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = URL(string: trimmed),
           let scheme = direct.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           direct.host() != nil {
            return direct
        }
        return ShareLinkExtractor.first(in: text)?.url
    }
}
