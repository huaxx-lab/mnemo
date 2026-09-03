import Foundation
import Testing
@testable import MnemoCore

/// 一个结构上和真实文章站一样的页面：导航、正文、侧栏、页脚、脚本齐全。
private let articleHTML = """
<!doctype html>
<html lang="zh-CN">
<head>
  <title>如何理解 RDMA 的零拷贝 - 某某技术博客</title>
  <style>.hidden { display: none }</style>
  <script>window.analytics = { track: function () {} }</script>
</head>
<body>
  <header class="header"><a href="/">首页</a><a href="/about">关于</a></header>
  <nav class="navbar"><ul><li>技术</li><li>生活</li><li>归档</li></ul></nav>
  <main>
    <article>
      <h1>如何理解 RDMA 的零拷贝</h1>
      <p>RDMA 让网卡直接读写应用内存，绕开了内核协议栈的多次拷贝。这一段要足够长，
         才能通过正文子树的最小字数判定，所以这里再补充一些说明文字。</p>
      <p>传统 TCP 收包要经过网卡缓冲区、内核 socket 缓冲区、用户态缓冲区三次搬运，
         每一次都消耗 CPU 和内存带宽。零拷贝把中间两步去掉。</p>
      <blockquote>关键在于内存注册：应用必须提前把这块内存钉住，网卡才敢直接写。</blockquote>
    </article>
  </main>
  <aside class="sidebar"><h3>相关阅读</h3><p>一篇完全无关的推荐文章标题</p></aside>
  <div class="comments"><p>第一条评论：写得不错</p></div>
  <footer class="footer"><p>版权所有 2026 某某技术博客</p></footer>
  <script>console.log("tracking pixel")</script>
</body>
</html>
"""

@Test("取到标题，并且只取正文那一棵子树")
func extractsArticleBody() {
    let result = LinkTextExtraction.fromHTML(articleHTML, baseURL: URL(string: "https://example.com/post"))
    #expect(result.title == "如何理解 RDMA 的零拷贝 - 某某技术博客")
    #expect(result.text.contains("网卡直接读写应用内存"))
    #expect(result.text.contains("内存注册"))
}

@Test("导航、页脚、侧栏、评论、脚本全部不进正文")
func stripsBoilerplate() {
    let text = LinkTextExtraction.fromHTML(articleHTML).text
    // 这几段在同一站点的每一页上都一样。留着会让所有页面的向量互相靠拢，
    // 检索时一搜全中——比漏掉正文更难察觉。
    for noise in ["首页", "归档", "相关阅读", "第一条评论", "版权所有", "analytics", "tracking pixel"] {
        #expect(!text.contains(noise), "正文里混进了「\(noise)」")
    }
}

@Test("段落之间保留换行，不会挤成一整行")
func keepsParagraphBreaks() {
    let text = LinkTextExtraction.fromHTML(articleHTML).text
    #expect(text.contains("\n"))
    // 也不能反过来留下成片空行——那会浪费分块预算。
    #expect(!text.contains("\n\n\n"))
}

@Test("没有 article/main 时退回 body，仍然能取到内容")
func fallsBackToBody() {
    let html = """
    <html><head><title>纯 body 页面</title></head><body>
    <nav>导航</nav>
    <div>\(String(repeating: "这是一段足够长的正文内容。", count: 20))</div>
    </body></html>
    """
    let result = LinkTextExtraction.fromHTML(html)
    #expect(result.title == "纯 body 页面")
    #expect(result.text.contains("足够长的正文内容"))
    #expect(!result.text.contains("导航"))
}

@Test("空页面与畸形 HTML 不崩，返回空正文")
func degenerateHTML() {
    #expect(LinkTextExtraction.fromHTML("").isEmpty)
    #expect(LinkTextExtraction.fromHTML("<html><body></body></html>").isEmpty)
    // 标签没闭合是网上的常态，解析器要容忍。
    #expect(!LinkTextExtraction.fromHTML("<p>一段没有闭合的文字").isEmpty)
}

@Test("正文超长时截断到上限")
func clampsVeryLongText() {
    let long = String(repeating: "内容", count: LinkTextExtraction.maximumTextLength)
    let html = "<html><body><article><p>\(long)</p></article></body></html>"
    #expect(LinkTextExtraction.fromHTML(html).text.count <= LinkTextExtraction.maximumTextLength)
}

// MARK: - 类型分流

@Test("按 Content-Type 分流，而不是按后缀猜")
func routesByContentType() {
    let download = URL(string: "https://example.com/download?id=123")!
    #expect(LinkContentKind.of(mimeType: "application/pdf", url: download) == .pdf)
    #expect(LinkContentKind.of(mimeType: "text/html; charset=utf-8", url: download) == .webPage)
    #expect(LinkContentKind.of(mimeType: "image/png", url: download) == .image)
    #expect(LinkContentKind.of(mimeType: "video/mp4", url: download) == .video)
    #expect(LinkContentKind.of(mimeType: "application/json", url: download) == .plainText)
}

@Test("服务器没声明类型时才退回后缀")
func fallsBackToPathExtension() {
    #expect(LinkContentKind.of(
        mimeType: "application/octet-stream",
        url: URL(string: "https://example.com/paper.pdf")!
    ) == .pdf)
    #expect(LinkContentKind.of(
        mimeType: "",
        url: URL(string: "https://example.com/poster.png")!
    ) == .image)
    #expect(LinkContentKind.of(
        mimeType: "application/octet-stream",
        url: URL(string: "https://example.com/blob")!
    ) == nil)
}

@Test("HTML 的 Content-Type 优先于误导性的后缀")
func contentTypeWinsOverExtension() {
    // 图床的分享页后缀是 .png，返回的却是一张 HTML 页面。
    #expect(LinkContentKind.of(
        mimeType: "text/html",
        url: URL(string: "https://example.com/share/photo.png")!
    ) == .webPage)
}

@Test("导航菜单凑够字数也不算正文：闸门看的是有没有成段的句子")
func navigationJunkDoesNotCountAsProse() {
    // 阿里云控制台的真实形状：几十个两三字的菜单项，总字数轻松过 200，
    // 但一个成段的句子都没有。旧闸门按总字数放行，正文永远抓不到。
    let menu = (0..<60).map { "<li>菜单项\($0)</li>" }.joined()
    let shell = LinkTextExtraction.fromHTML("<html><body><ul>\(menu)</ul></body></html>")
    #expect(shell.text.count > LinkTextExtraction.minimumBodyLength)
    #expect(shell.longestParagraph < LinkTextExtraction.proseParagraphLength)

    let article = LinkTextExtraction.fromHTML("""
    <html><body><article><p>\(String(repeating: "远程内存直接访问让网卡绕过内核直接读写对端内存。", count: 8))</p></article></body></html>
    """)
    #expect(article.longestParagraph >= LinkTextExtraction.proseParagraphLength)
}
