import SwiftUI
import WebKit

/// 小红书登录页——真实加载 `www.xiaohongshu.com`，用户在里面用小红书官方
/// 支持的任意方式登录（扫码、手机号验证码……）。不自己实现登录协议，也就
/// 不用跟着小红书改登录方式而跟着改；小红书支持什么，这里就有什么。
///
/// 用持久化的 `WKWebsiteDataStore.default()`（不是 `.nonPersistent()`）：
/// 一是这样登录完 cookie 才留得住，`XiaohongshuSession.adopt` 才有东西可抄；
/// 二是下次重新打开这张登录页时，WKWebView 自己记得登录态，不用每次都重新
/// 走一遍验证码。
struct XiaohongshuLoginSheet: View {
    @Binding var isPresented: Bool
    @State private var savedCount: Int?
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            XiaohongshuLoginWebView()
                .frame(minWidth: 440, minHeight: 560)
            Divider()
            footer
        }
        .frame(width: 480, height: 680)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("登录小红书")
                .font(.system(size: 15, weight: .semibold))
            Text("用你自己的账号登录后，抓取笔记走的是登录访问那条路，不再依赖分享链接里会过期的临时令牌，也不容易被当成匿名访问限流。登录方式和小红书官网完全一致——扫码、手机号验证码都支持。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let savedCount {
                Label("已保存登录状态（\(savedCount) 项）", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Text("在上方完成登录后，点击右侧按钮保存登录状态。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("取消") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button {
                Task {
                    isSaving = true
                    savedCount = await XiaohongshuSession.adopt(from: .default())
                    isSaving = false
                    // 给用户一眼看到"保存了多少项"的反馈，不立刻关掉——
                    // 万一登录其实还没完成（保存数是 0 或很小），用户能看出来
                    // 还要再等一下，而不是窗口一闭就以为大功告成了。
                    try? await Task.sleep(for: .seconds(1.1))
                    isPresented = false
                }
            } label: {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("完成登录，保存")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving)
        }
        .padding(16)
    }
}

private struct XiaohongshuLoginWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // 不覆盖 UA：这是给用户本人交互登录用的真实浏览会话，用系统默认的
        // Safari 内核 UA 就是"看起来像一个正常浏览器"，不需要也不该伪装成
        // 别的东西——那是匿名抓取路径（LinkContentFetcher）才做的事。
        webView.load(URLRequest(url: URL(string: "https://www.xiaohongshu.com")!))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
