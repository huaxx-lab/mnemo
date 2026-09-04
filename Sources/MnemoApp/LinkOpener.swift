import AppKit
import Foundation
import MnemoCore

/// 一条链接该在哪里打开。
///
/// 优先级：装了对应 App 就去 App，否则回到**当初那个浏览器**，都没有才交给
/// 系统默认。
///
/// 关键决定：**不硬编码各家的 deep link scheme**。
/// `bilibili://video/BV...`、`xhsdiscover://item/...` 这类写法要为每个平台
/// 维护一张表，新装一个 App 不会自动生效，改版了也不会有人发现——正是那种
/// "写死之后慢慢烂掉"的东西。macOS 自己就能回答"哪些 App 注册了这个链接"
/// （通用链接 / URL scheme 都算），把它和"哪些 App 是通用 http 处理器"求差，
/// 剩下的就是内容 App。装了就能跳，卸了自动退回浏览器，一行表都不用维护。
@MainActor
enum LinkOpener {
    /// 任何登记了能打开 https 地址的 App。
    ///
    /// 这一份是用来做**减法**的：能打开任意网页 = 对这条链接没有专门支持。
    /// 内容 App 的特征恰恰相反——它只认自家域名，不认 example.com。
    private static let genericHTTPHandlers: Set<String> = {
        guard let probe = URL(string: "https://example.com") else { return [] }
        return Set(
            NSWorkspace.shared.urlsForApplications(toOpen: probe)
                .compactMap { Bundle(url: $0)?.bundleIdentifier }
        )
    }()

    /// 通用处理器里真正能显示网页的那些，也就是浏览器。
    ///
    /// 和上面那份的区别很关键，我在这里栽过一次：cmux、Codex、夸克网盘都
    /// 登记了 http scheme（为了接管自家深链），但它们不是浏览器。
    /// 曾经把它们从浏览器集合里剔除，结果它们落进了"内容 App"那一档、
    /// 反而被优先打开——用户点一个知乎链接，Codex 弹出来了。
    ///
    /// 所以两份集合各司其职：`genericHTTPHandlers` 决定谁**不是**内容 App，
    /// `browserBundleIDs` 决定浏览器记忆记谁。
    private static let browserBundleIDs: Set<String> = {
        guard let probe = URL(string: "https://example.com") else { return [] }
        var result = Set(
            NSWorkspace.shared.urlsForApplications(toOpen: probe)
                .filter { displaysWebPages($0) }
                .compactMap { Bundle(url: $0)?.bundleIdentifier }
        )
        // 系统默认打开网页的那个，无论它怎么声明文档类型，都是浏览器。
        // Safari 就不在上面那份名单里——只按文档类型筛会把它筛掉。
        if let fallback = NSWorkspace.shared.urlForApplication(toOpen: probe),
           let id = Bundle(url: fallback)?.bundleIdentifier {
            result.insert(id)
        }
        return result
    }()

    /// 这个 App 是真的能显示网页，还是只是登记了 http scheme。
    /// 分水岭是有没有声明自己能显示 HTML 文档。
    private nonisolated static func displaysWebPages(_ appURL: URL) -> Bool {
        guard let info = Bundle(url: appURL)?.infoDictionary,
              let types = info["CFBundleDocumentTypes"] as? [[String: Any]] else { return false }
        return types.contains { type in
            (type["LSItemContentTypes"] as? [String])?.contains("public.html") == true
        }
    }

    static func isBrowser(_ bundleID: String) -> Bool { browserBundleIDs.contains(bundleID) }

    /// 这台机器上装了哪些浏览器。设置页拿它列选项，卡片拿它取图标。
    struct InstalledBrowser: Identifiable, Hashable, Sendable {
        var bundleID: String
        var name: String
        var appURL: URL
        var id: String { bundleID }
    }

    /// bundle id → 应用 URL。正负结果都缓存：卡片的 tooltip 每帧都会问，
    /// 不缓存 nil 时，卸载过的浏览器会每帧重查 Launch Services。
    private static var appURLCache: [String: URL] = [:]
    private static var missingAppURLs: Set<String> = []

    private static func appURL(_ bundleID: String) -> URL? {
        if let cached = appURLCache[bundleID] { return cached }
        if missingAppURLs.contains(bundleID) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missingAppURLs.insert(bundleID)
            return nil
        }
        appURLCache[bundleID] = url
        return url
    }

    /// 按名字排序，稳定可预期。系统默认那个排在最前——多数人就用它。
    static var installedBrowsers: [InstalledBrowser] {
        let systemDefault = URL(string: "https://example.com")
            .flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        return browserBundleIDs
            .compactMap { bundleID -> InstalledBrowser? in
                guard let url = appURL(bundleID) else { return nil }
                return InstalledBrowser(bundleID: bundleID, name: appName(at: url), appURL: url)
            }
            .sorted { lhs, rhs in
                if lhs.bundleID == systemDefault { return true }
                if rhs.bundleID == systemDefault { return false }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    static func browserName(_ bundleID: String) -> String? {
        appURL(bundleID).map(appName(at:))
    }

    /// 浏览器自己的应用图标。卡片上那枚小徽标用它——不自己画图标，
    /// 用户屏幕上其他地方看到的 Chrome 是什么样，这里就该是什么样。
    ///
    /// 同样必须缓存：`icon(forFile:)` 每次都会读盘并新建一个 NSImage。
    /// 一屏几十张链接卡在滚动里反复调它，掉帧就是这么来的。
    private static var iconCache: [String: NSImage] = [:]

    static func browserIcon(_ bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let url = appURL(bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = icon
        return icon
    }

    /// 系统当前的默认浏览器。用户没有在设置里指定时就是它。
    ///
    /// 必须缓存：卡片上那枚徽标每帧都要问一次"这条链接会用哪个浏览器"，而
    /// `urlForApplication(toOpen:)` 是一次 Launch Services 往返。一屏几十张卡
    /// 乘以 60fps，滚动直接卡死。默认浏览器在应用运行期间几乎不会变，
    /// 变了大不了下次启动生效。
    static let systemDefaultBrowserBundleID: String? = URL(string: "https://example.com")
        .flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        .flatMap { Bundle(url: $0)?.bundleIdentifier }

    /// 只走浏览器，不看有没有对应的原生 App。
    ///
    /// 和 `open` 是两个不同的意图：那个是"打开这条内容"（B 站链接优先进
    /// B 站 App），这个是"在网页里看"。卡片上两枚徽标各自对应一个，
    /// 用户不用先猜会跳到哪儿。
    @discardableResult
    static func openInBrowser(_ url: URL, bundleID: String?) -> String {
        if let bundleID,
           let browser = appURL(bundleID) {
            NSWorkspace.shared.open(
                [url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration()
            )
            return appName(at: browser)
        }
        NSWorkspace.shared.open(url)
        return "默认浏览器"
    }

    /// 能打开这条链接、而且不是浏览器的那个 App。
    ///
    /// 有多个时取第一个：系统按用户的默认设置排序，它比我们自己挑更合理。
    static func nativeApp(for url: URL) -> URL? {
        let key = url.host() ?? url.absoluteString
        if let cached = nativeAppCache[key] { return cached }
        let resolved = resolvedNativeApp(for: url)
        nativeAppCache[key] = resolved
        return resolved
    }

    private static func resolvedNativeApp(for url: URL) -> URL? {
        NSWorkspace.shared.urlsForApplications(toOpen: url).first { appURL in
            guard let id = Bundle(url: appURL)?.bundleIdentifier else { return false }
            // 减去**所有**通用 http 处理器，不只是浏览器。留下的才是"专门认
            // 这个域名"的 App，也就是真正的内容 App。
            return !genericHTTPHandlers.contains(id)
        }
    }

    /// 打开。返回落到哪儿了，供界面给一句反馈。
    @discardableResult
    static func open(_ url: URL, preferredBrowserBundleID: String?) -> String {
        let configuration = NSWorkspace.OpenConfiguration()
        if let app = nativeApp(for: url) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
            return appName(at: app)
        }
        // 没有对应 App：回到当初拖进来的那个浏览器。用户在哪儿看到的就在哪儿
        // 打开——登录态、扩展、书签都在那边，换一个浏览器等于换了个环境。
        if let bundleID = preferredBrowserBundleID,
           let browser = appURL(bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: configuration)
            return appName(at: browser)
        }
        NSWorkspace.shared.open(url)
        return "默认浏览器"
    }

    /// 悬停提示里那句"会去哪儿"。让用户点之前就知道结果。
    static func destinationName(for url: URL, preferredBrowserBundleID: String?) -> String {
        if let app = nativeApp(for: url) { return appName(at: app) }
        if let bundleID = preferredBrowserBundleID,
           let browser = appURL(bundleID) {
            return appName(at: browser)
        }
        return "默认浏览器"
    }

    /// 应用名。缓存住：卡片的悬停提示每帧都会重新算一遍"这条链接会去哪儿"，
    /// 而 `displayName(atPath:)` 每次都要读一趟磁盘上的 bundle 信息。
    private static var nameCache: [String: String] = [:]

    private static func appName(at url: URL) -> String {
        if let cached = nameCache[url.path] { return cached }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        nameCache[url.path] = name
        return name
    }

    /// `urlsForApplications(toOpen:)` 是一次 Launch Services 往返，还要逐个
    /// 读候选应用的 Info.plist。按主机名缓存——同一个域名的链接会落到同一个
    /// App 上，而卡片轨道里同域名的链接往往是成片的。
    private static var nativeAppCache: [String: URL?] = [:]
}

/// 这条链接当初是从哪个浏览器来的。
///
/// 为什么不写进 `Item`：这是一条辅助记录，为它给整个库做一次结构迁移不划算。
/// 存法沿用 `NearbyDeviceOrigin` / `TodoProvenanceStore` 那一套。
///
/// 只记浏览器，不记任意来源应用：从微信里复制一条链接，用户想要的是"用我
/// 平时那个浏览器打开"，而不是"回到微信"。来源是不是浏览器由 `LinkOpener`
/// 问系统判定，不靠 bundle id 前缀猜。
@MainActor
enum LinkSourceBrowserStore {
    private static let key = "Pinland.linkSourceBrowser.v1"

    private static var map: [UUID: String] = {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else {
            return [:]
        }
        return raw.reduce(into: [:]) { result, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            result[id] = pair.value
        }
    }()

    /// 记下来源。非浏览器一律忽略。
    @discardableResult
    static func record(itemID: UUID, sourceBundleID: String?) -> Bool {
        guard let sourceBundleID, LinkOpener.isBrowser(sourceBundleID),
              map[itemID] != sourceBundleID else { return false }
        map[itemID] = sourceBundleID
        persist()
        return true
    }

    /// 读的时候再判一次"它还是不是浏览器"。
    ///
    /// 早先那一版的判定是错的，把 Codex、cmux 这类也记了进来，用户点链接
    /// 会被扔进终端。写入时的判定已经修好，但**已经存下的脏数据还在**——
    /// 在出口再过一道，旧记录自动失效，不用要求用户去清什么。
    static func bundleID(for itemID: UUID) -> String? {
        guard let id = map[itemID], LinkOpener.isBrowser(id) else { return nil }
        return id
    }

    static func prune(keeping ids: Set<UUID>) {
        let kept = map.filter { ids.contains($0.key) }
        guard kept.count != map.count else { return }
        map = kept
        persist()
    }

    private static func persist() {
        UserDefaults.standard.set(
            Dictionary(uniqueKeysWithValues: map.map { ($0.key.uuidString, $0.value) }),
            forKey: key
        )
    }
}
