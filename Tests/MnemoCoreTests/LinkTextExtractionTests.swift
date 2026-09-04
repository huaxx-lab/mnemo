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

// MARK: - 站点自己的结构化出口
//
// linux.do 和小红书的卡片此前一律显示"无法访问该链接内容"。实测两者既没有
// 拦爬虫也不要登录：linux.do 的 topic 页匿名返回 200 但正文一个字都不在
// HTML 里（Ember 空壳），小红书整篇笔记就写在 meta / __INITIAL_STATE__ 里。
// 通用 DOM 抽取对这两种形状都无解，所以走各站自己的公开出口。

@Suite("站点结构化抽取")
struct SiteContentExtractionTests {

    @Test("Discourse 话题页推导出 .json 地址")
    func discourseTopicJSONURL() throws {
        let plain = try #require(URL(string: "https://linux.do/t/topic/2808529"))
        #expect(
            SiteContentExtraction.Discourse.topicJSONURL(for: plain)?.absoluteString
                == "https://linux.do/t/topic/2808529.json"
        )

        // 带 slug、带楼层号、带查询串：`.json` 只能挂到话题 id 上，
        // 带着楼层号请求会 404。
        let deep = try #require(URL(string: "https://linux.do/t/some-slug/1234/56?u=me"))
        #expect(
            SiteContentExtraction.Discourse.topicJSONURL(for: deep)?.absoluteString
                == "https://linux.do/t/some-slug/1234.json"
        )

        // 不是话题页就不该乱猜。
        let listing = try #require(URL(string: "https://linux.do/latest"))
        #expect(SiteContentExtraction.Discourse.topicJSONURL(for: listing) == nil)
    }

    @Test("Discourse 话题 JSON 拼出整串楼层")
    func discourseTopicJSON() throws {
        let json = """
        {"title":"解读 Harness 的核心论文",
         "post_stream":{"posts":[
           {"post_number":1,"username":"davy","cooked":"<p>先概括一下 Harness。</p>"},
           {"post_number":2,"username":"someone","cooked":"<p>学到了，感谢分享。</p>"},
           {"post_number":3,"username":"empty","cooked":"<p>   </p>"}
         ]}}
        """
        let extracted = try #require(
            SiteContentExtraction.Discourse.extract(fromTopicJSON: Data(json.utf8))
        )
        #expect(extracted.title == "解读 Harness 的核心论文")
        #expect(extracted.text.contains("先概括一下 Harness"))
        #expect(extracted.text.contains("学到了，感谢分享"))
        // 楼号和作者要留着：检索命中时能看出这句话是谁在第几楼说的。
        #expect(extracted.text.contains("#1 davy"))
        // 纯空白的楼层不该留下一个空块。
        #expect(!extracted.text.contains("#3"))
    }

    @Test("小红书笔记正文从内嵌状态里取，比截断的 meta 完整")
    func xiaohongshuNote() throws {
        let html = """
        <html><head><title>夜间畅蹬 - 小红书</title>
        <meta name="description" content="即日起至9月20日开启活动">
        </head><body><div id="app"></div>
        <script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{"x":{"note":
        {"title":"夜间畅蹬","desc":"即日起至9月20日，开启「Flash」活动：\\n每天23:00 起生效，说\\"免费\\"就是免费。"}}}}}</script>
        </body></html>
        """
        let note = try #require(SiteContentExtraction.Xiaohongshu.extract(fromHTML: html))
        #expect(note.contains("每天23:00 起生效"))
        // JSON 转义要真的解开：换行是换行，转义引号是引号。
        #expect(note.contains("\n"))
        #expect(note.contains("\"免费\""))
    }

    @Test("不是小红书的页面不误判")
    func xiaohongshuRejectsOtherPages() {
        #expect(SiteContentExtraction.Xiaohongshu.extract(fromHTML: "<html><body>普通页面</body></html>") == nil)
    }

    @Test("页面自报的摘要被读出来")
    func metaSummary() {
        // 前端渲染的站点 DOM 里没有正文，meta 是唯一能匿名拿到的那份。
        let html = """
        <html><head><title>标题</title>
        <meta property="og:description" content="这是分享卡片用的完整摘要。">
        <meta name="description" content="这是 SEO 摘要。">
        </head><body><div id="app"></div></body></html>
        """
        let extracted = LinkTextExtraction.fromHTML(html)
        #expect(extracted.summary == "这是分享卡片用的完整摘要。")
    }
}

@Suite("链接配图")
struct LinkCoverExtractionTests {

    @Test("小红书取笔记自己的图，不是平台静态资源")
    func xiaohongshuNoteImage() throws {
        // og:image 指向 fe-platform 的静态图，一排卡片会长得一模一样；
        // 真正的配图在 imageList 里，路径用 / 转义。
        let html = #"""
        <html><head>
        <meta property="og:image" content="//picasso-static.xiaohongshu.com/fe-platform/logo.png">
        </head><body><script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{"x":{"note":
        {"imageList":[{"infoList":[
        {"imageScene":"WB_PRV","url":"http://sns-webpic-qc.xhscdn.com/a/b!nd_prv_wlteh_jpg_3"},
        {"imageScene":"WB_DFT","url":"http://sns-webpic-qc.xhscdn.com/a/b!nd_dft_wlteh_jpg_3"}
        ]}]}}}}}</script></body></html>
        """#
        let url = try #require(SiteContentExtraction.Xiaohongshu.noteImageURL(fromHTML: html))
        #expect(url.absoluteString.contains("xhscdn.com/a/b"))
        // 原图优先于预览小图。
        #expect(url.absoluteString.contains("nd_dft"))
    }

    @Test("没有笔记图时退回页面自报的配图")
    func fallsBackToOpenGraph() throws {
        let html = """
        <html><head>
        <meta property="og:image" content="//cdn.example.com/cover.png">
        </head><body></body></html>
        """
        #expect(SiteContentExtraction.Xiaohongshu.noteImageURL(fromHTML: html) == nil)
        let base = try #require(URL(string: "https://example.com/post/1"))
        let url = try #require(LinkTextExtraction.metaImageURL(html: html, baseURL: base))
        // 协议相对地址要按页面地址补全，不能原样丢给 URLSession。
        #expect(url.absoluteString == "https://cdn.example.com/cover.png")
    }
}

@Test("小红书结构化正文压过登录墙 DOM")
func xiaohongshuStructuredTextIsAuthoritative() throws {
    let html = #"""
    <html><head><title>真实笔记标题 - 小红书</title></head><body>
    <main><p>可用小红书或微信扫码。手机号登录。我已阅读并同意用户协议。</p>
    <script>window.__INITIAL_STATE__={"noteDetailMap":{"x":{"note":{
      "desc":"这才是笔记正文：今天分享如何准备秋招。\n第二段是投递建议。",
      "imageList":[{"infoList":[
        {"imageScene":"WB_DFT","url":"https://sns-webpic-qc.xhscdn.com/real-note.jpg"}
      ]}]
    }}}}</script>
    </body></html>
    """#
    let text = try #require(SiteContentExtraction.Xiaohongshu.extract(fromHTML: html))
    #expect(text.contains("这才是笔记正文"))
    #expect(!text.contains("手机号登录"))
    let image = try #require(SiteContentExtraction.Xiaohongshu.noteImageURL(fromHTML: html))
    #expect(image.absoluteString == "https://sns-webpic-qc.xhscdn.com/real-note.jpg")
}

@Test("Discourse 每层楼形成带来源的独立语义段")
func discoursePostsBecomeSegments() throws {
    let json = #"""
    {"title":"测试主题","post_stream":{"posts":[
      {"cooked":"<p>第一层正文</p>","username":"alice","post_number":1},
      {"cooked":"<p>第二层正文</p>","username":"bob","post_number":2}
    ]}}
    """#
    let result = try #require(
        SiteContentExtraction.Discourse.extract(fromTopicJSON: Data(json.utf8))
    )
    let segments = try #require(result.segments)
    #expect(segments.count == 2)
    #expect(segments[0].contains("《测试主题》"))
    #expect(segments[0].contains("#1 alice"))
    #expect(segments[1].contains("#2 bob"))
}

@Test("抓取失败状态文案不被当作用户标题保护")
func failedLinkTitlesRemainReplaceable() {
    #expect(LinkTextExtraction.isFailurePlaceholderTitle("无法访问链接内容"))
    #expect(LinkTextExtraction.isFailurePlaceholderTitle(" Loading… "))
    #expect(!LinkTextExtraction.isFailurePlaceholderTitle("用户自己写的标题"))
}

@Test("小红书登录墙需要两个稳定标记才判定")
func xiaohongshuLoginWallFingerprint() {
    #expect(SiteContentExtraction.Xiaohongshu.isLoginWall(
        "可用小红书或微信扫码，手机号登录，我已阅读并同意用户协议"
    ))
    #expect(!SiteContentExtraction.Xiaohongshu.isLoginWall(
        "这篇文章讨论账号登录的交互设计"
    ))
    #expect(!SiteContentExtraction.Xiaohongshu.isLoginWall("请阅读隐私政策"))
}
