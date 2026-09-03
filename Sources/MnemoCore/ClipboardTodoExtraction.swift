import Foundation

/// 剪贴板文字里那种"一串码"。
///
/// 这三类的共同点是：**内容本身就是全部价值**，标题、正文、摘要都不重要，
/// 用户要的就是把那几个字符原样念出来或粘出去。所以它们既决定卡片怎么画，
/// 也决定要不要提一条待办。
public enum ClipboardSignal: Sendable, Equatable, Codable {
    case pickupCode(String)
    case verificationCode(String)
    case trackingNumber(String)

    public var code: String {
        switch self {
        case .pickupCode(let value), .verificationCode(let value), .trackingNumber(let value):
            value
        }
    }

    public var label: String {
        switch self {
        case .pickupCode: "取餐/取件码"
        case .verificationCode: "验证码"
        case .trackingNumber: "快递单号"
        }
    }

    /// 从一段文字里认出第一个码。纯正则，不调用模型。
    public static func detect(_ text: String) -> ClipboardSignal? {
        let patterns: [(String, (String) -> ClipboardSignal)] = [
            // 真实的取餐码常常只有两三位（"A7""12"），下限卡在 3 会漏掉一大半。
            // 放宽到 2 是安全的：线索词和码之间只允许一个可选的"码"和一个可选
            // 的冒号，中间夹别的字就不匹配了，不存在"取件后 3"这种误命中。
            // 线索词后面跟的可能是"码"也可能是"号"（取餐号、取件号），都要认。
            (#"(?:取餐|取件|取货|提货|取单|取号)\s*[码号]?\s*[:：#]?\s*([A-Za-z0-9]{2,8})"#, { .pickupCode($0) }),
            (#"(?:验证码|校验码|动态码|动态口令)\s*[:：#]?\s*(\d{4,6})"#, { .verificationCode($0) }),
            (#"(?:快递|物流|运单|单号|tracking)\s*(?:号|编号|number|no\.?)?\s*[:：#]\s*([A-Za-z0-9]{8,20})"#, { .trackingNumber($0) }),
        ]
        for (pattern, make) in patterns {
            guard let match = ChineseDateParser.firstMatch(pattern, in: text),
                  let code = match.group(1) else { continue }
            return make(code)
        }
        return nil
    }
}

/// 一条"从剪贴板里看出来的待办"。
///
/// 它**不是**待办本身，只是一个候选：提取全部靠本地正则，宁可漏也不能乱建，
/// 所以默认走"提示 + 用户点一下"，由用户决定它要不要变成 `Todo`。
public struct TodoDraft: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable, Codable {
        /// 取餐 / 取号：当天的事，码就是全部内容。
        case pickupCode
        /// 快递待取：有取件码或明确说了"已到/待取"。
        case delivery
        /// 有截止时间的事：交作业、提交材料、报名、缴费。
        case deadline
        /// 有开始时间的事：开会、上课、面试、体检。
        case appointment

        /// 数字越小越先提。码类是字面命中，最确定；日期类要靠抽主题，稍弱。
        var priority: Int {
            switch self {
            case .pickupCode: 0
            case .delivery: 1
            case .appointment: 2
            case .deadline: 3
            }
        }

        /// 这条候选的把握够不够大到"不必问，直接建"。
        ///
        /// 判据是**结论建立在什么之上**，不是某个自报的分数：
        ///
        /// - 码类的标题是模板拼的（"取餐 A12"），码本身是正则字面命中，
        ///   要么对要么没匹配上，不存在"抠错了主题"这种中间状态；
        /// - 日程类的标题靠从整句里做减法抠出来，同一句话换个写法就可能
        ///   多带半句废话或少掉关键词。这种时候必须让用户看一眼再点头。
        ///
        /// 这条界线和 `ContextualAutoCopy` 是同一套原则：只有本地事实唯一
        /// 确定结果时才替用户动手。
        public var isCertain: Bool {
            self == .pickupCode || self == .delivery
        }
    }

    /// 去重键。同一件事被复制两遍、或者截图和文字各来一次，都只提一次。
    public var id: String
    public var title: String
    public var dueAt: Date?
    public var source: Source
    /// 一句话说明"凭什么提这条"。UI 上写在标题下面，用户一眼能判断对不对。
    public var reason: String
    public var code: String?

    /// 见 `Source.isCertain`。确凿的候选直接建，只留一个撤销入口；
    /// 拿不准的才弹一个对号和一个叉。
    public var isCertain: Bool { source.isCertain }

    public init(
        id: String,
        title: String,
        dueAt: Date?,
        source: Source,
        reason: String,
        code: String? = nil
    ) {
        self.id = id
        self.title = title
        self.dueAt = dueAt
        self.source = source
        self.reason = reason
        self.code = code
    }
}

/// 从剪贴板文字（含截图 OCR 结果）里提取待办候选。
///
/// 设计上只做**确定性**判断，不问模型。原因和 `ContextualAutoCopy` 一样：
/// 提取的结果会变成用户日程里的一条东西，错一条的代价远大于漏一条。
/// 模型可以在此之后帮忙润色标题，但"有没有这件事"必须由本地证据决定。
public enum ClipboardTodoExtractor {
    /// 超过这个长度多半是整篇文章被复制，不是一条通知。截断后再扫。
    public static let maximumScannedLength = 4_000

    public static func draft(
        from text: String,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> TodoDraft? {
        drafts(from: text, now: now, calendar: calendar).first
    }

    /// 最多返回与模型协议相同的 5 条，按可信度排序。
    /// 一次都不匹配就直接走人的关键词表。
    ///
    /// 真实剪贴板里绝大多数内容和待办无关：代码、网址、一段正文、一个人名。
    /// 让它们全跑一遍正则电池是纯浪费。先做一次朴素的子串扫描——命中不了
    /// 任何一个词，后面那些规则也一定命中不了。
    private static let triggerWords: [String] = [
        "取餐", "取件", "取货", "提货", "取单", "取号", "快递", "物流", "运单", "单号",
        "驿站", "菜鸟", "已到", "待取", "请取", "自提", "代收",
    ] + deadlineCues + appointmentCues

    public static func drafts(
        from text: String,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [TodoDraft] {
        let body = String(text.prefix(maximumScannedLength))
        guard body.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 else { return [] }
        let lowered = body.lowercased()
        guard triggerWords.contains(where: { lowered.contains($0.lowercased()) }) else { return [] }

        var found: [TodoDraft] = []
        var seen: Set<String> = []

        func add(_ draft: TodoDraft?) {
            guard let draft, seen.insert(draft.id).inserted else { return }
            // 同一段通知里的结构化码是最强本地事实。如果日程减法又从同一句
            // “取餐码 B72，本券有效期至……”抠出一条截止事项，它不是第二件事，
            // 只是同一通知被两套规则重复解释。码相同或标题原样包含已验证码时去重。
            if let code = draft.code {
                guard !found.contains(where: {
                    $0.code?.caseInsensitiveCompare(code) == .orderedSame
                }) else { return }
            } else if found.contains(where: { existing in
                guard let code = existing.code else { return false }
                return draft.title.localizedCaseInsensitiveContains(code)
            }) {
                return
            }
            found.append(draft)
        }

        add(pickupDraft(in: body, now: now, calendar: calendar))
        add(deliveryDraft(in: body, now: now, calendar: calendar))
        let lines = meaningfulLines(of: body)
        let listLines = scheduleListLines(in: lines, whole: body)
        for (index, line) in lines.enumerated() {
            add(scheduleDraft(
                in: line,
                now: now,
                calendar: calendar,
                acceptsUncuedDate: listLines.contains(index)
            ))
        }

        return Array(
            found.sorted { lhs, rhs in
                if lhs.source.priority != rhs.source.priority {
                    return lhs.source.priority < rhs.source.priority
                }
                return (lhs.dueAt ?? .distantFuture) < (rhs.dueAt ?? .distantFuture)
            }.prefix(TodoRevisionPrompt.maximumDecisionCount)
        )
    }

    // MARK: - 码类

    private static func pickupDraft(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> TodoDraft? {
        guard case .pickupCode(let code)? = ClipboardSignal.detect(text) else { return nil }
        // 验证码绝不进待办：它几分钟就失效，留一条"去输验证码"只是噪音。
        // `detect` 已经把它归成另一个 case，这里只是把边界写明。
        let due = sameDayDue(in: text, now: now, calendar: calendar)
        // 用哪个动词由**命中的那个线索词**决定，不能拿整段文字去 contains("餐")：
        // "取件码 A12，餐厅在一楼"会因为后半句里的"餐"被说成取餐。
        let verb = ChineseDateParser
            .firstMatch(#"(取餐|取件|取货|提货|取单|取号)"#, in: text)?
            .group(1) == "取餐" ? "取餐" : "取件"
        return TodoDraft(
            id: "pickup:\(code.lowercased())",
            title: "\(verb) \(code)",
            dueAt: due,
            source: .pickupCode,
            reason: "识别到取件码 \(code)",
            code: code
        )
    }

    /// 快递。
    ///
    /// 光有一串单号不是待办——那只是一条可查询的信息。只有同时出现"取件码"
    /// 或"已到/待取/驿站/快递柜"这类明确说了**东西在等你**的措辞时才算一件事。
    private static func deliveryDraft(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> TodoDraft? {
        let arrivalCues = ["已到", "待取", "请取", "驿站", "快递柜", "菜鸟", "代收点", "自提"]
        guard arrivalCues.contains(where: { text.contains($0) }) else { return nil }

        let code = ChineseDateParser
            .firstMatch(#"(?:取件码|取货码|提货码)\s*[:：#]?\s*([A-Za-z0-9\-]{3,12})"#, in: text)?
            .group(1)
        let tracking = ChineseDateParser
            .firstMatch(#"(?:快递|物流|运单|单号)\s*(?:号|编号)?\s*[:：#]?\s*([A-Za-z0-9]{8,20})"#, in: text)?
            .group(1)
        guard code != nil || tracking != nil else { return nil }

        let identifier = code ?? tracking!
        let station = ChineseDateParser
            .firstMatch(#"([^\s，,。;；]{2,12}(?:驿站|快递柜|菜鸟|代收点|服务站))"#, in: text)?
            .group(1)
        let title = station.map { "去\($0)取快递 \(identifier)" } ?? "取快递 \(identifier)"
        return TodoDraft(
            id: "delivery:\(identifier.lowercased())",
            title: String(title.prefix(28)),
            dueAt: sameDayDue(in: text, now: now, calendar: calendar),
            source: .delivery,
            reason: code == nil ? "快递单号 \(identifier)" : "取件码 \(identifier)",
            code: identifier
        )
    }

    // MARK: - 日程类

    private static let deadlineCues = [
        "截止", "deadline", "ddl", "提交", "上交", "交作业", "报名", "缴费", "交费",
        "签到", "填报", "申报", "投稿", "提交材料", "之前完成", "前完成", "务必",
        "最后一天", "有效期至", "到期",
    ]

    private static let appointmentCues = [
        "会议", "开会", "组会", "例会", "周会", "晨会", "班会", "站会",
        "面试", "答辩", "评审", "上课", "课程", "讲座", "培训", "宣讲",
        "体检", "门诊", "复诊", "预约", "报到", "考试", "复试",
        "见面", "碰头", "面谈", "约谈", "路演", "彩排",
    ]

    /// 一行文字里"要做的事 + 时间"。
    ///
    /// 两个条件缺一不可：既要有像日程的线索词，也要能解出一个具体时间。
    /// 只有时间没有线索词的行到处都是（"2026年1月发布"），只有线索词没时间
    /// 的行则给不出提醒——两种都不该变成待办。
    private static func scheduleDraft(
        in line: String,
        now: Date,
        calendar: Calendar,
        acceptsUncuedDate: Bool = false
    ) -> TodoDraft? {
        let source: TodoDraft.Source
        if deadlineCues.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
            source = .deadline
        } else if appointmentCues.contains(where: { line.contains($0) }) {
            source = .appointment
        } else if acceptsUncuedDate {
            // 这一行本身没有线索词，但它是一张**日程清单**里以日期开头的一条。
            // 线索词表永远追不上活动名（"入学教育""开学典礼""交流活动"都不在
            // 表里，而它们恰恰是通知里最常见的事）。清单这个形状本身就是证据：
            // 判定条件见 `scheduleListLines`。
            source = .appointment
        } else {
            return nil
        }

        // 过去时的陈述句不产生待办，哪怕日期解析把它顺延到了明年。
        guard !pastTenseCues.contains(where: { line.contains($0) }) else { return nil }

        guard let reference = ChineseDateParser.firstDate(in: line, now: now, calendar: calendar) else {
            return nil
        }
        // 只写了年份定位不到某一天，那是正文里的一个年号，不是日程。
        //
        // "〈2026级研究生招生群（100）…就不能填报了"就是这么变成待办的：句子里
        // 有"填报"这个截止线索词，年份又被补齐成了一个具体时刻，两个条件
        // 凑巧都成立。日期解析给不出"哪一天"的时候，这条就不成立。
        guard pinsDownADay(reference) else { return nil }
        // 已经过去很久的日期是正文里的历史陈述，不是待办。留一天的宽限，
        // 让"今天 23:59 截止"在当天晚些时候仍然成立。
        guard reference.date > now.addingTimeInterval(-86_400) else { return nil }

        // 没写钟点时，两类事各有各的自然落点：
        // - 截止类按当天结束算，"周五交"指的是周五结束前，不是周五零点；
        // - 日程类按当天早上算。"9月7日开学典礼"提醒在零点响没有任何用——
        //   那时候人在睡觉，而这一天真正要做的事在白天。
        let due: Date
        if reference.hasExplicitTime {
            due = reference.date
        } else if source == .deadline {
            due = ChineseDateParser.endOfDay(reference.date, calendar: calendar)
        } else {
            // 钟点没被日期解析吃进去，但"上午""下午"这类时段词常常就写在
            // 日期旁边（"9月7日（周一）上午 开学典礼"）。它是原文给的证据，
            // 不是猜的——读它，比一律按早上或一律按午夜都准。
            due = calendar.date(
                bySettingHour: dayPeriodHour(in: line) ?? allDayAppointmentHour,
                minute: 0, second: 0,
                of: reference.date
            ) ?? reference.date
        }

        // 清单条目的括注多半是"（周三）""（8:50 前就座）"这类补充说明，
        // 留着会把标题挤成一串括号。日期已经从原行解析过了，去掉不影响时间。
        let titleSource = acceptsUncuedDate ? strippingParentheticals(line) : line
        let title = subject(of: titleSource, removing: reference.matchedText, fallback: source)
        guard !title.isEmpty else { return nil }

        let day = Int(due.timeIntervalSince1970 / 3_600)
        return TodoDraft(
            id: "schedule:\(title.lowercased()):\(day)",
            title: title,
            dueAt: due,
            source: source,
            reason: "识别到时间「\(reference.matchedText.trimmingCharacters(in: .whitespaces))」"
        )
    }

    /// 这个解析结果有没有落到具体某一天。
    ///
    /// 写了钟点就算（"14:20"指的是今天）；否则必须出现月/日/号，或者
    /// 是"明天""周三"这类相对日。光有"2026年"不算。
    private static func pinsDownADay(_ reference: ParsedDateReference) -> Bool {
        if reference.hasExplicitTime { return true }
        let text = reference.matchedText
        guard text.contains("年") else { return true }
        return text.contains("月") || text.contains("日") || text.contains("号")
    }

    /// 全天日程的提醒钟点。早上九点：既在人醒着的时段，又早于绝大多数
    /// 需要出门的安排。
    private static let allDayAppointmentHour = 9

    /// 时段词到钟点。原文没写具体几点，但写了"上午"的时候用这张表。
    ///
    /// 只认原文真的出现过的词，查不到就返回 nil 交给默认值——这里宁可给一个
    /// 保守的早上，也不替用户编一个"看起来合理"的开始时间。
    private static let dayPeriods: [(word: String, hour: Int)] = [
        ("凌晨", 6), ("清晨", 7), ("早晨", 8), ("早上", 8), ("上午", 9),
        ("中午", 12), ("下午", 14), ("傍晚", 18), ("晚上", 19), ("夜里", 21),
    ]

    private static func dayPeriodHour(in line: String) -> Int? {
        dayPeriods.compactMap { period -> (Int, Int)? in
            guard let range = line.range(of: period.word) else { return nil }
            return (line.distance(from: line.startIndex, to: range.lowerBound), period.hour)
        }
        // 一行里出现多个时段词时按出场顺序取第一个：它修饰的是这一行的主事件，
        // 后面那个多半在括注里补充别的环节（"下午14:20在礼堂就座"）。
        .min { $0.0 < $1.0 }?.1
    }

    /// 从一行里抠出"要做的事"。
    ///
    /// 做法是减法而不是加法：把时间表达、常见的连接词和标点去掉，剩下的就是
    /// 主题。加法（去猜哪几个字是主题）在中文里几乎必错，减法最差也只是留下
    /// 一句稍长的原话——那仍然是可读的待办标题。
    private static func subject(
        of line: String,
        removing matched: String,
        fallback: TodoDraft.Source
    ) -> String {
        var value = line
        for token in matched.components(separatedBy: " ") where !token.isEmpty {
            value = value.replacingOccurrences(of: token, with: " ")
        }
        // "上午""下午"这类时段词跟在日期后面，日期被解析走之后它们会留在
        // 标题最前面。它们说的是时间，不是事情。
        value = value.replacingOccurrences(
            of: #"^\s*(上午|下午|中午|早上|晚上|傍晚|凌晨|全天)\s*"#,
            with: "",
            options: .regularExpression
        )
        // "9月5日—6日"这种日期区间只被解析走了前半截，剩下的"—6日"会挂在
        // 标题最前面。它是时间的残渣，不是事情。
        value = value.replacingOccurrences(
            of: #"^\s*[\-–—~至到]\s*\d{1,2}\s*[日号]"#,
            with: "",
            options: .regularExpression
        )
        // 提示性前缀通常是通知模板的套话，留着会让每条待办都长一个样。
        for prefix in ["【", "】", "通知：", "提醒：", "温馨提示：", "各位同学：", "各位老师：", "@所有人"] {
            value = value.replacingOccurrences(of: prefix, with: " ")
        }
        value = value.replacingOccurrences(
            of: #"^[\s，,。.、;；:：\-—…]+|[\s，,。.、;；:：\-—…]+$"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard value.count >= 2 else {
            return fallback == .deadline ? "截止事项" : "日程安排"
        }
        // 待办列表一行只放得下二十来个字，长句在那里会被截成同一个前缀，
        // 几条并排时根本分不出谁是谁。这里先截，用户改得动。
        guard value.count > 24 else { return value }
        return String(value.prefix(24)) + "…"
    }

    /// 码类待办的到期时间。
    ///
    /// 取餐码、取件码都是当天的事。文本里恰好出现的日期（外卖单上的下单日期、
    /// 优惠券的有效期）不该被拿来当截止时间，所以只接受**七天以内**的解析
    /// 结果，其余一律按今天结束算。
    private static func sameDayDue(in text: String, now: Date, calendar: Calendar) -> Date {
        let fallback = ChineseDateParser.endOfDay(now, calendar: calendar)
        guard let parsed = ChineseDateParser.firstDate(in: text, now: now, calendar: calendar)?.date,
              parsed > now.addingTimeInterval(-3_600),
              parsed < now.addingTimeInterval(7 * 86_400) else { return fallback }
        return parsed
    }

    /// 这句话说的是"已经过去的事"吗。
    ///
    /// "报名已于 1月5日 截止"和"报名 1月5日 截止"只差一个"已"字，日期解析
    /// 却给出同一个结果——而且只写月日时还会被顺延到明年，于是一条早就结束
    /// 的通知会变成一条未来的待办。
    private static let pastTenseCues = [
        "已于", "已经", "已结束", "已截止", "已过期", "已完成", "已停止",
        "已关闭", "已取消", "过期", "截止时间已", "报名结束",
    ]

    // MARK: - 日程清单

    /// 「通知里列了好几条日程」这个形状。
    ///
    /// 线索词表（会议/答辩/体检…）覆盖不了活动名本身："全天入学教育"
    /// "开学典礼""交流活动""新生见面会"一个都不在表里，而这正是通知里最
    /// 常见的一类事。补词是填不完的坑。
    ///
    /// 换一个角度：**清单这个形状本身就是证据**。连着好几行都以日期开头、
    /// 日期后面还跟着一件事，这不可能是正文里偶然出现的年份。所以这里不看
    /// 每行写了什么，只看整块文字排成了什么样。
    ///
    /// 门槛按条数分两档，宁可漏也不误报：
    /// - 三条及以上以日期开头 → 本身足够像清单；
    /// - 恰好两条 → 还要求整段里有"通知/安排/日程"这类框架词。
    ///
    /// 返回的是命中的行号，让调用方只对这些行放开线索词要求；其余行仍按
    /// 原规则走，不会因为同一段文字里有清单就整段放行。
    private static func scheduleListLines(in lines: [String], whole text: String) -> Set<Int> {
        let dateLed = lines.indices.filter { startsWithDate(lines[$0]) }
        guard dateLed.count >= 2 else { return [] }
        if dateLed.count == 2 {
            guard scheduleListFrames.contains(where: { text.contains($0) }) else { return [] }
        }
        return Set(dateLed)
    }

    /// 通知类文本的框架词。只在"恰好两条日期行"时用来加一道保险。
    private static let scheduleListFrames = [
        "日程", "安排", "通知", "如下", "议程", "流程", "课表", "排班", "值班",
        "请大家", "请各位", "请同学", "务必", "时间表",
    ]

    /// 这一行是不是"以日期开头"。
    ///
    /// 只认日期，不认单独的钟点：截图里"14:20在明理礼堂就坐完毕"是上一行
    /// 折下来的半句，不是新的一条。把它当成新条目，整段就会被切碎。
    private static let dateHeadPattern =
        #"^[\s\-–—•·▪◦*]*"#
        + #"((\d{4}\s*[年./-]\s*)?\d{1,2}\s*[月./-]\s*\d{1,2}\s*[日号]?"#
        + #"|今[天日]|明[天日]|后天|大后天"#
        + #"|[下本这上]{0,1}周[一二三四五六日天]|星期[一二三四五六日天]|礼拜[一二三四五六日天])"#

    /// 预编译。这两条正则要对**每一行**各跑一遍，而
    /// `range(of:options:.regularExpression)` 每次调用都会重新编译一次模式——
    /// 一段几十行的 OCR 就是几十次编译，单条识别的耗时预算就是这么被吃掉的。
    private static let dateHeadRegex = try? NSRegularExpression(pattern: dateHeadPattern)

    /// 能当日期开头的首字符。正则要跑几十遍，先用一次字符比较把绝大多数
    /// 行挡在外面——正文行几乎都不是数字或"今明后周"开头。
    private static let dateHeadInitials = Set("0123456789今明后大下本这上周星礼-–—•·▪◦* \t")

    private static func startsWithDate(_ line: String) -> Bool {
        guard let first = line.first, dateHeadInitials.contains(first) else { return false }
        return matches(dateHeadRegex, line)
    }

    private static func matches(_ regex: NSRegularExpression?, _ line: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
        ) != nil
    }

    /// 去掉成对括注；没有右括号的按"括到行尾"处理。
    ///
    /// OCR 常常在括注中间断行，末尾那个左括号永远等不到闭合——不特判的话
    /// 半句补充说明会被当成标题的一部分。
    private static func strippingParentheticals(_ line: String) -> String {
        var value = line
        for pattern in [#"（[^（）]*）"#, #"\([^()]*\)"#, #"【[^【】]*】"#] {
            value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        value = value.replacingOccurrences(
            of: #"[（(][^（()）]*$"#,
            with: "",
            options: .regularExpression
        )
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// 按行扫描，但长行会继续按句号断开。
    ///
    /// 截图 OCR 常常把整屏文字合成很少的几行，其中一行可能几百个字符。
    /// 只按换行切、再用长度上限一卡，那种整块文本会被**整行丢弃**，
    /// 于是"截图里的通知永远提取不出待办"。
    private static func meaningfulLines(of text: String) -> [String] {
        var result: [String] = []
        let separators = CharacterSet(charactersIn: "。！？；\n\r")
        for raw in unwrapping(text.components(separatedBy: .newlines)) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count >= 4 else { continue }
            if line.count <= 200 {
                result.append(line)
                continue
            }
            for piece in line.components(separatedBy: separators) {
                let sentence = piece.trimmingCharacters(in: .whitespaces)
                guard sentence.count >= 4, sentence.count <= 200 else { continue }
                result.append(sentence)
            }
        }
        // 一段文字里值得看的句子不会有几百条。截断既是性能闸门，也避免
        // 一次弹出一堆候选。
        return Array(result.prefix(80))
    }

    /// 把**视觉换行**接回去。
    ///
    /// 截图 OCR 是按屏幕上看到的样子断行的，一条日程常常被劈成两三行：
    ///
    ///     9月9日（周三）下午14:00  学院
    ///     新生见面会（13:45在明理礼堂就坐
    ///     完毕。
    ///
    /// 日期在第一行、事情在第二行，于是"既要有线索词又要有时间"这条规则
    /// 在任何一行上都不成立——通知里明明写了四件事，一件都提不出来。
    ///
    /// 判据是**这一行有没有顶到那块文字的宽度**：被宽度切断的行才是半句，
    /// 短行是自己说完了的。宽度取本段行长的八分位数，所以窄如聊天气泡、
    /// 宽如整屏文档都自适应，不写死字数。
    ///
    /// 两道闸门防止把相邻的两件事黏成一件：句末标点收尾的行不续，
    /// 下一行以日期开头（= 新的一条）的也不续。
    private static func unwrapping(_ raw: [String]) -> [String] {
        let lines = raw.map { $0.trimmingCharacters(in: .whitespaces) }
        let widths = lines.map(\.count).filter { $0 > 0 }.sorted()
        guard widths.count >= 3 else { return lines }
        let reference = widths[min(widths.count - 1, Int(Double(widths.count) * 0.8))]
        // 顶到八成宽就算被切断。再低会把"自己说完了的短行"也粘上去。
        let continuationWidth = max(12, Int(Double(reference) * 0.75))

        var result: [String] = []
        for line in lines {
            guard !line.isEmpty, !isChrome(line) else {
                // 空行是作者自己打的段落分隔；单独成行的钟点是聊天界面的
                // 时间戳（"10:56"），同样不是正文的一部分。跨过去的话，
                // 上一条消息的末句会和时间戳粘成一句，还平白多出一个"时间"。
                result.append("")
                continue
            }
            if let last = result.last, last.count >= continuationWidth,
               !endsSentence(last), !startsWithDate(line),
               last.count + line.count <= 200 {
                result[result.count - 1] = last + line
            } else {
                result.append(line)
            }
        }
        return result
    }

    /// 整行只是一个钟点或一串数字：聊天时间戳、页码、楼层号这类界面碎片。
    private static let chromeRegex = try? NSRegularExpression(
        pattern: #"^[\s\p{P}]*\d{1,2}\s*[:：]\s*\d{2}(\s*[apAP]\.?[mM]\.?)?[\s\p{P}]*$"#
    )

    private static func isChrome(_ line: String) -> Bool { matches(chromeRegex, line) }

    /// 这一行是不是自己收尾了。冒号也算：它是"下面开始列"的标题行。
    ///
    /// 收尾标点后面还可以跟右括号、引号：「…就坐完毕。）」是一句话结束，
    /// 只看最后一个字符会把它判成半句，于是下一段正文被粘进这条日程的标题。
    private static func endsSentence(_ line: String) -> Bool {
        let trimmed = line.reversed().drop { "）)】」』”\"'>》".contains($0) }
        guard let last = trimmed.first else { return true }
        return "。！？；：!?;:".contains(last)
    }
}
