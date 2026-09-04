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
