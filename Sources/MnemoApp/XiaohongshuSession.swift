import Foundation
import WebKit

/// 用户自己的小红书登录态：cookie 落盘 + 注入到发请求那条路。
///
/// 为什么要这个：小红书对匿名/无登录态的抓取会限流甚至直接回退成整站通用页
/// （见 `SiteContentExtraction.Xiaohongshu.isGenericSiteTitle` 那次修复）。
/// 用户自己账号登录后访问自己能看到的笔记，走的是完全不同的一条路——不依赖
/// 分享链接里那个会过期的 `xsec_token`，也不会被当成匿名爬虫限流。
///
/// 落地方式刻意选得很朴素：登录页用真实的小红书网页（`WKWebView` 加载
/// `www.xiaohongshu.com`），用户在里面用他们平时那一套完成登录——扫码、
/// 手机号验证码，小红书官方支持什么方式，这里就有什么方式，不用我们自己
/// 重新实现一遍登录协议。登录完成后把这一份 cookie 抄一份到
/// `HTTPCookieStorage.shared`：`URLSession.shared`（`LinkContentFetcher` /
/// `LinkCoverStore` 用的都是它）默认会自动带上这里面匹配域名的 cookie，
/// 不需要在每一处发请求的地方各自拼一遍 `Cookie:` 请求头——那样迟早会漏掉
/// 新加的某一处请求。
enum XiaohongshuSession {
    static let host = "xiaohongshu.com"

    private static let store = SessionStore()

    /// 是否已登录，供设置页显示状态。
    @MainActor private(set) static var isSignedIn = false
    @MainActor private(set) static var signedInAt: Date?
    @MainActor private(set) static var cookieCount = 0

    /// 启动时调用一次：把上次登录落盘的 cookie 重新注入到 `HTTPCookieStorage`。
    /// 不这样做的话，每次重启应用登录态就形同虚设——落盘了却没人用。
    @MainActor
    static func restoreAtLaunch() async {
        let snapshot = await store.load()
        apply(snapshot)
    }

    /// 登录页调用：把这一刻 WKWebView 里的小红书 cookie 抄一份出来落盘并生效。
    ///
    /// 不依赖猜测某个具体 cookie 名字才算"登录成功"——那种判定迟早会因为
    /// 小红书自己调整 cookie 方案而失效，且用户看得到自己有没有登录成功，
    /// 让他们自己确认比我们代码猜测更可靠。这里只管"把当下这份 cookie
    /// 原样搬过来"，用户在登录页看到已经登录了再点保存即可。
    @MainActor
    @discardableResult
    static func adopt(from dataStore: WKWebsiteDataStore) async -> Int {
        let cookies = await dataStore.httpCookieStore.allCookies()
        let relevant = cookies.filter { $0.domain.hasSuffix(host) }
        let snapshot = SessionSnapshot(
            cookies: relevant.map(PersistedCookie.init),
            signedInAt: .now
        )
        await store.save(snapshot)
        apply(snapshot)
        return relevant.count
    }

    /// 退出登录：清掉落盘的副本、`HTTPCookieStorage` 里的副本，以及 WKWebView
    /// 自己持久化的那一份——三处都不清的话，重新打开登录页会显示"已经登录"，
    /// 用户会以为退出没有生效。
    @MainActor
    static func signOut() async {
        for cookie in HTTPCookieStorage.shared.cookies ?? []
        where cookie.domain.hasSuffix(host) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        await store.clear()
        isSignedIn = false
        signedInAt = nil
        cookieCount = 0
        let records = await WKWebsiteDataStore.default().dataRecords(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()
        )
        let matching = records.filter { $0.displayName.hasSuffix(host) }
        guard !matching.isEmpty else { return }
        await WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching
        )
    }

    @MainActor
    private static func apply(_ snapshot: SessionSnapshot) {
        let cookies = snapshot.cookies.compactMap(\.httpCookie)
        for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
        isSignedIn = !cookies.isEmpty
        signedInAt = snapshot.signedInAt
        cookieCount = cookies.count
    }
}

// MARK: - 落盘

private struct PersistedCookie: Codable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var isSecure: Bool
    var expiresAt: Date?

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        isSecure = cookie.isSecure
        expiresAt = cookie.expiresDate
    }

    var httpCookie: HTTPCookie? {
        // 已过期的不必搬过去，省得 HTTPCookieStorage 里堆一堆废条目。
        if let expiresAt, expiresAt < .now { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path,
        ]
        if isSecure { properties[.secure] = "TRUE" }
        if let expiresAt { properties[.expires] = expiresAt }
        return HTTPCookie(properties: properties)
    }
}

private struct SessionSnapshot: Codable {
    var cookies: [PersistedCookie] = []
    var signedInAt: Date?
}

/// 和 `CredentialStore` 同一个存放模式：普通配置文件而不是钥匙串。
///
/// 这个应用是 ad-hoc 签名自分发，钥匙串按"创建它的那个二进制"认亲，每发
/// 一版就要重新登录一次——用户刚登录完，下一次更新又要再登一遍，体验很差。
/// 换成 `~/.mnemo/xiaohongshu-session.json`，权限 0600，只有本用户能读，
/// 威胁模型和钥匙串默认保护（登录密码）一致，换来的是升级不打扰登录态。
private actor SessionStore {
    private let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".mnemo/xiaohongshu-session.json", directoryHint: .notDirectory)

    func load() -> SessionSnapshot {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty,
              let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data)
        else { return SessionSnapshot() }
        return snapshot
    }

    func save(_ snapshot: SessionSnapshot) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { continuation.resume(returning: $0) }
        }
    }
}
