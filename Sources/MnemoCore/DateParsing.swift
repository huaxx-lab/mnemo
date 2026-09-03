import Foundation

/// 从一段自然语言里解出的时间点。
///
/// `hasExplicitTime` 决定调用方怎么补齐：写了"下午三点"就按三点，
/// 只写了"周五"则由调用方决定当天几点算截止——待办用当天 23:59，
/// 会议提醒用当天上午，两者不该在解析器里混成一个默认值。
public struct ParsedDateReference: Sendable, Equatable {
    public var date: Date
    public var hasExplicitTime: Bool
    /// 命中的原文片段。用来从标题里把时间词摘掉，剩下的才是"要做的事"。
    public var matchedText: String

    public init(date: Date, hasExplicitTime: Bool, matchedText: String) {
        self.date = date
        self.hasExplicitTime = hasExplicitTime
        self.matchedText = matchedText
    }
}

/// 中文（兼顾英文数字格式）时间表达解析。纯本地、确定性，不调用模型。
///
/// 为什么不直接用 `NSDataDetector`：它认得 "12/31" 和 "2026年1月3日"，
/// 但认不出"下周三下午三点"、"大后天"、"月底前"这些国内日常最常写的说法，
/// 而这几种恰恰是截图和聊天记录里的主力。这里先跑自己的规则，
/// 全部落空时才回退到 `NSDataDetector`，两边互补。
public enum ChineseDateParser {

    /// 找出文本里**第一个**能确定到某一天的时间表达。
    ///
    /// 找不到返回 nil——宁可没有截止日期，也不要猜一个错的：待办的截止日期
    /// 一旦错了，提醒就会在错误的时间响，比没有提醒更糟。
    public static func firstDate(
        in text: String,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> ParsedDateReference? {
        var calendar = calendar
        calendar.locale = Locale(identifier: "zh_CN")

        let time = firstTime(in: text, calendar: calendar)

        // 日期部分按"信息量从大到小"依次尝试：写了年月日就不该被"周三"截胡。
        let dayResolvers: [(String, Date) -> (day: Date, matched: String)?] = [
            { absoluteFullDate(in: $0, now: $1, calendar: calendar) },
            { absoluteMonthDay(in: $0, now: $1, calendar: calendar) },
            { relativeDay(in: $0, now: $1, calendar: calendar) },
            { weekday(in: $0, now: $1, calendar: calendar) },
            { offsetDay(in: $0, now: $1, calendar: calendar) },
            { periodBoundary(in: $0, now: $1, calendar: calendar) },
        ]

        for resolve in dayResolvers {
            guard let hit = resolve(text, now) else { continue }
            let resolved = apply(time: time, to: hit.day, calendar: calendar)
            return ParsedDateReference(
                date: resolved,
                hasExplicitTime: time != nil,
                matchedText: [hit.matched, time?.matched].compactMap { $0 }.joined(separator: " ")
            )
        }

        // 只写了时间没写日期（"三点半开会"）：指的是今天那个点；
        // 已经过去了就是明天——没人会在下午三点说"三点开会"指的是三小时前。
        if let time {
            let today = calendar.startOfDay(for: now)
            var candidate = apply(time: time, to: today, calendar: calendar)
            if candidate <= now, let tomorrow = calendar.date(byAdding: .day, value: 1, to: candidate) {
                candidate = tomorrow
            }
            return ParsedDateReference(
                date: candidate,
                hasExplicitTime: true,
                matchedText: time.matched
            )
        }

        return detectorFallback(in: text, now: now)
    }

    /// 截止日期语境下补齐到当天 23:59。没写时间的"周五交"指的是周五结束前。
    public static func endOfDay(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = 23
        components.minute = 59
        components.second = 0
        return calendar.date(from: components) ?? date
    }

    // MARK: - 时间

    private struct TimeOfDay {
        var hour: Int
        var minute: Int
        var matched: String
    }

    private static func apply(time: TimeOfDay?, to day: Date, calendar: Calendar) -> Date {
        guard let time else { return day }
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        return calendar.date(from: components) ?? day
    }

    private static func firstTime(in text: String, calendar: Calendar) -> TimeOfDay? {
        // "下午 3:30" / "15:30" / "晚上八点半" / "上午9点" / "明天下午两点"。
        // 中文数字必须认：口语和聊天记录里"两点""三点半"远比"14:00"常见，
        // 只认阿拉伯数字等于这条路径在真实文本上大半时间不生效。
        let digits = #"\d{1,2}"#
        let chinese = #"[零一二三四五六七八九十两]{1,3}"#
        let pattern = #"(上午|早上|清晨|中午|下午|傍晚|晚上|夜里|凌晨)?\s*("#
            + digits + "|" + chinese
            + #")\s*(?:[:：]\s*(\d{1,2})|[点時时]\s*(半|一刻|"#
            + digits + "|" + chinese
            + #")?\s*分?)"#
        guard let match = firstMatch(pattern, in: text) else { return nil }
        let period = match.group(1)
        guard let rawHour = match.group(2).flatMap(number(from:)) else { return nil }
        var minute = 0
        if let colonMinute = match.group(3).flatMap(Int.init) {
            minute = colonMinute
        } else if let spoken = match.group(4) {
            switch spoken {
            case "半": minute = 30
            case "一刻": minute = 15
            default: minute = number(from: spoken) ?? 0
            }
        }
        guard rawHour <= 24, minute < 60 else { return nil }

        var hour = rawHour
        switch period {
        case "下午", "傍晚", "晚上", "夜里":
            if hour < 12 { hour += 12 }
        case "中午":
            if hour < 12 && hour != 12 { hour += 12 }
        case "凌晨", "早上", "上午", "清晨":
            if hour == 12 { hour = 0 }
        default:
            // 没写上午下午的一到六点，说的是下午。
            //
            // "组会改到四点""五点半来拿"——凌晨四点开会这件事在中文里基本
            // 不存在，而按字面读成 04:00 之后还会被"已经过去了"的规则顺延到
            // 第二天凌晨，错得更远。七点以后不动：早八和晚八都常见，那种
            // 歧义交给"过去了就顺延"去兜。
            if (1...6).contains(hour) { hour += 12 }
        }
        guard hour < 24 else { return nil }
        return TimeOfDay(hour: hour, minute: minute, matched: match.whole)
    }

    /// 阿拉伯数字或中文数字都读成整数。
    ///
    /// 只覆盖钟点和分钟用得到的范围（0…59），十进制结构写死成"十"前后拆分，
    /// 不做通用中文数字解析——那会把"三五个人"里的数也读出来。
    static func number(from token: String) -> Int? {
        if let value = Int(token) { return value }
        let digits: [Character: Int] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
        ]
        let characters = Array(token)
        guard !characters.isEmpty else { return nil }
        guard let tenIndex = characters.firstIndex(of: "十") else {
            guard characters.count == 1, let value = digits[characters[0]] else { return nil }
            return value
        }
        let high = tenIndex == 0 ? 1 : digits[characters[tenIndex - 1]]
        let lowIndex = tenIndex + 1
        let low = lowIndex < characters.count ? digits[characters[lowIndex]] : 0
        guard let high, let low, characters.count <= 3 else { return nil }
        return high * 10 + low
    }

    // MARK: - 日期

    private static func absoluteFullDate(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> (day: Date, matched: String)? {
        let pattern = #"(\d{4})\s*[年/\-\.]\s*(\d{1,2})\s*[月/\-\.]\s*(\d{1,2})\s*[日号]?"#
        guard let match = firstMatch(pattern, in: text),
              let year = match.group(1).flatMap(Int.init),
              let month = match.group(2).flatMap(Int.init),
              let day = match.group(3).flatMap(Int.init),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        return (calendar.startOfDay(for: date), match.whole)
    }

    private static func absoluteMonthDay(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> (day: Date, matched: String)? {
        // "12月31日" 与 "12/31"。后者必须两边都不挨着别的数字，
        // 否则 "8/16" 这种分数、版本号也会被读成日期。
        // 裸数字形式只认斜杠。`12-31` 在中文语境里几乎不用来写日期，却和
        // "3-5天内""8-10人"这类区间长得一模一样——认了它，"3-5天内提交"
        // 会被读成 3 月 5 日。宁可漏掉极少数写 `12-31` 的人。
        let patterns = [
            #"(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]"#,
            #"(?<![\d/\-:：])(\d{1,2})\s*/\s*(\d{1,2})(?![\d/\-:：])"#,
        ]
        for pattern in patterns {
            guard let match = firstMatch(pattern, in: text),
                  let month = match.group(1).flatMap(Int.init),
                  let day = match.group(2).flatMap(Int.init),
                  (1...12).contains(month), (1...31).contains(day) else { continue }
            let currentYear = calendar.component(.year, from: now)
            var components = DateComponents()
            components.year = currentYear
            components.month = month
            components.day = day
            guard var date = calendar.date(from: components) else { continue }
            // 只写月日时默认指"接下来的那一个"：今天 12 月说"1月3日"是明年。
            // 容一周的回溯窗口，"昨天到期的 12月31日"仍算今年。
            if date < calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now))!,
               let next = calendar.date(byAdding: .year, value: 1, to: date) {
                date = next
            }
            return (calendar.startOfDay(for: date), match.whole)
        }
        return nil
    }

    private static func relativeDay(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> (day: Date, matched: String)? {
        let table: [(word: String, offset: Int)] = [
            ("大后天", 3), ("后天", 2), ("明天", 1), ("明日", 1), ("明early", 1),
            ("今天", 0), ("今日", 0), ("本日", 0),
            ("昨天", -1), ("昨日", -1), ("前天", -2),
        ]
        // 长词优先：先匹配"大后天"，否则会被"后天"抢走两天的差。
        for entry in table.sorted(by: { $0.word.count > $1.word.count })
        where text.contains(entry.word) {
            guard let day = calendar.date(
                byAdding: .day,
                value: entry.offset,
                to: calendar.startOfDay(for: now)
            ) else { continue }
            return (day, entry.word)
        }
        return nil
    }

    private static func weekday(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> (day: Date, matched: String)? {
        let pattern = #"(这|本|下|下下|上)?\s*(?:周|星期|礼拜)\s*([一二三四五六日天末1-7])"#
        guard let match = firstMatch(pattern, in: text),
              let symbol = match.group(2) else { return nil }
        // 周一 = 0 … 周日 = 6。中文语感里一周从周一开始，"周末"按周六算——
        // 说"周末交"时没人指的是周日夜里。
        let offsets = ["一": 0, "二": 1, "三": 2, "四": 3, "五": 4, "六": 5, "日": 6, "天": 6,
                       "1": 0, "2": 1, "3": 2, "4": 3, "5": 4, "6": 5, "7": 6,
                       "末": 5]
        guard let target = offsets[symbol] else { return nil }

        let today = calendar.startOfDay(for: now)
        // Calendar 的一周从周日开始，直接拿 weekday 去算会让周日整体偏移一周：
        // 周日说"这周三"会指到三天后，而不是刚过去的那个周三。先换算成
        // 以周一为第 0 天的坐标，后面所有加减都在这套坐标里做。
        let mondayOffset = (calendar.component(.weekday, from: today) + 5) % 7
        guard let thisMonday = calendar.date(byAdding: .day, value: -mondayOffset, to: today) else {
            return nil
        }

        let weekShift: Int
        switch match.group(1) {
        case "下": weekShift = 1
        case "下下": weekShift = 2
        case "上": weekShift = -1
        default: weekShift = 0
        }
        guard var day = calendar.date(
            byAdding: .day,
            value: weekShift * 7 + target,
            to: thisMonday
        ) else { return nil }

        // "周三"在周四说的是下一个周三；写了"这周/本周"则老老实实指本周那一天，
        // 哪怕它已经过去了（"这周一交的那份"）。
        if match.group(1) == nil, day < today,
           let next = calendar.date(byAdding: .day, value: 7, to: day) {
            day = next
        }
        return (day, match.whole)
    }

    private static func offsetDay(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> (day: Date, matched: String)? {
        let pattern = #"(\d{1,3})\s*(分钟|小时|天|日|周|个星期|个月)\s*(?:之)?[后内]"#
        guard let match = firstMatch(pattern, in: text),
              let amount = match.group(1).flatMap(Int.init),
              let unit = match.group(2) else { return nil }
        let date: Date?
        switch unit {
        case "分钟": date = calendar.date(byAdding: .minute, value: amount, to: now)
        case "小时": date = calendar.date(byAdding: .hour, value: amount, to: now)
        case "天", "日": date = calendar.date(byAdding: .day, value: amount, to: calendar.startOfDay(for: now))
        case "周", "个星期": date = calendar.date(byAdding: .day, value: amount * 7, to: calendar.startOfDay(for: now))
        case "个月": date = calendar.date(byAdding: .month, value: amount, to: calendar.startOfDay(for: now))
        default: date = nil
        }
        guard let date else { return nil }
        return (date, match.whole)
    }

    private static func periodBoundary(
        in text: String,
        now: Date,
        calendar: Calendar
    ) -> (day: Date, matched: String)? {
        let today = calendar.startOfDay(for: now)
        if let range = ["月底", "月末", "本月底"].first(where: { text.contains($0) }) {
            guard let interval = calendar.dateInterval(of: .month, for: today),
                  let last = calendar.date(byAdding: .day, value: -1, to: interval.end) else { return nil }
            return (calendar.startOfDay(for: last), range)
        }
        if let range = ["周末", "本周末"].first(where: { text.contains($0) }) {
            let currentWeekday = calendar.component(.weekday, from: today)
            var delta = 7 - currentWeekday  // 周六
            if delta < 0 { delta += 7 }
            guard let day = calendar.date(byAdding: .day, value: delta, to: today) else { return nil }
            return (day, range)
        }
        return nil
    }

    /// 系统探测器兜底。它认得英文和标准数字格式，补上规则表没覆盖的写法。
    private static func detectorFallback(in text: String, now: Date) -> ParsedDateReference? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, range: range),
              let date = match.date,
              let matchedRange = Range(match.range, in: text) else { return nil }
        return ParsedDateReference(
            date: date,
            // 探测器不区分"只有日期"和"日期加时间"，只能按它给的秒数判断：
            // 落在 00:00 的多半是它自己补的零点，不是用户写的时间。
            hasExplicitTime: Calendar.current.dateComponents([.hour, .minute], from: date) != DateComponents(hour: 0, minute: 0),
            matchedText: String(text[matchedRange])
        )
    }

    // MARK: - 正则小工具

    struct RegexMatch {
        var whole: String
        private var groups: [String?]

        init(whole: String, groups: [String?]) {
            self.whole = whole
            self.groups = groups
        }

        func group(_ index: Int) -> String? {
            guard groups.indices.contains(index - 1) else { return nil }
            return groups[index - 1]
        }
    }

    /// 编译好的正则按 pattern 缓存。
    ///
    /// `NSRegularExpression(pattern:)` 每次都要重新编译，而这条路径在一段
    /// OCR 文本上会被调用几百次（每行 × 六个日期规则）。实测编译本身就是
    /// 大头，缓存之后整段提取从几十毫秒掉到一毫秒量级。
    ///
    /// 用一把锁而不是 actor：调用方遍布 MainActor 与后台任务，做成异步会把
    /// 一个纯函数染成 async，代价远大于这里的锁竞争（命中即返回）。
    private static let regexCache = RegexCache()

    private final class RegexCache: @unchecked Sendable {
        private var storage: [String: NSRegularExpression] = [:]
        private let lock = NSLock()

        func regex(for pattern: String) -> NSRegularExpression? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = storage[pattern] { return cached }
            guard let compiled = try? NSRegularExpression(
                pattern: pattern,
                options: .caseInsensitive
            ) else { return nil }
            storage[pattern] = compiled
            return compiled
        }
    }

    static func firstMatch(_ pattern: String, in text: String) -> RegexMatch? {
        guard let regex = regexCache.regex(for: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let wholeRange = Range(match.range, in: text) else { return nil }
        var groups: [String?] = []
        for index in 1..<match.numberOfRanges {
            if let groupRange = Range(match.range(at: index), in: text) {
                groups.append(String(text[groupRange]))
            } else {
                groups.append(nil)
            }
        }
        return RegexMatch(whole: String(text[wholeRange]), groups: groups)
    }
}
