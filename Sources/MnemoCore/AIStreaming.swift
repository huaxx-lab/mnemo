import Foundation

/// Server-Sent Events 的增量解析。
///
/// 网络分片和事件边界没有任何关系：一个 `data:` 负载可能跨两次 `consume`，
/// 一次 `consume` 也可能带来三条完整事件。所以这里只做一件事——把任意切分
/// 的字节流还原成一条条完整负载，交给上层按方言解码。
public struct SSEParser: Sendable {
    /// OpenAI 兼容端点用它标记流结束；Anthropic 不发，靠连接结束。
    public static let doneSentinel = "[DONE]"

    private var pending = ""
    private var dataLines: [String] = []

    public init() {}

    /// 返回这批字节里已经完整的负载，顺序与到达顺序一致。
    public mutating func consume(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        pending += text
        var payloads: [String] = []

        // 只在换行处切分：没有换行就说明这一行还没收完，留到下一批。
        while let breakIndex = pending.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
            let line = String(pending[pending.startIndex..<breakIndex])
            pending = String(pending[pending.index(after: breakIndex)...])
            if let payload = consume(line: line) { payloads.append(payload) }
        }
        return payloads
    }

    /// 连接结束时调用：把最后一行没有换行结尾的内容也结算掉。
    public mutating func flush() -> [String] {
        var payloads: [String] = []
        let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        if !tail.isEmpty, let payload = consume(line: tail) { payloads.append(payload) }
        if let payload = flushEvent() { payloads.append(payload) }
        return payloads
    }

    private mutating func consume(line rawLine: String) -> String? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

        // 空行是事件边界。
        if line.isEmpty { return flushEvent() }
        // 注释行（心跳）与非 data 字段一律忽略：event/id/retry 对我们没有意义。
        guard line.hasPrefix("data:") else { return nil }

        var value = String(line.dropFirst("data:".count))
        if value.hasPrefix(" ") { value.removeFirst() }
        dataLines.append(value)
        return nil
    }

    private mutating func flushEvent() -> String? {
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        return payload.isEmpty ? nil : payload
    }
}

/// 流式回答里，模型先写给人看的总结，再写机器读的推荐。
///
/// 分隔符之前的每一个增量都可以立刻上屏；之后的内容进缓冲区，等流结束再
/// 一次性解析成推荐。这样用户看得到打字效果，而卡片不会闪烁半截 JSON。
public struct AgenticAnswerAccumulator: Sendable {
    public static let delimiter = "---PINS---"

    /// 已经可以展示的总结文本。
    public private(set) var summary = ""
    /// 分隔符之后的原始内容，流结束后才解析。
    private var trailing = ""
    private var reachedDelimiter = false
    /// 分隔符之前那段是给人看的，正文里可能内联着 `<think>`，要现切；分隔符
    /// 之后是 JSON，本来就要走 `extractJSONObject`，不必也不该过这一层。
    private var traceFilter = ReasoningTrace.Filter()
    /// 从正文里切出来的思考过程。它不进 summary，由调用方单独展示。
    public private(set) var reasoning = ""

    public init() {}

    public mutating func consume(_ delta: String) {
        guard !delta.isEmpty else { return }
        if reachedDelimiter {
            trailing += delta
            return
        }
        let split = traceFilter.consume(delta)
        reasoning += split.reasoning
        guard !split.text.isEmpty else { return }

        summary += split.text
        guard let range = summary.range(of: Self.delimiter) else {
            return
        }
        // 分隔符可能跨增量到达，所以每次都在完整 summary 上找，找到就切开。
        trailing = String(summary[range.upperBound...])
        summary = String(summary[summary.startIndex..<range.lowerBound])
        reachedDelimiter = true
    }

    /// 流结束时调用一次：把过滤器扣住的尾巴交出来。不调也不会丢内容，
    /// 只是最后几个字符会晚到——但"模型只写了推理"那种残局要靠它兜底。
    public mutating func finish() {
        guard !reachedDelimiter else { return }
        let tail = traceFilter.flush()
        reasoning += tail.reasoning
        guard !tail.text.isEmpty else { return }
        summary += tail.text
        if let range = summary.range(of: Self.delimiter) {
            trailing = String(summary[range.upperBound...])
            summary = String(summary[summary.startIndex..<range.lowerBound])
            reachedDelimiter = true
        }
    }

    /// 分隔符可能被切成两半，末尾这段先别上屏，否则会闪一下残缺的 `---PI`。
    public var displaySummary: String {
        guard !reachedDelimiter else { return summary.trimmed() }
        let dropCount = Self.partialDelimiterSuffixLength(of: summary)
        return String(summary.dropLast(dropCount)).trimmed()
    }

    /// 只承认真实存在的 Pin。模型给出库里没有的 ID 一律丢弃——它是排序器，
    /// 不是内容来源。
    ///
    /// 模型不一定照着分隔符写。忘了写的时候 JSON 会混在总结里，这里退一步从
    /// 总结尾部找配平的花括号块——否则一次没照格式的输出就等于零个推荐。
    public func recommendationSelection(
        allowedItemIDs: Set<UUID>,
        limit: Int = 5
    ) -> RetrievalSelection {
        let json = Self.extractJSONObject(from: trailing)
            ?? Self.extractJSONObject(from: summary)
        return AgenticRetrieval.selection(
            modelJSON: json,
            allowedItemIDs: allowedItemIDs,
            limit: limit
        )
    }

    public func recommendations(allowedItemIDs: Set<UUID>, limit: Int = 5) -> [RetrievalRecommendation] {
        guard case .selected(let recommendations) = recommendationSelection(
            allowedItemIDs: allowedItemIDs,
            limit: limit
        ) else { return [] }
        return recommendations
    }

    /// 流结束后用于展示的总结。模型把 JSON 写进正文时，这里把它摘掉，
    /// 不让一段机器格式糊在用户眼前。
    public var finalizedSummary: String {
        guard !reachedDelimiter, let start = summary.firstIndex(of: "{"),
              Self.extractJSONObject(from: summary) != nil else {
            return displaySummary
        }
        return String(summary[summary.startIndex..<start]).trimmed()
    }

    /// summary 末尾有多少个字符可能是分隔符被截断的前半段。
    static func partialDelimiterSuffixLength(of text: String) -> Int {
        let delimiter = Array(delimiter)
        let tail = Array(text.suffix(delimiter.count - 1))
        var length = min(tail.count, delimiter.count - 1)
        while length > 0 {
            if Array(tail.suffix(length)) == Array(delimiter.prefix(length)) { return length }
            length -= 1
        }
        return 0
    }

    /// 模型偶尔会把 JSON 包在 ```json 围栏里，或者前后带一句话。取第一个
    /// 配平的花括号块即可，比整体解码宽容。
    public static func extractJSONObject(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let object = text[start...index]
                        return Data(object.utf8)
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

private extension String {
    func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
