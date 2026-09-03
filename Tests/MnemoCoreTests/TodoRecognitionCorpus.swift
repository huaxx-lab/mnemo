import Foundation
@testable import MnemoCore

/// 待办识别的评测语料。
///
/// 这份语料是**单一事实来源**：
///
/// - `TodoRecognitionEvalTests` 拿它算准确率、耗时，并导出报告；
/// - 逐条行为测试（`ClipboardTodoExtractionTests` / `TodoReconciliationTests`）
///   写的是"这一条为什么该这样"，语料写的是"整体上对多少"。两者不重复：
///   前者是回归护栏，后者是可对比的指标。
///
/// `needsModel` 标出**本地确定性层做不到**的用例。它不是"允许失败"的挡箭牌，
/// 而是有没有 few-shot 这两版之间的差值本身——项目总结里要对比的正是这一列。
enum TodoRecognitionCorpus {

    enum Expectation: Sendable, Equatable {
        /// 什么都不该发生。误报就在这一类里暴露。
        case none
        case create(titleContains: String)
        /// 一次输入必须得到多条独立的新建提案；用于防止“只取第一条”回归。
        case creates(titleContains: [String])
        case reschedule(todoTitle: String, hour: Int?, day: Int?)
        case complete(todoTitle: String)
        case cancel(todoTitle: String)
    }

    struct Case: Sendable {
        var id: String
        var category: String
        var text: String
        /// 现有待办的标题。截止时间统一用 `existingDueAt`，避免每条都写一遍。
        var todos: [String]
        var expectation: Expectation
        /// 本地确定性层预期覆盖不了，需要模型（few-shot）才可能答对。
        var needsModel: Bool = false
        /// 这一条想守住的东西，一句话。写进报告，便于日后回看。
        var note: String = ""
    }

    /// 2026-09-02 周三 10:00（UTC+8）。语料里所有相对时间都以它为基准。
    static let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 2; c.hour = 10
        return calendar.date(from: c)!
    }()

    static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        value.locale = Locale(identifier: "zh_CN")
        return value
    }()

    /// 现有待办统一的截止时间：9/5 23:59。
    static let existingDueAt: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 5; c.hour = 23; c.minute = 59
        return calendar.date(from: c)!
    }()

    static let meetingDueAt: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 2; c.hour = 15
        return calendar.date(from: c)!
    }()

    static func todos(_ titles: [String]) -> [Todo] {
        titles.map { title in
            Todo(
                title: title,
                dueAt: title.contains("组会") ? meetingDueAt : existingDueAt
            )
        }
    }

    // MARK: - 语料

    static let cases: [Case] = codeCases + deadlineCases + revisionCases
        + multiTaskCases + noiseCases

    /// 一、码类。取餐、取件、快递——本地字面命中，是"确凿"那一档。
    static let codeCases: [Case] = [
        .init(id: "code-01", category: "取餐码", text: "您的餐品已备好，取餐码 A12，请到 3 号窗口领取",
              todos: [], expectation: .create(titleContains: "A12"),
              note: "标准外卖取餐通知"),
        .init(id: "code-02", category: "取餐码", text: "取餐号 B7",
              todos: [], expectation: .create(titleContains: "B7"),
              note: "两位短码，下限放宽到 2 位才接得住"),
        .init(id: "code-03", category: "取件码", text: "您的包裹已到菜鸟驿站，取件码 8-3-2201，请及时取件",
              todos: [], expectation: .create(titleContains: "8-3-2201"),
              note: "带驿站名的取件通知"),
        .init(id: "code-04", category: "取件码", text: "取件码 A12，餐厅在一楼西侧",
              todos: [], expectation: .create(titleContains: "取件"),
              note: "旁边出现「餐」字，动词不能被带偏"),
        .init(id: "code-05", category: "快递", text: "快递单号：SF1234567890",
              todos: [], expectation: .none,
              note: "光有单号不是一件待办，只是可查询的信息"),
        .init(id: "code-06", category: "快递", text: "您的快递已到丰巢快递柜，单号 YT8899001234，请尽快取件",
              todos: [], expectation: .create(titleContains: "取快递"),
              note: "有「已到」才构成待办"),
        .init(id: "code-07", category: "验证码", text: "【某某】验证码 583921，5 分钟内有效，请勿转发",
              todos: [], expectation: .none,
              note: "验证码几分钟就失效，进待办纯噪音"),
        .init(id: "code-08", category: "取餐码", text: "取餐码 B72，本券有效期至 2027年3月1日",
              todos: [], expectation: .create(titleContains: "B72"),
              note: "远期的券有效期不能被当成取餐截止时间"),
    ]

    /// 二、截止与日程。标题靠从整句里做减法抠出来，是"要问一句"那一档。
    static let deadlineCases: [Case] = [
        .init(id: "due-01", category: "截止", text: "请各位同学在周五之前提交开题报告",
              todos: [], expectation: .create(titleContains: "开题报告"),
              note: "最典型的老师通知"),
        .init(id: "due-02", category: "截止", text: "【教务处】通知：请于 9月10日 前提交课程论文",
              todos: [], expectation: .create(titleContains: "课程论文"),
              note: "标题要去掉【教务处】和日期"),
        .init(id: "due-03", category: "截止", text: "报名截止到本月底，别忘了交材料",
              todos: [], expectation: .create(titleContains: "报名"),
              note: "「月底」要能解析"),
        .init(id: "due-04", category: "日程", text: "明天下午两点在 305 开组会",
              todos: [], expectation: .create(titleContains: "组会"),
              note: "中文数字钟点"),
        .init(id: "due-05", category: "日程", text: "下周三下午三点答辩，记得带纸质版",
              todos: [], expectation: .create(titleContains: "答辩"),
              note: "「下周三」按自然周算"),
        .init(id: "due-06", category: "日程", text: "9月5日上午9:00 面试，地点待定",
              todos: [], expectation: .create(titleContains: "面试"),
              note: "绝对日期加冒号钟点"),
        .init(id: "due-07", category: "截止", text: "报名已于 1月5日 截止，请等待下一轮",
              todos: [], expectation: .none,
              note: "过去时陈述不能被顺延成明年的待办"),
        .init(id: "due-08", category: "截止", text: "该活动已结束，原定 12月1日 提交",
              todos: [], expectation: .none,
              note: "同上，另一种过去时措辞"),
        .init(id: "due-09", category: "截止", text: "请在 3-5 天内提交材料",
              todos: [], expectation: .create(titleContains: "材料"),
              note: "区间不能被读成 3 月 5 日"),
        .init(id: "due-10", category: "日程", text: "组会时间定在这周五下午四点半",
              todos: [], expectation: .create(titleContains: "组会"),
              note: "「四点半」的分钟部分"),
        .init(id: "due-11", category: "截止", text: "麻烦周一之前把周报发我",
              todos: [], expectation: .create(titleContains: "周报"),
              needsModel: true,
              note: "「发我」不是截止线索词，本地词表接不住"),
        .init(id: "due-12", category: "日程", text: "礼拜四上午带上身份证去体检",
              todos: [], expectation: .create(titleContains: "体检"),
              note: "「礼拜」写法"),
        .init(id: "due-13", category: "模型泛化", text: "明天晚上八点我要赶回合肥",
              todos: [], expectation: .create(titleContains: "赶回合肥"),
              needsModel: true,
              note: "未来时间 + 个人出行，不依赖出行词表"),
        .init(id: "due-14", category: "模型泛化", text: "你还差多少？明天应该就搞好了，改两个图",
              todos: [], expectation: .create(titleContains: "改两个图"),
              needsModel: true,
              note: "聊天上下文里的隐含截止任务"),
        .init(id: "due-15", category: "餐饮取餐", text: "配餐中… 订单号 35341 麦当劳承德奥体中心餐厅",
              todos: [], expectation: .create(titleContains: "35341"),
              needsModel: true,
              note: "没有取餐码字样，模型结合订单状态识别待取餐"),
    ]

    /// 三、改期、取消、完成。要和现有待办对上号，是这次新增的核心能力。
    static let revisionCases: [Case] = [
        .init(id: "rev-01", category: "改期", text: "组会改到四点",
              todos: ["组会"], expectation: .reschedule(todoTitle: "组会", hour: 16, day: 2),
              note: "裸「四点」在中文里指下午"),
        .init(id: "rev-02", category: "改期", text: "组会改到四点",
              todos: ["在305开组会"], expectation: .reschedule(todoTitle: "在305开组会", hour: 16, day: 2),
              note: "标题只有一部分命中，仍要认出是同一件事"),
        .init(id: "rev-03", category: "改期", text: "开题报告延期到下周一",
              todos: ["提交开题报告"], expectation: .reschedule(todoTitle: "提交开题报告", hour: 23, day: 7),
              note: "没写钟点按当天结束算"),
        .init(id: "rev-04", category: "改期", text: "面试提前到明天上午十点",
              todos: ["面试"], expectation: .reschedule(todoTitle: "面试", hour: 10, day: 3),
              note: "提前也是改期"),
        .init(id: "rev-05", category: "改期", text: "组会改期吧",
              todos: ["组会"], expectation: .none,
              note: "说了改期却没给新时间，等于什么都没说"),
        .init(id: "rev-06", category: "改期", text: "组会改到下午三点",
              todos: ["组会"], expectation: .none,
              note: "改成和现在一样的时间不算改期"),
        .init(id: "rev-07", category: "取消", text: "这周组会取消",
              todos: ["组会"], expectation: .cancel(todoTitle: "组会"),
              note: "取消一律要用户点头"),
        .init(id: "rev-08", category: "取消", text: "组会取消了，改到下周再说",
              todos: ["组会"], expectation: .cancel(todoTitle: "组会"),
              note: "取消比改期强"),
        .init(id: "rev-09", category: "取消", text: "开题报告不用交了",
              todos: ["提交开题报告"], expectation: .cancel(todoTitle: "提交开题报告"),
              note: "口语化的取消"),
        .init(id: "rev-10", category: "完成", text: "开题报告我已经交上去了",
              todos: ["提交开题报告"], expectation: .complete(todoTitle: "提交开题报告"),
              note: "本人陈述才算完成"),
        .init(id: "rev-11", category: "干扰", text: "听说隔壁组的开题报告交了",
              todos: ["提交开题报告"], expectation: .none,
              note: "说的是别人，一个字都不能改"),
        .init(id: "rev-12", category: "干扰", text: "他们的组会取消了",
              todos: ["组会"], expectation: .none,
              note: "第三方主语"),
        .init(id: "rev-13", category: "去重", text: "请在 9月5日 之前提交开题报告",
              todos: ["提交开题报告"], expectation: .none,
              note: "同一件事同一个时间，不重复建"),
        .init(id: "rev-14", category: "改期", text: "请在 9月4日 之前提交开题报告",
              todos: ["提交开题报告"], expectation: .reschedule(todoTitle: "提交开题报告", hour: 23, day: 4),
              note: "没明说改期，但时间对不上——提出来让用户确认"),
        .init(id: "rev-15", category: "改期",
              text: """
              小王：今天中午吃什么
              小李：随便吧
              导师：各位，组会改到四点，教室不变
              小王：收到
              """,
              todos: ["组会"], expectation: .reschedule(todoTitle: "组会", hour: 16, day: 2),
              note: "整段聊天记录里认出改期"),
        .init(id: "rev-16", category: "歧义", text: "组会改到四点",
              todos: ["组会", "组会"], expectation: .none,
              note: "两条一样像就是有歧义，不许挑一个"),
        .init(id: "rev-17", category: "改期", text: "那个报告的事往后挪挪，下周三吧",
              todos: ["提交开题报告"], expectation: .reschedule(todoTitle: "提交开题报告", hour: 23, day: 9),
              needsModel: true,
              note: "「那个报告的事」是指代，本地对不上号"),
        .init(id: "rev-18", category: "完成", text: "报告搞定了",
              todos: ["提交开题报告"], expectation: .complete(todoTitle: "提交开题报告"),
              needsModel: true,
              note: "「报告」两个字在标题里是通用词，本地判 0"),
    ]

    /// 四、多任务。一段输入里的事项必须能分别完成、改期或删除，不能总结成一条。
    static let multiTaskCases: [Case] = [
        .init(
            id: "multi-01",
            category: "多任务拆解",
            text: "今天要看完项目并写完论文儿",
            todos: [],
            expectation: .creates(titleContains: ["看完项目", "写完论文"]),
            needsModel: true,
            note: "微信真实回归：同一个今天修饰两件可独立管理的任务"
        ),
        .init(
            id: "multi-02",
            category: "多任务拆解",
            text: "周四提交项目报告\n周五下午三点参加课程答辩",
            todos: [],
            expectation: .creates(titleContains: ["项目报告", "课程答辩"]),
            note: "模型不可用时，本地多行提取也不能只保留 drafts.first"
        ),
        .init(
            id: "multi-03",
            category: "多任务去重",
            text: "周五提交课程论文\n周五提交课程论文",
            todos: [],
            expectation: .create(titleContains: "课程论文"),
            note: "同一事项重复出现只生成一条"
        ),
    ]

    /// 五、噪音。误报全在这一类里暴露——它比漏报更伤，因为用户没有触发任何东西。
    static let noiseCases: [Case] = [
        .init(id: "noise-01", category: "干扰", text: "今天食堂人好多", todos: ["组会"], expectation: .none),
        .init(id: "noise-02", category: "干扰", text: "let value = items.map(\\.id).sorted()",
              todos: [], expectation: .none, note: "代码截图最常见的内容"),
        .init(id: "noise-03", category: "干扰", text: "https://developer.apple.com/design/human-interface-guidelines/",
              todos: [], expectation: .none),
        .init(id: "noise-04", category: "干扰", text: "这款产品 2026年3月 在国内正式发售，销量不错",
              todos: [], expectation: .none, note: "有日期没线索词"),
        .init(id: "noise-05", category: "干扰", text: "会议室在三楼东侧，走廊尽头",
              todos: ["组会"], expectation: .none, note: "有场景词没时间"),
        .init(id: "noise-06", category: "干扰", text: "取", todos: [], expectation: .none, note: "超短输入"),
        .init(id: "noise-07", category: "干扰", text: "   \n\n  ", todos: [], expectation: .none, note: "纯空白"),
        .init(id: "noise-08", category: "干扰", text: "记得提交材料", todos: ["提交开题报告"],
              expectation: .none, note: "只共用「提交」这个通用词，不算同一件事"),
    ]
}
