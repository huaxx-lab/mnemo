import Foundation
import Testing
@testable import MnemoCore

/// 用真实抓下来的页面测站点抽取。
///
/// 样本存在 `Fixtures/`，不是手写的简化 HTML——这类规则每次出错都是因为
/// 真实页面和想象中的不一样，手写样本只会把同一个误解照抄进测试里。
private func fixture(_ name: String) throws -> String {
    let url = try #require(
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "html"),
        "找不到样本 \(name).html"
    )
    return try String(contentsOf: url, encoding: .utf8)
}

@Test("小红书：作者填了标题时用它自己的标题，不带平台后缀")
func xiaohongshuUsesAuthoredTitle() throws {
    let html = try fixture("xhs-with-title")
    #expect(SiteContentExtraction.Xiaohongshu.title(fromHTML: html) == "9.4 美团ai应用一面")
}

@Test("小红书：用户实报页面完整回归——标题、短正文、首图一次绑定")
func xiaohongshuReportedLivePageExtractsCompletely() throws {
    let html = try fixture("xhs-live-6a9a466c")
    let url = try #require(URL(string:
        "https://www.xiaohongshu.com/explore/6a9a466c00000000270147fc?xsec_token=sample"
    ))
    let note = try #require(SiteContentExtraction.Xiaohongshu.note(fromHTML: html, url: url))
    #expect(note.title == "已经可以全面兼容codex micro 了")
    #expect(note.text == "外设和按键刚刚够，真是天意巧合")
    #expect(note.imageURLs.count == 1)
    #expect(note.imageURLs[0].scheme == "https")
    #expect(note.imageURLs[0].absoluteString.contains("1040g3k0324mb7kqvga005q3efga3drut1kim4o8"))
}

@Test("小红书：按 URL 的 note id 绑定同一条记录，不会串到推荐流的同名字段")
func xiaohongshuSelectsTheRequestedNoteRecord() throws {
    let html = """
    <html><body><script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{
      "wrong":{"note":{"title":"推荐流标题","desc":"推荐流正文","imageList":[{"urlDefault":"http://img.example/wrong.jpg"}]}},
      "target":{"note":{"title":"目标标题","desc":"目标正文\\n第二行","imageList":[{"urlDefault":"http://img.example/target.jpg"}]}}
    }},"noise":{"title":"外层噪音","desc":"外层正文","imageList":[]}}</script></body></html>
    """
    let url = try #require(URL(string: "https://www.xiaohongshu.com/explore/target?xsec_token=abc"))
    let note = try #require(SiteContentExtraction.Xiaohongshu.note(fromHTML: html, url: url))
    #expect(note.title == "目标标题")
    #expect(note.text == "目标正文\n第二行")
    #expect(note.imageURLs.map(\.absoluteString) == ["https://img.example/target.jpg"])
    #expect(note.segments == ["目标正文", "第二行"])
}

@Test("小红书：被限流/风控返回的通用页，标语标题绝不当作笔记标题写回")
func xiaohongshuRejectsGenericSiteFallbackPage() throws {
    // 用户实报：一次批量迁移撞上这种响应，五条互不相关的笔记被同时写成
    // 同一句"小红书 - 你的生活兴趣社区"，顶掉了之前抓对的真标题。这是网站
    // 拿不到具体笔记时（限流/需要登录/笔记被删）回落的**整站默认页**，
    // og:title 和 <title> 完全一样，跟任何一条笔记都无关——没有
    // __INITIAL_STATE__ 笔记数据，只有这句通用标语。
    let html = """
    <html><head>
      <title>小红书 - 你的生活兴趣社区</title>
      <meta property="og:title" content="小红书 - 你的生活兴趣社区">
    </head><body></body></html>
    """
    let url = try #require(URL(string: "https://www.xiaohongshu.com/explore/blocked-note"))
    #expect(SiteContentExtraction.Xiaohongshu.note(fromHTML: html, url: url) == nil)
    #expect(SiteContentExtraction.Xiaohongshu.title(fromHTML: html) == nil)
}

@Test("小红书：标题命中通用标语时，整份响应判失败，不逐字段单独抢救")
func xiaohongshuGenericTitlePageFailsEntirely() throws {
    // og:title 命中标语说明这整份响应是网站自己的通用页，不是这条笔记的——
    // og:description 大概率也是同一份通用页的内容（这里故意配一段听起来
    // 也很像宣传语的摘要），不能"标题不算数、摘要单独抢救"，否则换一种
    // 通用文案措辞又会从另一个字段漏过去。
    let html = """
    <html><head>
      <title>小红书 - 你的生活兴趣社区</title>
      <meta property="og:title" content="小红书 - 你的生活兴趣社区">
      <meta property="og:description" content="发现更多有趣的内容，加入小红书一起分享生活。">
    </head><body></body></html>
    """
    let url = try #require(URL(string: "https://www.xiaohongshu.com/explore/blocked-note-2"))
    #expect(SiteContentExtraction.Xiaohongshu.note(fromHTML: html, url: url) == nil)
}

@Test("小红书：真实笔记标题即便含平台名，也不会被误判为通用标语")
func xiaohongshuRealTitleMentioningPlatformSurvives() throws {
    // 泛化判据只认"你的生活兴趣社区"这句固定标语，不按"含不含'小红书'
    // 三个字"这种宽判据，否则会误伤内容里正常提到平台名的真实标题。
    let html = """
    <script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{"target":{"note":{
      "title":"小红书上的干货分享合集","desc":"正文","imageList":[]
    }}}}}</script>
    """
    let url = try #require(URL(string: "https://www.xiaohongshu.com/explore/target"))
    let note = try #require(SiteContentExtraction.Xiaohongshu.note(fromHTML: html, url: url))
    #expect(note.title == "小红书上的干货分享合集")
}

@Test("小红书：状态里的裸 undefined 只在 JSON 字符串外替换")
func xiaohongshuHandlesJavaScriptUndefinedWithoutChangingAuthoredText() throws {
    let html = """
    <script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{"target":{"note":{
      "title":"undefined 不是空值","desc":"正文也可以写 undefined","imageList":[],"extra":undefined
    }}}}}</script>
    """
    let url = try #require(URL(string: "https://www.xiaohongshu.com/explore/target"))
    let note = try #require(SiteContentExtraction.Xiaohongshu.note(fromHTML: html, url: url))
    #expect(note.title == "undefined 不是空值")
    #expect(note.text == "正文也可以写 undefined")
}

@Test("小红书：作者没填标题时取正文首句，而不是把整段正文当标题")
func xiaohongshuFallsBackToLeadingSentence() throws {
    let html = try fixture("xhs-without-title")
    let title = try #require(SiteContentExtraction.Xiaohongshu.title(fromHTML: html))
    // <title> 那一版是整段正文（两百多字）加 " - 小红书"，绝不能拿来当标题。
    #expect(title.count <= 50, "标题过长，说明又把整段正文当标题了：\(title)")
    #expect(!title.contains("小红书"), "平台后缀没剥掉")
    #expect(!title.contains("[话题]"), "话题记号没清掉")
    #expect(!title.isEmpty)
}

@Test("小红书：正文里的 [话题]# 记号被清掉，主题词本身保留")
func xiaohongshuStripsTopicMarkers() throws {
    let html = try fixture("xhs-without-title")
    let body = try #require(SiteContentExtraction.Xiaohongshu.extract(fromHTML: html))
    #expect(!body.contains("[话题]#"), "平台内部记号不该进 RAG")
    #expect(body.contains("考研人"), "主题词是这条笔记的内容，不能一起删掉")
}

@Test("小红书：清单体正文按作者换的行分段")
func xiaohongshuListBodySplitsIntoLines() throws {
    let html = try fixture("xhs-with-title")
    let segments = try #require(SiteContentExtraction.Xiaohongshu.bodySegments(fromHTML: html))
    // 真实笔记：48 条编号面试题 + 结尾一句反问体会。
    #expect(segments.count == 49)
    #expect(segments.first?.hasPrefix("1.北京作为工作地点") == true)
    #expect(segments.last?.hasPrefix("无手撕") == true)

    // 这份笔记总长没超过一个窗口，正确结果恰恰是不切——整块留下，
    // 按段缝拆开要恰好还原每一行。
    let chunks = ContentChunking.chunks(
        itemID: UUID(),
        segments: segments,
        source: .linkPage,
        pageNumber: nil,
        ordinalBase: 0
    )
    #expect(chunks.flatMap { $0.text.components(separatedBy: "\n\n") } == segments)
}

@Test("小红书：长清单分块沿行边界走，按字数硬切会对照出半行")
func xiaohongshuLongListChunksOnLineBoundaries() throws {
    // 60 条、每条约 30 字，总量超出一个窗口：这是分块真正要做选择的场景。
    let lines = (1...60).map { "第\($0)条清单：这是一条大约三十个字左右的条目内容填充填充" }
    let jsonDesc = lines.joined(separator: "\\n")
    let html = """
    <html><body><script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{"x":{"note":
    {"desc":"\(jsonDesc)","imageList":[]}}}}}</script></body></html>
    """
    let segments = try #require(SiteContentExtraction.Xiaohongshu.bodySegments(fromHTML: html))
    #expect(segments == lines)

    let chunks = ContentChunking.chunks(
        itemID: UUID(), segments: segments, source: .linkPage,
        pageNumber: nil, ordinalBase: 0
    )
    #expect(chunks.count > 1, "超过一个窗口的长清单不该只有一块")
    for chunk in chunks {
        for piece in chunk.text.components(separatedBy: "\n\n") {
            #expect(lines.contains(piece), "块里出现了被切断的半行：\(piece)")
        }
    }

    // 对照组：同一段文字按字数硬切，第一块必然断在某一条的中间。
    let hardChunks = ContentChunking.chunks(
        itemID: UUID(), text: lines.joined(separator: "\n"), source: .linkPage,
        pageNumber: nil, ordinalBase: 0
    )
    #expect(hardChunks.count > 1)
    #expect(hardChunks[0].text.components(separatedBy: "\n").contains { !lines.contains($0) })
}

@Test("小红书：多图笔记的每张配图地址都能取到，按顺序、取原图")
func xiaohongshuListsAllNoteImages() throws {
    // 这份样本由真实页面派生：真实页面本身只有一张图，覆盖不了"多图"这条
    // 规则，第二条图片记录是按同页第一条的真实结构复制的。
    let html = try fixture("xhs-multi-image")
    let urls = SiteContentExtraction.Xiaohongshu.noteImageURLs(fromHTML: html)
    #expect(urls.count == 2)
    #expect(urls[0].absoluteString.contains("1040g2sg"), "顺序要跟笔记里的图序一致")
    #expect(urls[1].absoluteString.contains("2040g2sg"))
    for url in urls {
        #expect(url.scheme == "https", "状态里的 http CDN 必须升级成 HTTPS")
        #expect(url.absoluteString.contains("nd_dft"), "要原图，不要预览小图")
        #expect(!url.absoluteString.contains("u002F"), "路径转义没解开：\(url)")
    }
    // 首图接口与全量接口必须指向同一张图。
    #expect(SiteContentExtraction.Xiaohongshu.noteImageURL(fromHTML: html) == urls.first)
}

@Test("小红书：结构化状态坏掉时从 JSON-LD/meta 保住标题、正文和首图")
func xiaohongshuFallsBackToMetadata() throws {
    let html = """
    <html><head>
      <title>元数据标题 - 小红书</title>
      <meta property="og:description" content="元数据正文">
      <meta property="og:image" content="http://img.example/fallback.jpg">
    </head><body><script>window.__INITIAL_STATE__={broken</script></body></html>
    """
    let url = try #require(URL(string: "https://www.xiaohongshu.com/explore/target"))
    let note = try #require(SiteContentExtraction.Xiaohongshu.note(fromHTML: html, url: url))
    #expect(note.title == "元数据标题")
    #expect(note.text == "元数据正文")
    #expect(note.imageURLs.map(\.absoluteString) == ["https://img.example/fallback.jpg"])
}

@Test("小红书：状态里出现 new Map(...) 时，笔记本身仍要能解析出来")
func xiaohongshuSurvivesJavaScriptMapConstructor() throws {
    // 平台把一部分 store 直接序列化成了 `new Map(...)` 这种构造表达式。它出现
    // 在我们根本不读的分店里，但 JSONSerialization 是全有全无的——不处理的话
    // 整份状态解析失败，笔记的 imageList 跟着拿不到，悄悄退回 og:image 兜底，
    // 而那正是平台 logo。线上"标题正文都对、唯独封面是红方块"就是这么来的。
    let html = """
    <html><head><meta property="og:image" content="https://picasso-static.xiaohongshu.com/fe-platform/logo.png"></head>
    <body><script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{"target":{"note":
    {"title":"真实标题","desc":"真实正文","imageList":[
    {"url":"","infoList":[{"imageScene":"WB_PRV","url":"http://sns-webpic-qc.xhscdn.com/a!nd_prv"},
    {"imageScene":"WB_DFT","url":"http://sns-webpic-qc.xhscdn.com/a!nd_dft"}]}]}}}},
    "AiNoteDetailStore":{"noteDetailMap":new Map([["k",{"v":1}]]),"other":undefined}}</script></body></html>
    """
    let url = try #require(URL(string: "https://www.xiaohongshu.com/explore/target"))
    let note = try #require(SiteContentExtraction.Xiaohongshu.note(fromHTML: html, url: url))
    #expect(note.title == "真实标题", "走通结构化状态，而不是退回 og:title")
    #expect(note.text == "真实正文")
    #expect(
        note.imageURLs.map(\.absoluteString) == ["https://sns-webpic-qc.xhscdn.com/a!nd_dft"],
        "imageList 没有 urlDefault 时要从 infoList 取 WB_DFT，并升级成 HTTPS"
    )
}

@Test("小红书：imageList 里的平台占位图不能当成笔记配图")
func xiaohongshuRejectsPlatformPlaceholderImage() throws {
    // 分享链接的 token 失效时，页面照给真标题真正文，imageList 却换成了
    // 平台前端静态资源里的通用 logo。这张图一旦被当成真配图，卡片会显示
    // 成红方块，更要命的是它会被送进 OCR，在 RAG 里留下从 logo 上认出来
    // 的碎字。
    let html = """
    <html><body><script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{"target":{"note":
    {"title":"真实笔记标题","desc":"真实正文","imageList":[
    {"urlDefault":"https://picasso-static.xiaohongshu.com/fe-platform/abc123.png"}]}}}}}</script></body></html>
    """
    let url = try #require(URL(string: "https://www.xiaohongshu.com/explore/target"))
    let note = try #require(SiteContentExtraction.Xiaohongshu.note(fromHTML: html, url: url))
    #expect(note.title == "真实笔记标题", "正文和标题是真的，不能因为图假就整条丢掉")
    #expect(note.text == "真实正文")
    #expect(note.imageURLs.isEmpty, "占位图必须被剔掉，宁可没有封面也不要一张假的")
}

@Test("小红书：og:image 退回路径同样要挡掉平台占位图")
func xiaohongshuRejectsPlaceholderFromMetaImage() throws {
    let html = """
    <html><head>
      <title>真实标题 - 小红书</title>
      <meta property="og:description" content="真实正文">
      <meta property="og:image" content="https://picasso-static.xiaohongshu.com/fe-platform/logo.png">
    </head><body><script>window.__INITIAL_STATE__={broken</script></body></html>
    """
    let url = try #require(URL(string: "https://www.xiaohongshu.com/explore/target"))
    let note = try #require(SiteContentExtraction.Xiaohongshu.note(fromHTML: html, url: url))
    #expect(note.title == "真实标题")
    #expect(note.imageURLs.isEmpty)
}

@Test("小红书：内容 CDN 上的真实配图不受占位图判据影响")
func xiaohongshuKeepsRealCDNImage() throws {
    let html = """
    <html><body><script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{"target":{"note":
    {"title":"标题","desc":"正文","imageList":[
    {"urlDefault":"https://sns-webpic-qc.xhscdn.com/202609/abc/1040g2sg!nd_dft.jpg"}]}}}}}</script></body></html>
    """
    let url = try #require(URL(string: "https://www.xiaohongshu.com/explore/target"))
    let note = try #require(SiteContentExtraction.Xiaohongshu.note(fromHTML: html, url: url))
    #expect(note.imageURLs.count == 1, "判据只排除已证实的平台资源，不能误伤真配图")
}

@Test("小红书：正文只有一行时不分段，交给通用按字数切")
func xiaohongshuSingleLineBodyHasNoSegments() throws {
    let html = """
    <html><body><script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{"x":{"note":
    {"desc":"就一句话的笔记，没有换行","imageList":[]}}}}}</script></body></html>
    """
    #expect(SiteContentExtraction.Xiaohongshu.bodySegments(fromHTML: html) == nil)
}

@Test("GitHub：仓库页认得出来，功能页不会被误判")
func gitHubRecognizesRepositoryPages() throws {
    #expect(SiteContentExtraction.GitHub.isRepositoryPage(
        URL(string: "https://github.com/huaxx-lab/mnemo")!
    ))
    #expect(!SiteContentExtraction.GitHub.isRepositoryPage(
        URL(string: "https://github.com/settings/profile")!
    ))
    #expect(!SiteContentExtraction.GitHub.isRepositoryPage(
        URL(string: "https://github.com/huaxx-lab/mnemo/issues/1")!
    ))
    #expect(!SiteContentExtraction.GitHub.isRepositoryPage(
        URL(string: "https://github.com/huaxx-lab")!
    ))
}

@Test("GitHub：标题剥掉平台样板，README 正文进 RAG")
func gitHubExtractsReadme() throws {
    let html = try fixture("github-repo")
    let url = URL(string: "https://github.com/huaxx-lab/mnemo")!
    let extracted = try #require(SiteContentExtraction.GitHub.extract(fromHTML: html, url: url))

    let title = try #require(extracted.title)
    #expect(title.hasPrefix("huaxx-lab/mnemo"), "标题该以 owner/repo 打头：\(title)")
    #expect(!title.contains("· GitHub"), "平台样板没剥掉")

    // 描述里那句对每个仓库都一样的招募语必须去掉，否则所有 GitHub 链接的
    // 向量会互相靠拢。
    #expect(extracted.summary?.contains("Contribute to") != true)

    // README 的实质内容要进来。
    #expect(extracted.text.contains("刘海"), "README 正文没抓到")
    let segments = extracted.segments ?? []
    #expect(segments.count > 5, "README 该按语义段切开，实际 \(segments.count) 段")
}
