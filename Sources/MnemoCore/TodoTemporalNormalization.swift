import Foundation

/// 给模型看的、已经本地确定化的时间上下文。
///
/// 原文与归一化文本分开：模型用后者判断日期，但 `evidence` / `code` 只能从原文
/// 逐字复制。这样模型不需要自己算“明天”，又不能拿归一化后的新增文字冒充证据。
public struct TodoTemporalContext: Sendable, Equatable {
    public struct Resolution: Sendable, Equatable {
        public var expression: String
        public var absoluteDate: Date
        public var hasExplicitTime: Bool
        /// 纯 UI / 聊天时间戳，作用是给后续消息建立时间轴，本身不是任务。
        public var isContextAnchor: Bool
        public var lineNumber: Int

        public init(
            expression: String,
            absoluteDate: Date,
            hasExplicitTime: Bool,
            isContextAnchor: Bool,
            lineNumber: Int
        ) {
            self.expression = expression
            self.absoluteDate = absoluteDate
            self.hasExplicitTime = hasExplicitTime
            self.isContextAnchor = isContextAnchor
            self.lineNumber = lineNumber
        }
    }

    public var originalText: String
    public var normalizedText: String
    public var resolutions: [Resolution]

    public init(originalText: String, normalizedText: String, resolutions: [Resolution]) {
        self.originalText = originalText
        self.normalizedText = normalizedText
        self.resolutions = resolutions
    }
}

/// 把待办输入里的相对时间全部先在本地转换成绝对时间。
///
/// 这里不判断“是不是待办”，也不判断任务类型；只做日历算术与聊天时间轴。
/// 是否新建 / 改期 / 忽略仍由模型理解。
public enum TodoTemporalNormalizer {
    public static let maximumInputLength = 4_000
    private static let maximumReferencesPerLine = 6

    public static func normalize(
        _ text: String,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> TodoTemporalContext {
        let source = String(text.prefix(maximumInputLength))
        let lines = source.components(separatedBy: .newlines)
        var normalized: [String] = []
        var resolutions: [TodoTemporalContext.Resolution] = []
        // 最近一条纯聊天时间戳是后续消息里“明天/后天”的基准。
        var conversationAnchor = now

        for (offset, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                normalized.append("")
                continue
            }

            // 时间戳标题（昨天 / 星期五 / 20:25）永远相对截图识别时刻解释；
            // 只有消息正文里的“明天”才相对最近一条时间戳解释。否则“星期五”
            // 之后的“昨天”会被错误地算成星期四，而不是截图当前日期的昨天。
            let anchorReferences = allReferences(in: line, now: now, calendar: calendar)
            let isAnchor = isTimestampOnly(line, references: anchorReferences)

            if isAnchor, var first = anchorReferences.first {
                // 普通时间解析把已经过去的裸钟点滚到明天；UI 时间戳恰好相反，
                // 应落在最近过去的那一天。
                if first.date.timeIntervalSince(now) > 12 * 60 * 60,
                   line.range(of: #"(?:周|星期|礼拜)"#, options: .regularExpression) == nil,
                   let previous = calendar.date(byAdding: .day, value: -1, to: first.date) {
                    first.date = previous
                }
                // “星期五 23:35”作为聊天标题通常指刚过去的星期五，不是未来。
                if first.date > now,
                   line.range(of: #"(?:周|星期|礼拜)"#, options: .regularExpression) != nil,
                   let previous = calendar.date(byAdding: .day, value: -7, to: first.date) {
                    first.date = previous
                }
                conversationAnchor = first.date
                resolutions.append(.init(
                    expression: first.matchedText,
                    absoluteDate: first.date,
                    hasExplicitTime: first.hasExplicitTime,
                    isContextAnchor: true,
                    lineNumber: offset + 1
                ))
                normalized.append(
                    "[界面时间锚点：\(absoluteString(first, calendar: calendar))；不是任务]"
                )
                continue
            }

            let references = allReferences(
                in: line,
                now: conversationAnchor,
                calendar: calendar
            )
            var rendered = line
            // 从长表达开始替换，避免“明天晚上八点”先替掉“明天”之后，剩余八点
            // 又被当成第二个不相关时间。
            for reference in references.sorted(by: { $0.matchedText.count > $1.matchedText.count }) {
                let label = "[绝对时间：\(absoluteString(reference, calendar: calendar))]"
                rendered = replacingTemporalTokens(
                    reference.matchedText,
                    in: rendered,
                    with: label
                )
                resolutions.append(.init(
                    expression: reference.matchedText,
                    absoluteDate: reference.date,
                    hasExplicitTime: reference.hasExplicitTime,
                    isContextAnchor: false,
                    lineNumber: offset + 1
                ))
            }
            normalized.append(rendered)
        }

        return TodoTemporalContext(
            originalText: source,
            normalizedText: normalized.joined(separator: "\n"),
            resolutions: resolutions
        )
    }

    /// 一行里可能同时有“周五交 A，周六交 B”。反复调用单值解析器，并把每次
    /// 命中的原文 token 从工作副本里移走，直到没有更多或到安全上限。
    private static func allReferences(
        in line: String,
        now: Date,
        calendar: Calendar
    ) -> [ParsedDateReference] {
        var working = line
        var result: [ParsedDateReference] = []
        for _ in 0..<maximumReferencesPerLine {
            guard let reference = ChineseDateParser.firstDate(
                in: working,
                now: now,
                calendar: calendar
            ) else { break }
            // 防止系统 detector 重复返回同一个无法替换的表达式。
            guard !reference.matchedText.isEmpty,
                  !result.contains(where: { $0.matchedText == reference.matchedText }) else { break }
            result.append(reference)
            let replaced = replacingTemporalTokens(reference.matchedText, in: working, with: " ")
            guard replaced != working else { break }
            working = replaced
        }
        return result
    }

    /// 去掉所有时间 token 后只剩标点 / “昨天、星期”等 UI 包装，就是时间戳行。
    private static func isTimestampOnly(
        _ line: String,
        references: [ParsedDateReference]
    ) -> Bool {
        guard !references.isEmpty else { return false }
        var residue = line
        for reference in references {
            residue = replacingTemporalTokens(reference.matchedText, in: residue, with: " ")
        }
        residue = residue
            .replacingOccurrences(
                of: #"(?:昨天|前天|今天|今日|星期|礼拜|周|上午|下午|晚上|早上|中午|凌晨)"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(
                in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
            )
        return residue.isEmpty
    }

    /// `matchedText` 为了同时带日期和钟点，会用空格拼接（如“明天 晚上八点”）；
    /// 原文里通常没有那个空格。逐 token 替换，并且只在第一个 token 位置写标签。
    private static func replacingTemporalTokens(
        _ matchedText: String,
        in source: String,
        with replacement: String
    ) -> String {
        let tokens = matchedText
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return source }
        var result = source
        var inserted = false
        for token in tokens {
            guard result.localizedCaseInsensitiveContains(token) else { continue }
            result = result.replacingOccurrences(
                of: token,
                with: inserted ? "" : replacement,
                options: [.caseInsensitive],
                range: result.startIndex..<result.endIndex
            )
            inserted = true
        }
        return result
    }

    private static func absoluteString(
        _ reference: ParsedDateReference,
        calendar: Calendar
    ) -> String {
        var formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = reference.hasExplicitTime
            ? [.withInternetDateTime, .withColonSeparatorInTimeZone]
            : [.withFullDate, .withDashSeparatorInDate]
        let value = formatter.string(from: reference.date)
        return reference.hasExplicitTime ? value : value + "（未给具体钟点）"
    }
}
