import Foundation
import Testing
@testable import MnemoCore

@Test("小红书 / 抖音 / B站的分享文案都认得出来，并取到原标题")
func recognizesRealSharePayloads() throws {
    let xhs = try #require(ShareLinkExtractor.first(
        in: "19 【北海道vlog】跟着我一起吃遍札幌 😆 http://xhslink.com/a/abc123，复制本条信息，打开【小红书】App查看精彩内容！"
    ))
    #expect(xhs.isSharePayload)
    #expect(xhs.url.host() == "xhslink.com")
    #expect(xhs.title == "北海道vlog")

    let douyin = try #require(ShareLinkExtractor.first(
        in: "7.85 复制打开抖音，看看【小明】的作品 https://v.douyin.com/abc/ 复制此链接，打开Dou音搜索，直接观看视频！"
    ))
    #expect(douyin.isSharePayload)
    #expect(douyin.title == "小明")

    let bilibili = try #require(ShareLinkExtractor.first(
        in: "【硬核解读 RDMA 拥塞控制】 https://b23.tv/xyz789"
    ))
    #expect(bilibili.isSharePayload)
    #expect(bilibili.title == "硬核解读 RDMA 拥塞控制")
}

@Test("裸链接仍然算分享，标题取不到就老实返回 nil")
func bareURLIsStillAShare() throws {
    let link = try #require(ShareLinkExtractor.first(in: "https://www.bilibili.com/video/BV1xx"))
    #expect(link.isSharePayload)
    #expect(link.title == nil)
}

@Test("正文里引用了链接的笔记不改判成链接")
func proseWithALinkIsNotAShare() throws {
    let note = try #require(ShareLinkExtractor.first(in: """
    今天读了这篇讲 RDMA 丢包恢复的论文，作者提出用 bitmap 记录乱序到达的分片，
    在超大规模训练场景下比逐包重传省很多带宽。原文在 https://arxiv.org/abs/2401.00001
    我觉得第三节那个实验设计有问题，样本量太小，回头再看看。
    """))
    // 链接取得到，供界面使用；但整条 Pin 仍然是一段笔记。
    #expect(!note.isSharePayload)
    #expect(note.url.host() == "arxiv.org")
    #expect(note.title == nil)
}

@Test("一段话里有多个链接时绝不改判：那是引用了若干来源的正文")
func multipleLinksNeverPromote() throws {
    let text = "对比一下 https://github.com/a/b 和 https://github.com/c/d 这两个实现"
    let link = try #require(ShareLinkExtractor.first(in: text))
    #expect(!link.isSharePayload)
    #expect(ShareLinkExtractor.urls(in: text).count == 2)
}

@Test("短链域名一望即知是分享，不必再看剩下多长")
func shortShareHostsPromoteRegardlessOfLength() throws {
    // 前面挂了一长串描述，但 b23.tv 除了分享没有别的用途。
    let text = String(repeating: "这个视频讲得特别好我强烈推荐给你看一下。", count: 5)
        + " https://b23.tv/abc"
    let link = try #require(ShareLinkExtractor.first(in: text))
    #expect(link.isSharePayload)
}

@Test("没有链接的文字返回 nil")
func plainTextHasNoLink() {
    #expect(ShareLinkExtractor.first(in: "今天要看完项目并写完论文儿") == nil)
    #expect(ShareLinkExtractor.first(in: "") == nil)
}

@Test("Item.linkURL 是唯一出口：裸链接和分享文案都取得到")
func itemLinkURLHandlesBothShapes() {
    let bare = Item(
        title: "b",
        kind: .link,
        holding: .inline("https://www.bilibili.com/video/BV1xx")
    )
    #expect(bare.linkURL?.host() == "www.bilibili.com")

    let share = Item(
        title: "s",
        kind: .link,
        holding: .inline("【标题】 https://b23.tv/xyz789 复制此链接")
    )
    #expect(share.linkURL?.host() == "b23.tv")

    let plain = Item(title: "t", kind: .text, holding: .inline("没有链接"))
    #expect(plain.linkURL == nil)
}

@Test("分享文案能顺出平台，归类那一排因此也认得它")
func sharePayloadResolvesToPlatform() throws {
    let share = Item(
        title: "s",
        kind: .link,
        holding: .inline("19 【北海道vlog】 http://xhslink.com/a/abc123，复制本条信息")
    )
    let url = try #require(share.linkURL)
    #expect(LinkPlatform.resolve(url) == .xiaohongshu)
}
