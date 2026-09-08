import Foundation
import WebKit

/// 离屏渲染一个网页，拿到 JavaScript 执行之后的 HTML。
///
/// **只在静态抽取确实拿不到正文时才用。** 判据是客观的——静态那一遍返回了
/// 零字或几十字，不是"我觉得这页可能是 SPA"。
///
/// 为什么非要它：现在相当一部分文档站、笔记站是前端渲染的，服务器返回的
/// HTML 里只有一个空壳。实测 Apple 的 HIG 页面静态抽取正文长度是 0，
/// 而维基百科同样的代码能拿到五千多字。不做这一层，"链接可以被自然语言
/// 检索"在这类站点上就是空话。
///
/// 代价也要说清楚：起一个 WebKit 进程、执行页面的脚本、等它加载完，
/// 比一次 HTTP 请求贵得多，也慢得多（秒级）。所以它挂在链接**被固定**
/// 之后的索引路径上，一条链接一辈子只跑一次。
@MainActor
enum HeadlessPageRenderer {

    /// 每隔这么久看一次正文长度有没有还在涨。
    private static let pollInterval = Duration.milliseconds(300)
    /// 连续两次不再增长就认为落定了。
    private static let stableChecksRequired = 2
    /// 最多等这么久。B 站这类重前端渲染 900ms 远远不够，但也不能无限等。
    private static let maximumSettle = Duration.seconds(6)

    /// 整个进程共用一个**不落盘**的数据仓。
    ///
    /// 之前是每次渲染新建一个，等于每次访问都是"一台从没上过网的浏览器"：
    /// 零 Cookie。B 站 412 最常见的直接成因就是缺 `buvid3`——真实浏览器
    /// 第一次访问 bilibili.com 时服务端会种上，此后每个请求都带着走；
    /// 永远零 Cookie 本身就是很强的机器人特征。共用之后，第一次渲染拿到的
    /// Cookie 后面还在，行为和一个刚打开的浏览器窗口一致。
    ///
    /// 仍然不落盘：关掉应用就全没了，"抓一篇文章不该在用户机器上留下这个
    /// 站点的登录痕迹"这条承诺没有变。
    private static let dataStore = WKWebsiteDataStore.nonPersistent()

    /// 同一时刻只许一个离屏 WebKit 活着，其余排队。
    ///
    /// 这道闸是补上一个真实的坑：`LinkFetchScheduler` 的租约在 `load()` 里
    /// **状态码检查之前**就释放了，所以"被 412 拦下 → 换 WebKit 重来"这条降级
    /// 路径跑在并发控制之外。批量重抓时同一个站点会连着来好几条（用户收藏本来
    /// 就集中在几个站），撞上风控就是几条同时降级——几个 WebKit 实例一起起、
    /// 一起跑 JS、一起等最长 6 秒的 settle，而这些协调都在主线程上，界面直接
    /// 开始掉帧。B 站接上官方 API 出口之后自己绕开了这条路，但下一个还 412 的
    /// 站点（Cloudflare 挑战页之类）没有 API 兜底，会原样踩回来。
    ///
    /// 排队而不是丢弃：降级本来就只在被拦之后才发生，频率很低，让它们依次跑完
    /// 比放弃抓取更符合用户预期——慢几秒可以，抓不到不行。
    private static var renderInFlight = false
    private static var waitingForSlot: [CheckedContinuation<Void, Never>] = []

    private static func acquireSlot() async {
        while renderInFlight {
            await withCheckedContinuation { waitingForSlot.append($0) }
        }
        renderInFlight = true
    }

    private static func releaseSlot() {
        renderInFlight = false
        guard !waitingForSlot.isEmpty else { return }
        waitingForSlot.removeFirst().resume()
    }

    static func renderedHTML(of url: URL, timeout: Duration = .seconds(15)) async -> String? {
        await acquireSlot()
        // 无论走哪条 return（超时、失败、正常），槽位都必须还回去，
        // 否则一次卡住就把后面所有降级永久堵死。
        defer { releaseSlot() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.suppressesIncrementalRendering = true

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1_280, height: 2_000),
            configuration: configuration
        )
        // 不设 customUserAgent。
        //
        // WKWebView 默认发的就是这台机器上真实 Safari 的 UA，和它真实的
        // TLS / HTTP2 指纹完全自洽。之前这里硬写了一串
        // "…Version/17.0 Safari/605.1.15 Mnemo/1.0"，两个毛病叠在一起：
        //
        // - 末尾那个 `Mnemo/1.0` 是在**唯一一条指纹本来就无懈可击的路径**上
        //   主动举手说"我是程序"。`BrowserRequestHeaders` 那边费劲把自报家门的
        //   UA 换掉了，这边又原样写了回来。
        // - `Version/17.0` 和这台机器真实的 WebKit 版本对不上。UA 声称一个
        //   版本、TLS 指纹是另一个版本，这种自相矛盾比不改还容易被挑出来。
        //
        // 想装得像浏览器，最好的办法是别装——本来就是浏览器。

        let coordinator = LoadCoordinator()
        webView.navigationDelegate = coordinator

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout.timeIntervalValue
        webView.load(request)

        let finished = await coordinator.wait(timeout: timeout)
        guard finished else {
            webView.stopLoading()
            return nil
        }
        await settle(webView)

        let html = try? await webView.evaluateJavaScript("document.documentElement.outerHTML")
        webView.stopLoading()
        webView.navigationDelegate = nil
        return html as? String
    }

    /// 等正文落定。
    ///
    /// 原来是无脑睡 900ms。`didFinish` 只说主文档加载完，前端框架往往在那之后
    /// 才把正文塞进 DOM——固定时长要么白等（静态页），要么不够（B 站这类）。
    /// 改成盯着正文长度：不再增长就走，最多等 6 秒。
    private static func settle(_ webView: WKWebView) async {
        let deadline = ContinuousClock.now + maximumSettle
        var previous = -1
        var stable = 0
        while ContinuousClock.now < deadline, stable < stableChecksRequired {
            try? await Task.sleep(for: pollInterval)
            if Task.isCancelled { return }
            let value = try? await webView.evaluateJavaScript(
                "document.body ? document.body.innerText.length : 0"
            )
            let length = (value as? NSNumber)?.intValue ?? 0
            stable = length == previous ? stable + 1 : 0
            previous = length
        }
    }

    /// 把 `didFinish` / `didFail` 桥成一次 await。
    ///
    /// 单独一个类而不是闭包：`WKNavigationDelegate` 要求一个对象，而且必须在
    /// 导航期间被强引用住，否则回调永远不来。超时用一个并行的 Task 兜底，
    /// 两条路都汇到 `finish`，由 `settled` 保证 continuation 只恢复一次。
    @MainActor
    private final class LoadCoordinator: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var settled = false
        private var timeoutTask: Task<Void, Never>?

        func wait(timeout: Duration) async -> Bool {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finish(false)
                }
            }
        }

        private func finish(_ value: Bool) {
            guard !settled else { return }
            settled = true
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation?.resume(returning: value)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(true)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: any Error
        ) {
            finish(false)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            finish(false)
        }
    }
}

private extension Duration {
    var timeIntervalValue: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
