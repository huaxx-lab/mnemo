import Foundation

public enum LinkRefreshPolicy {
    public static let xiaohongshuVersion = 5

    public static func isNote(_ url: URL?) -> Bool {
        guard let url, LinkPlatform.resolve(url) == .xiaohongshu else { return false }
        let parts = url.path.split(separator: "/")
        return (parts.first == "explore" || parts.first == "discovery") && parts.count >= 2
    }

    public static func needsMigration(_ item: Item) -> Bool {
        item.state == .active && !item.isPrivate && isNote(item.linkURL)
            && (item.linkExtractionVersion ?? 0) < xiaohongshuVersion
    }

    public static func mayReplaceTitle(_ item: Item) -> Bool {
        if item.titleOrigin == "user" { return false }
        if item.titledLocally || item.titleOrigin == "ai" || item.titleOrigin == "page" { return true }
        // 旧库把 AI 与手写标题混在同一个 Bool 里。只迁移已知泛化占位名，
        // 不按“小红书”关键字覆盖任何其他旧标题。
        return LinkTextExtraction.isFailurePlaceholderTitle(item.title)
            || (isNote(item.linkURL) && [
                "小红书精彩内容分享", "小红书生活分享笔记", "小红书热门内容分享",
                "小红书分享内容", "小红书搜索结果",
            ].contains(item.title))
    }
}
