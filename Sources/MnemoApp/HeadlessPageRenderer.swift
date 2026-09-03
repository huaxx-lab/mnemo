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

    static func renderedHTML(of url: URL, timeout: Duration = .seconds(15)) async -> String? {
        let configuration = WKWebViewConfiguration()
        // 不落盘：Cookie、localStorage 全部随这次渲染消失。抓一篇文章不该
        // 在用户机器上留下这个站点的登录痕迹。
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.suppressesIncrementalRendering = true

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1_280, height: 2_000),
            configuration: configuration
        )
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15 Mnemo/1.0"

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
