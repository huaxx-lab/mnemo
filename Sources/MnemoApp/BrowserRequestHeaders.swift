import Foundation

/// 抓取第三方页面/图片时统一套的请求头配置。
///
/// 之前三个地方（`LinkContentFetcher`、`LinkCoverStore` 的正文请求和配图
/// 请求）各自复制了一份几乎一样的 UA + Accept-Language，改一处经常漏改
/// 另外两处；更关键的是那份 UA 直接自报家门——`Mnemo/1.0 (+link preview)`，
/// 对任何有基本风控的站点都是最简单的机器人特征，用户实报小红书登录后
/// 依然频繁被拦，和这个直接相关。
///
/// 这里改成一份完整、一致的 Safari-on-macOS 请求头画像，而不是只换一个
/// UA 字符串——只换 UA、其余请求头还是"应用自己那一小撮"，UA 声称是
/// Safari 但配套的 Accept / Sec-Fetch-* 却完全不像，这种"自相矛盾"本身
/// 就是更容易被抓的信号（之前试过换 UA 但没有配齐这些，B 站风控反而
/// 更严，大概率就是这个原因）。真实浏览器加载文档和加载图片发的请求头
/// 并不相同（Sec-Fetch-Dest 等），所以按用途分了 `.document` / `.image`
/// 两种画像，不能不分青红皂白全套同一份。
///
/// 说明：URLSession 走的是系统网络栈，TLS/HTTP2 层面的指纹终究和真实
/// Safari（走 WebKit）不同——这不是请求头能补上的差距。这里能做到的是
/// 不再用一个自报家门的 UA 主动暴露身份；如果某个站点连这一步都不够，
/// 那已经是指纹级别的识别，得换成真正走 WebKit 的抓取方式，不是这里
/// 能解决的。
enum BrowserRequestHeaders {
    enum Kind {
        /// 整页 HTML（顶层导航）。
        case document
        /// 页面内引用的图片（配图、favicon）。
        case image
    }

    /// macOS 上真实 Safari 的 UA 常年写着 "10_15_7"，不随实际系统版本变——
    /// 这是 Safari 自己的怪癖，保留它比换成"更准确"的版本号更像真的。
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/18.3 Safari/605.1.15"

    private static let acceptLanguage = "zh-CN,zh;q=0.9,en;q=0.8"

    static func apply(_ kind: Kind, to request: inout URLRequest, referer: String? = nil) {
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
        switch kind {
        case .document:
            request.setValue(
                "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
                forHTTPHeaderField: "Accept"
            )
            request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
            request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
            request.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
            request.setValue("?1", forHTTPHeaderField: "Sec-Fetch-User")
            request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        case .image:
            request.setValue(
                "image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5",
                forHTTPHeaderField: "Accept"
            )
            request.setValue("image", forHTTPHeaderField: "Sec-Fetch-Dest")
            request.setValue("no-cors", forHTTPHeaderField: "Sec-Fetch-Mode")
            request.setValue("same-site", forHTTPHeaderField: "Sec-Fetch-Site")
        }
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
    }
}
