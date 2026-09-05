import Foundation

public enum LinkRefreshPolicy {
    // v6→v7：修了"被限流/风控返回的整站通用页，标题/正文被误当成笔记内容
    // 写回"的问题。少数条目在 v6 那次迁移里恰好撞上这种响应，标题被顶成了
    // 网站自己的标语——版本号必须再前进一格，让它们重新成为迁移候选，
    // 不用等用户逐条手动点"重新解析"。
    // v7→v8：修了"平台占位图（fe-platform 下的通用红底 logo）被当成笔记真实
    // 配图"的问题。它不只把卡片显示成红方块，还被一路送进 OCR——生产库里
    // 878/967/968 三条的 imageOCR 分块内容都是从 logo 上认出来的 `小书`，
    // 这些碎字至今留在 RAG 里。版本号前进一格，让这些条目重新成为迁移候选，
    // 抓不到真图时至少把假图和它带来的脏分块清掉。
    public static let xiaohongshuVersion = 8

    public static func isNote(_ url: URL?) -> Bool {
        guard let url, LinkPlatform.resolve(url) == .xiaohongshu else { return false }
        let parts = url.path.split(separator: "/")
        return (parts.first == "explore" || parts.first == "discovery") && parts.count >= 2
    }

    public static func needsMigration(_ item: Item) -> Bool {
        item.state == .active && !item.isPrivate && isNote(item.linkURL)
            && (item.linkExtractionVersion ?? 0) < xiaohongshuVersion
    }

    /// 小红书在笔记不可用（token 过期、临时抓取失败等）时回退给的通用文案，
    /// 而不是这条笔记自己的标题。逐字维护一张名单在实测里已经不够：同一类
    /// 回退文案换个措辞就漏过去（"生活分享精选推荐"就不在旧名单里，
    /// 用户手动重新解析也救不回来）。改成认这几个反复出现的泛化片段——
    /// 真实笔记标题几乎不会同时踩中"分享/推荐/热门/精彩"这类纯营销词而不带
    /// 任何具体内容，即便偶尔撞上，重新抓到的仍是同一个值，不会越改越错。
    private static let genericFallbackFragments = [
        "精彩内容", "生活分享", "热门内容", "分享内容", "搜索结果", "精选推荐",
    ]

    public static func mayReplaceTitle(_ item: Item) -> Bool {
        if item.titleOrigin == "user" { return false }
        if item.titledLocally || item.titleOrigin == "ai" || item.titleOrigin == "page" { return true }
        // 旧库把 AI 与手写标题混在同一个 Bool 里，遇到这种历史条目只敢在
        // "看着就是泛化回退文案"时才覆盖，不按其他任何理由动旧标题。
        if LinkTextExtraction.isFailurePlaceholderTitle(item.title) { return true }
        guard isNote(item.linkURL) else { return false }
        return genericFallbackFragments.contains { item.title.contains($0) }
    }
}
