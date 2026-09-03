import Foundation
import Testing
@testable import MnemoCore

@Test("常见平台按域名认得出来，子域名和短链都算")
func resolvesCommonPlatforms() {
    #expect(LinkPlatform.resolve("https://www.bilibili.com/video/BV1xx411c7mD") == .bilibili)
    #expect(LinkPlatform.resolve("https://m.bilibili.com/video/BV1xx") == .bilibili)
    #expect(LinkPlatform.resolve("https://b23.tv/abcdef") == .bilibili)
    #expect(LinkPlatform.resolve("https://youtu.be/dQw4w9WgXcQ") == .youtube)
    #expect(LinkPlatform.resolve("https://www.xiaohongshu.com/explore/123") == .xiaohongshu)
    #expect(LinkPlatform.resolve("https://xhslink.com/abc") == .xiaohongshu)
    #expect(LinkPlatform.resolve("https://mp.weixin.qq.com/s/abc") == .wechatArticle)
    #expect(LinkPlatform.resolve("https://github.com/apple/swift") == .github)
    #expect(LinkPlatform.resolve("https://arxiv.org/abs/2401.00001") == .arxiv)
}

@Test("知乎专栏和知乎问答分开：一个是文章，一个是问答串")
func separatesZhihuColumnFromQuestions() {
    #expect(LinkPlatform.resolve("https://www.zhihu.com/question/123") == .zhihu)
    #expect(LinkPlatform.resolve("https://zhuanlan.zhihu.com/p/456") == .zhihuZhuanlan)
    #expect(LinkPlatform.resolve("https://www.zhihu.com/p/456") == .zhihuZhuanlan)
}

@Test("认不出的域名返回 nil，绝不硬套一个平台")
func unknownHostsStayUnknown() {
    #expect(LinkPlatform.resolve("https://cdk.hybgzs.com/") == nil)
    #expect(LinkPlatform.resolve("https://developer.apple.com/design/") == nil)
    #expect(LinkPlatform.resolve("不是链接") == nil)
    #expect(LinkPlatform.resolve("") == nil)
}

@Test("后缀匹配不能被相似域名骗到")
func suffixMatchingIsNotFooled() {
    // notbilibili.com 不是 bilibili，evil.com/bilibili.com 也不是。
    #expect(LinkPlatform.resolve("https://notbilibili.com/x") == nil)
    #expect(LinkPlatform.resolve("https://evil.com/www.bilibili.com") == nil)
    // 真正的子域名要认。
    #expect(LinkPlatform.resolve("https://space.bilibili.com/123") == .bilibili)
}

@Test("每个平台都有名字")
func everyPlatformIsPresentable() {
    for platform in LinkPlatform.allCases {
        #expect(!platform.displayName.isEmpty, "\(platform) 少了显示名")
    }
}

@Test("常用社交 / 流媒体平台都配了图标，而且素材文件真的在")
func mainstreamPlatformsHaveShippedIcons() throws {
    // 断言"文件存在"而不是"返回了名字"：资源名拼错时前者会红，后者不会——
    // 而拼错的表现是界面上静默退回色块，正是最不容易被发现的那种坏法。
    let root = URL(filePath: #filePath)
        .deletingLastPathComponent()   // MnemoCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // 仓库根
        .appending(path: "Sources/MnemoApp/Resources/ServiceIcons")

    let mainstream: [LinkPlatform] = [
        .bilibili, .youtube, .douyin, .kuaishou, .tiktok, .netflix,
        .iqiyi, .youku, .tencentVideo,
        .xiaohongshu, .weibo, .zhihu, .zhihuZhuanlan, .x, .instagram,
        .reddit, .facebook, .threads, .douban, .tieba,
        .spotify, .appleMusic, .neteaseMusic, .qqMusic, .ximalaya,
        .wechatArticle, .github,
        .taobao, .tmall, .jd, .meituan, .pinduoduo, .amazon,
    ]
    for platform in mainstream {
        let name = try #require(platform.iconResourceName, "\(platform) 还没配图标")
        let file = root.appending(path: "\(name).jpg")
        #expect(
            FileManager.default.fileExists(atPath: file.path),
            "\(platform) 指向的素材 \(name).jpg 不存在"
        )
    }
}

@Test("没素材的平台老实返回 nil，界面退回域名色块")
func platformsWithoutArtworkStayNil() {
    // 挂一个错的图标比没有更糟：用户是靠图标一眼认平台的。
    #expect(LinkPlatform.arxiv.iconResourceName == nil)
    #expect(LinkPlatform.notion.iconResourceName == nil)
}

@Test("大类用来给归类那一排排序，同类挨在一起")
func categoriesGroupRelatedPlatforms() {
    #expect(LinkPlatform.bilibili.category == .video)
    #expect(LinkPlatform.xiaohongshu.category == .social)
    #expect(LinkPlatform.neteaseMusic.category == .audio)
    #expect(LinkPlatform.arxiv.category == .reading)
    #expect(LinkPlatform.taobao.category == .shopping)
    #expect(LinkPlatform.Category.video < LinkPlatform.Category.shopping)
}

@Test("子域名收敛到注册域，同一家的多个子站算一组")
func collapsesSubdomainsToRegistrableDomain() {
    #expect(RegistrableDomain.of("cdk.hybgzs.com") == "hybgzs.com")
    #expect(RegistrableDomain.of("ai.hybgzs.com") == "hybgzs.com")
    #expect(RegistrableDomain.of("bailian.console.aliyun.com") == "aliyun.com")
    #expect(RegistrableDomain.of("www.feihoa.com") == "feihoa.com")
    #expect(RegistrableDomain.of("labuladong.online") == "labuladong.online")
}

@Test("二级后缀不能被当成注册域")
func keepsMultiPartSuffixesIntact() {
    // 收成 com.cn 的话，所有中国站点会被归成同一组。
    #expect(RegistrableDomain.of("www.example.com.cn") == "example.com.cn")
    #expect(RegistrableDomain.of("news.bbc.co.uk") == "bbc.co.uk")
    #expect(RegistrableDomain.of("shop.rakuten.co.jp") == "rakuten.co.jp")
    // 本来就只有两段的原样返回。
    #expect(RegistrableDomain.of("example.com.cn") == "example.com.cn")
}
