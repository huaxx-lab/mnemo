import Foundation

/// 模型这一轮吐出来的一段增量：是给用户看的正文，还是它自己的思考。
///
/// 分成两个 case 而不是一个字符串，是因为下游要用完全不同的方式对待它们：
/// 正文可以写进用户的输入框、可以复制、可以当答案；思考只能展示，而且默认
/// 折叠。把它们混在一根字符串里，任何一个下游想区分都得重新猜一遍。
public enum AIStreamChunk: Sendable, Equatable {
    case text(String)
    case reasoning(String)

    public var value: String {
        switch self {
        case .text(let value), .reasoning(let value): value
        }
    }
}

/// 一段被拆开的增量。两条通道可能同时有内容——同一个网络分片里既有思考的
/// 结尾也有正文的开头是常态。
public struct ReasoningSplit: Sendable, Equatable {
    public var text: String
    public var reasoning: String

    public init(text: String = "", reasoning: String = "") {
        self.text = text
        self.reasoning = reasoning
    }

    public var isEmpty: Bool { text.isEmpty && reasoning.isEmpty }

    static func + (lhs: Self, rhs: Self) -> Self {
        ReasoningSplit(text: lhs.text + rhs.text, reasoning: lhs.reasoning + rhs.reasoning)
    }
}

/// 把模型的思考过程和正文分开。
///
/// 供应商交付思考过程有三种互不兼容的方式，**必须全都认**，否则换一个模型
/// 就退化成另一种坏法：
///
/// | 方式 | 谁在用 | 长什么样 |
/// | --- | --- | --- |
/// | 独立字段 | DeepSeek / Qwen / GLM / MiniMax / OpenRouter | `delta.reasoning_content` |
/// | 独立内容块 | Anthropic | `content_block_delta` 里 `thinking_delta` |
/// | 内联标签 | MiniMax、部分自建部署 | 正文里直接写 `<think>…</think>` |
///
/// 前两种在解码层就能分开；第三种混在正文里，只能靠字面标签切。三种都归一
/// 到同一个 `ReasoningSplit`，上层因此只需要处理"正文 + 思考"这一种形状。
///
/// 判断依据只有字面标签，不猜"这段像不像推理"——后者会把正文里正常的分析
/// 段落也误判，而那正是用户要的内容。
public enum ReasoningTrace {
    /// 会被当成思考过程的包裹标签。只认这几个字面词，宁可漏认也不多认。
    static let tagNames = ["think", "thinking", "reasoning", "reflection"]

    /// 一次性版本，用于非流式输出。
    public static func split(_ text: String) -> ReasoningSplit {
        var filter = Filter()
        let value = filter.consume(text) + filter.flush()
        return ReasoningSplit(
            text: value.text.trimmingCharacters(in: .whitespacesAndNewlines),
            reasoning: value.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// 只要正文。用在"这段文字会被复制、会被写进别人的输入框"的地方——
    /// 那里没有第二条通道可以承载思考，混进去就是污染。
    public static func stripped(_ text: String) -> String {
        split(text).text
    }

    /// 流式版本。
    ///
    /// 标签会被网络分片切成两半，所以不能逐个增量独立判断：必须像 `SSEParser`
    /// 那样留一个缓冲区，末尾可能是半个开标签的内容先扣住不发，否则用户会
    /// 看到 `<thi` 闪一下。
    public struct Filter: Sendable {
        private var pending = ""
        private var insideTrace = false

        public init() {}

        /// 结构化通道来的增量不需要切分：解码层已经知道它是哪一类了。
        public mutating func consume(_ chunk: AIStreamChunk) -> ReasoningSplit {
            switch chunk {
            case .text(let value):
                return consume(value)
            case .reasoning(let value):
                return ReasoningSplit(reasoning: value)
            }
        }

        /// 正文通道来的增量：可能内联着 `<think>`，要现切。
        public mutating func consume(_ delta: String) -> ReasoningSplit {
            guard !delta.isEmpty else { return ReasoningSplit() }
            pending += delta
            var result = ReasoningSplit()

            while true {
                if insideTrace {
                    guard let close = Self.firstTag(in: pending, opening: false) else {
                        result.reasoning += pending
                        pending = ""
                        break
                    }
                    result.reasoning += String(pending[pending.startIndex..<close.lowerBound])
                    pending = String(pending[close.upperBound...])
                    insideTrace = false
                    continue
                }
                guard let open = Self.firstTag(in: pending, opening: true) else { break }
                result.text += String(pending[pending.startIndex..<open.lowerBound])
                pending = String(pending[open.upperBound...])
                insideTrace = true
            }

            if !insideTrace {
                // 末尾可能是半个开标签。扣住那几个字符，等下一批再判断。
                let hold = Self.partialOpeningSuffixLength(of: pending)
                let cut = pending.index(pending.endIndex, offsetBy: -hold)
                result.text += String(pending[pending.startIndex..<cut])
                pending = String(pending[cut...])
            }
            return result
        }

        /// 流结束：把扣住的尾巴交出去。
        ///
        /// 开标签始终没闭合（模型被截断）时，剩下的算思考而不是正文——它本来
        /// 就是从 `<think>` 之后开始的。上层看到"只有思考没有正文"应当如实
        /// 报告，而不是把一段推演当成答案端给用户。
        public mutating func flush() -> ReasoningSplit {
            let tail = pending
            pending = ""
            let wasInside = insideTrace
            insideTrace = false
            return wasInside
                ? ReasoningSplit(reasoning: tail)
                : ReasoningSplit(text: tail)
        }

        /// 第一个 `<think>` / `</think>` 的范围。大小写不敏感，允许标签里有空白。
        private static func firstTag(in text: String, opening: Bool) -> Range<String.Index>? {
            var best: Range<String.Index>?
            for name in ReasoningTrace.tagNames {
                let pattern = opening ? "<\\s*\(name)\\s*>" : "<\\s*/\\s*\(name)\\s*>"
                guard let range = text.range(
                    of: pattern,
                    options: [.regularExpression, .caseInsensitive]
                ) else { continue }
                if best == nil || range.lowerBound < best!.lowerBound { best = range }
            }
            return best
        }

        /// 末尾有多少个字符可能是被切断的开标签前缀。
        static func partialOpeningSuffixLength(of text: String) -> Int {
            guard let last = text.lastIndex(of: "<") else { return 0 }
            let suffix = text[last...].lowercased()
            // 已经收全的标签轮不到这里——上面的循环会先把它切走。这里只处理
            // 还没见到 ">" 的残段，而且长度必须还够得上某个标签名。
            guard !suffix.contains(">") else { return 0 }
            let body = suffix.dropFirst().drop(while: { $0 == " " || $0 == "/" })
            let plausible = ReasoningTrace.tagNames.contains { $0.hasPrefix(body) }
            return plausible ? text.distance(from: last, to: text.endIndex) : 0
        }
    }
}
