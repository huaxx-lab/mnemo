import Foundation

/// 一条链接来自哪个平台。
///
/// 只看域名，纯本地判定，不调模型也不联网。它有两个用处，而且必须是同一份
/// 判定：卡片上画哪个图标，以及"按平台归类"那一排怎么分组。两处各写一份的
/// 后果在这个项目里已经出现过一次——类型词表曾经分散在两处，给一处补了词
/// 另一处不认，同一句话在两条路径上得到不同结论。
public enum LinkPlatform: String, CaseIterable, Sendable, Codable, Hashable {
    // 视频 / 流媒体
    case bilibili, youtube, douyin, kuaishou, tiktok, netflix, iqiyi, youku, tencentVideo
    // 社交 / 社区
    case xiaohongshu, weibo, zhihu, x, instagram, reddit, facebook, threads, douban, tieba
    case linuxdo
    // 音乐 / 播客
    case spotify, appleMusic, neteaseMusic, qqMusic, ximalaya
    // 内容 / 工具
    case wechatArticle, zhihuZhuanlan, juejin, csdn, jianshu, medium, substack
    case github, gitlab, huggingface, arxiv, notion, figma, feishu, yuque
    // 电商（图标可以直接复用待办那套）
    case taobao, tmall, jd, meituan, pinduoduo, amazon

    /// 域名后缀 → 平台。
    ///
    /// 用后缀匹配而不是全等：`www.bilibili.com`、`m.bilibili.com`、`b23.tv`
    /// 都是同一个平台，而枚举每一种子域名是列不完的。
    private static let hostSuffixes: [(LinkPlatform, [String])] = [
        (.bilibili, ["bilibili.com", "b23.tv", "bilibili.tv"]),
        (.youtube, ["youtube.com", "youtu.be"]),
        (.douyin, ["douyin.com", "iesdouyin.com"]),
        (.kuaishou, ["kuaishou.com", "chenzhongtech.com"]),
        (.tiktok, ["tiktok.com"]),
        (.netflix, ["netflix.com"]),
        (.iqiyi, ["iqiyi.com"]),
        (.youku, ["youku.com"]),
        (.tencentVideo, ["v.qq.com"]),

        (.xiaohongshu, ["xiaohongshu.com", "xhslink.com"]),
        (.linuxdo, ["linux.do"]),
        (.weibo, ["weibo.com", "weibo.cn"]),
        // 知乎专栏和知乎主站是同一个域名下的不同路径，靠 path 再分一次。
        (.zhihu, ["zhihu.com", "zhihu.com.cn"]),
        (.x, ["x.com", "twitter.com", "t.co"]),
        (.instagram, ["instagram.com"]),
        (.reddit, ["reddit.com", "redd.it"]),
        (.facebook, ["facebook.com", "fb.com"]),
        (.threads, ["threads.net", "threads.com"]),
        (.douban, ["douban.com", "doub.an"]),
        (.tieba, ["tieba.baidu.com"]),

        (.spotify, ["spotify.com", "spoti.fi"]),
        (.appleMusic, ["music.apple.com"]),
        (.neteaseMusic, ["music.163.com", "163cn.tv"]),
        (.qqMusic, ["y.qq.com"]),
        (.ximalaya, ["ximalaya.com"]),

        (.wechatArticle, ["mp.weixin.qq.com"]),
        (.juejin, ["juejin.cn"]),
        (.csdn, ["csdn.net"]),
        (.jianshu, ["jianshu.com"]),
        (.medium, ["medium.com"]),
        (.substack, ["substack.com"]),

        (.github, ["github.com", "github.io"]),
        (.gitlab, ["gitlab.com"]),
        (.huggingface, ["huggingface.co", "hf.co"]),
        (.arxiv, ["arxiv.org"]),
        (.notion, ["notion.so", "notion.site"]),
        (.figma, ["figma.com"]),
        (.feishu, ["feishu.cn", "larksuite.com"]),
        (.yuque, ["yuque.com"]),

        (.taobao, ["taobao.com", "tb.cn"]),
        (.tmall, ["tmall.com"]),
        (.jd, ["jd.com", "3.cn"]),
        (.meituan, ["meituan.com", "dianping.com"]),
        (.pinduoduo, ["pinduoduo.com", "yangkeduo.com"]),
        (.amazon, ["amazon.com", "amazon.cn", "amzn.to"]),
    ]

    public static func resolve(_ raw: String) -> LinkPlatform? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return resolve(url)
    }

    public static func resolve(_ url: URL) -> LinkPlatform? {
        guard var host = url.host()?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let matched = hostSuffixes.first { _, suffixes in
            suffixes.contains { host == $0 || host.hasSuffix("." + $0) }
        }?.0
        // 知乎专栏在卡片上值得和知乎问答分开：一个是文章，一个是问答串。
        if matched == .zhihu, url.path().hasPrefix("/p/") { return .zhihuZhuanlan }
        return matched
    }

    /// 归类那一排上的名字。用中文，和界面其余部分一致。
    public var displayName: String {
        switch self {
        case .bilibili: "哔哩哔哩"
        case .youtube: "YouTube"
        case .douyin: "抖音"
        case .kuaishou: "快手"
        case .tiktok: "TikTok"
        case .netflix: "Netflix"
        case .iqiyi: "爱奇艺"
        case .youku: "优酷"
        case .tencentVideo: "腾讯视频"
        case .xiaohongshu: "小红书"
        case .linuxdo: "LINUX DO"
        case .weibo: "微博"
        case .zhihu: "知乎"
        case .zhihuZhuanlan: "知乎专栏"
        case .x: "X"
        case .instagram: "Instagram"
        case .reddit: "Reddit"
        case .facebook: "Facebook"
        case .threads: "Threads"
        case .douban: "豆瓣"
        case .tieba: "贴吧"
        case .spotify: "Spotify"
        case .appleMusic: "Apple Music"
        case .neteaseMusic: "网易云音乐"
        case .qqMusic: "QQ 音乐"
        case .ximalaya: "喜马拉雅"
        case .wechatArticle: "微信公众号"
        case .juejin: "掘金"
        case .csdn: "CSDN"
        case .jianshu: "简书"
        case .medium: "Medium"
        case .substack: "Substack"
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .huggingface: "Hugging Face"
        case .arxiv: "arXiv"
        case .notion: "Notion"
        case .figma: "Figma"
        case .feishu: "飞书"
        case .yuque: "语雀"
        case .taobao: "淘宝"
        case .tmall: "天猫"
        case .jd: "京东"
        case .meituan: "美团"
        case .pinduoduo: "拼多多"
        case .amazon: "亚马逊"
        }
    }

    /// 大类。归类那一排先按它排序，同类的挨在一起，用户扫得快。
    public var category: Category {
        switch self {
        case .bilibili, .youtube, .douyin, .kuaishou, .tiktok,
             .netflix, .iqiyi, .youku, .tencentVideo:
            .video
        case .xiaohongshu, .weibo, .zhihu, .zhihuZhuanlan, .x, .instagram,
             .reddit, .facebook, .threads, .douban, .tieba, .linuxdo:
            .social
        case .spotify, .appleMusic, .neteaseMusic, .qqMusic, .ximalaya:
            .audio
        case .wechatArticle, .juejin, .csdn, .jianshu, .medium, .substack,
             .github, .gitlab, .huggingface, .arxiv, .notion, .figma, .feishu, .yuque:
            .reading
        case .taobao, .tmall, .jd, .meituan, .pinduoduo, .amazon:
            .shopping
        }
    }

    public enum Category: Int, Sendable, CaseIterable, Comparable {
        case video, social, audio, reading, shopping

        public var displayName: String {
            switch self {
            case .video: "影音"
            case .social: "社交"
            case .audio: "音乐"
            case .reading: "阅读"
            case .shopping: "购物"
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 图标资源名。
    ///
    /// 只有真的准备了素材的才返回名字；其余返回 nil，由界面退回既有的
    /// "首字母色块"。宁可退回也不要挂一个错的图标——用户是靠图标一眼认出
    /// 平台的，认错比没有更糟。
    public var iconResourceName: String? {
        switch self {
        case .bilibili: "bilibili"
        case .youtube: "youtube"
        case .douyin: "douyin"
        case .kuaishou: "kuaishou"
        case .tiktok: "tiktok"
        case .netflix: "netflix"
        case .iqiyi: "iqiyi"
        case .youku: "youku"
        case .tencentVideo: "tencent-video"
        case .xiaohongshu: "xiaohongshu"
        case .linuxdo: "linuxdo"
        case .weibo: "weibo"
        case .zhihu, .zhihuZhuanlan: "zhihu"
        case .x: "x"
        case .instagram: "instagram"
        case .reddit: "reddit"
        case .facebook: "facebook"
        case .threads: "threads"
        case .douban: "douban"
        case .tieba: "tieba"
        case .spotify: "spotify"
        case .appleMusic: "apple-music"
        case .neteaseMusic: "netease-music"
        case .qqMusic: "qq-music"
        case .ximalaya: "ximalaya"
        // 公众号文章的载体就是微信，用微信的图标最好认。
        case .wechatArticle: "wechat"
        case .github: "github"
        // 待办那套已经有的素材，直接复用，不重复下载。
        case .taobao: "taobao"
        case .tmall: "tmall"
        case .jd: "jd"
        case .meituan: "meituan"
        case .pinduoduo: "pinduoduo"
        case .amazon: "amazon"
        // 这些还没有素材，界面退回域名色块。挂错图标比没有更糟。
        case .juejin, .csdn, .jianshu, .medium, .substack,
             .gitlab, .huggingface, .arxiv, .notion, .figma, .feishu, .yuque:
            nil
        }
    }
}

/// 把主机名收敛到"注册域"。
///
/// `cdk.hybgzs.com` 和 `ai.hybgzs.com` 是同一家的两个子站，按整串主机名分组
/// 会得到两个只有一条内容的分组——那不是聚类，是把噪音排成一行。
///
/// 没有引入完整的公共后缀表（PSL）：它有几千行、需要定期更新，而这里的
/// 用途只是给筛选条起个名字，判错一个冷门后缀的代价是分组粒度不理想，
/// 不会丢内容。只列真正常见的二级后缀，其余按"最后两段"处理。
public enum RegistrableDomain {
    /// 那些本身就是后缀、不能当注册域的第二级标签。
    private static let multiPartSuffixes: Set<String> = [
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "co.uk", "org.uk", "ac.uk", "gov.uk",
        "co.jp", "or.jp", "ne.jp", "ac.jp",
        "com.hk", "com.tw", "com.au", "net.au", "org.au",
        "co.kr", "com.br", "com.sg", "com.my",
    ]

    public static func of(_ host: String) -> String {
        var value = host.lowercased()
        if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
        let parts = value.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return value }
        let lastTwo = parts.suffix(2).joined(separator: ".")
        // 后缀本身占两段时要多留一段，否则 example.com.cn 会被收成 com.cn。
        let keep = multiPartSuffixes.contains(lastTwo) ? 3 : 2
        guard parts.count > keep else { return value }
        return parts.suffix(keep).joined(separator: ".")
    }
}
