import Foundation
@testable import MnemoCore

/// 检索证据的评测语料。
///
/// 和 `TodoRecognitionCorpus` 同一个角色：逐条行为测试回答"这一条为什么该
/// 这样"，语料回答"整体上对多少"。
///
/// 这里衡量的**不是**排序好不好，而是一个更前置、更致命的问题：
/// **答案那句话到底有没有进到发给模型的负载里**。排得再准，证据里没有那行字，
/// 模型也只能编或者说不知道。用户报的"最后那个 GitHub 链接他根本不知道"
/// 就是这一类——是 rag-01。
enum RetrievalEvalCorpus {

    struct Case: Sendable {
        var id: String
        var category: String
        /// 用户会怎么问。
        var query: String
        /// 答案所在的条目标题。它有没有进候选，是"召回"这一层。
        var goldDocument: String
        /// 答案所在的那段原文，必须原样出现在负载里才算证据完整。
        var goldSpan: String
        /// 这一条想守住的东西，一句话。
        var note: String
    }

    /// 一个条目：标题 + 正文。正文按 kind 决定进哪种分块。
    struct Document: Sendable {
        var title: String
        var body: String
        var kind: ItemKind = .text
    }

    static let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 5; c.hour = 10
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: c)!
    }()

    // MARK: - 库

    /// 用户真实发来的那段产品文案。GitHub 链接在**最后一行**——旧实现三道
    /// 头部截断都够不到它，这一条就是本次优化的靶子。
    static let mnemoIntro = """
    最近看着 Mac 的刘海想着结合 RAG 和 LLM 做一个增效的 AI 工具，就有了 Mnemo。开源免费，
    核心功能就是：
    看到什么，往刘海一拖就行。
    刷到的好文章、群里的通知、PDF 论文、Word 文档，随手拖到刘海顶部就存好了。
    然后配合快捷键和 RAG，平时散落各处的碎片内容，就这样慢慢攒成了你自己的知识库——想找文件，说句话就能拿到；想问里面的内容，直接就能问出答案。
    举几个我自己在用的场景：
    - 麦当劳取餐码的截图扔进去，它自己认出来，到点提醒你
    - 群里的日程通知截图，自动拆成几条待办，上午的九点响、下午的两点响
    - 「我的阿里云密钥在哪」——它真的找得到，哪怕藏在截图里
    - 论文存了好几个版本，它认得出哪版最新，聚成一摞卡片
    - 手机上复制的文字，自动出现在 Mac 的刘海里
    - macOS 26+：开源链接github.com/huaxx-lab/mnemo
    还有一些好玩的功能，朋友们可以自行探索 😄
    """

    /// 一篇长会议纪要：结论写在最后，是"头部截断"最典型的受害者。
    static let meetingNotes = """
    9 月 3 日 项目周会纪要

    参会：产品、前端、后端、测试
    议题一：本周迭代进度回顾。前端完成了卡片轨道的重构，后端把索引队列拆成了两条通道，
    测试补了三十多条回归用例。整体进度符合预期，没有阻塞项。
    议题二：下个版本的范围讨论。产品希望把分享功能提前，前端评估需要两周，后端认为
    依赖的权限模型还没定稿。经过讨论，先做权限模型，分享功能顺延。
    议题三：线上问题复盘。上周五的那次超时是连接池配置过小导致的，已经调整并观察三天，
    没有复现。后续把连接池参数纳入监控面板。
    议题四：其他事项。工位调整下周一执行，各自提前收拾。团建时间待定。

    结论：下个版本的发布窗口定在 10 月 17 日，代码冻结日是 10 月 10 日。
    发布负责人是后端的老王，回滚预案由测试负责编写。
    """

    /// 一段短文本，答案就在开头——用来确认改动没有把"本来就对"的搞坏。
    static let apiKeyNote = """
    阿里云百炼的 API Key 是 sk-bailian-7f3a92 ，存在密钥管理页面里。
    北京区域的 endpoint 和杭州不一样，调用前记得改。
    """

    /// 干扰项。
    ///
    /// 语料必须撑到候选池装满（24 条），否则"总预算 / 候选数"那一刀根本落不
    /// 下来——只放三篇文档时每条候选能分到六千多字，旧实现看起来毫发无伤，
    /// 而用户真实库里有几十个条目，每条只分到三百多字。语料不还原这个压力，
    /// 对照组就是假的。
    static let distractors: [Document] = (1...24).map { index in
        Document(
            title: "无关笔记 \(index)",
            body: """
            这是第 \(index) 条无关内容，用来把候选池填满。里面谈的是完全不同的事情：
            周末去了趟郊区，路上堵了一个多小时，回来的时候顺路买了点水果。
            最近在看的那本书讲的是城市规划，作者的观点挺有意思，说街区尺度决定了
            人和人之间会不会相遇。晚上煮了面，加了个蛋。天气开始转凉了，得把厚衣服
            找出来。楼下新开了一家咖啡店，豆子是自己烘的，价格比连锁店便宜一些。
            """
        )
    }

    static let documents: [Document] = [
        .init(title: "Mnemo 产品介绍文案", body: mnemoIntro),
        .init(title: "项目周会纪要 9/3", body: meetingNotes),
        .init(title: "阿里云百炼密钥", body: apiKeyNote),
    ] + distractors

    // MARK: - 查询

    static let cases: [Case] = [
        .init(
            id: "rag-01",
            category: "尾部答案",
            query: "我那个软件的 github 链接在哪里",
            goldDocument: "Mnemo 产品介绍文案",
            goldSpan: "github.com/huaxx-lab/mnemo",
            note: "用户实报：链接在长文案最后一行，旧实现三道头部截断都够不到"
        ),
        .init(
            id: "rag-02",
            category: "尾部答案",
            query: "这次发布窗口定在什么时候",
            goldDocument: "项目周会纪要 9/3",
            goldSpan: "10 月 17 日",
            note: "会议纪要的结论永远在最后，按头部截断必然丢"
        ),
        .init(
            id: "rag-03",
            category: "尾部答案",
            query: "谁负责这次发布的回滚预案",
            goldDocument: "项目周会纪要 9/3",
            goldSpan: "回滚预案由测试负责编写",
            note: "同一篇的另一处末尾事实，防止只是碰巧命中"
        ),
        .init(
            id: "rag-04",
            category: "头部答案",
            query: "阿里云的密钥是多少",
            goldDocument: "阿里云百炼密钥",
            goldSpan: "sk-bailian-7f3a92",
            note: "回归护栏：本来就在开头的答案不能被改坏"
        ),
        .init(
            id: "rag-05",
            category: "中部答案",
            query: "刘海能自动识别取餐码吗",
            goldDocument: "Mnemo 产品介绍文案",
            goldSpan: "麦当劳取餐码的截图扔进去",
            note: "答案在正文中段，头部 400 字勉强够到、总预算那一刀不一定"
        ),
        .init(
            id: "rag-06",
            category: "中部答案",
            query: "上周五超时是什么原因",
            goldDocument: "项目周会纪要 9/3",
            goldSpan: "连接池配置过小",
            note: "长文中段的因果句"
        ),
        .init(
            id: "rag-07",
            category: "类型词误伤",
            query: "网页里提到的那个发布日期",
            goldDocument: "项目周会纪要 9/3",
            goldSpan: "10 月 17 日",
            note: "口语里的「网页」被解析成 kinds=[link]，会把答案所在的文本条目整类滤掉"
        ),
    ]
}
