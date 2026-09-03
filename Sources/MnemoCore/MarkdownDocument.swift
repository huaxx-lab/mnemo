import Foundation

/// 流式 Markdown 的增量渲染。
///
/// 朴素做法是每次内容变化就把整段重新解析、整棵子树重建。流式输出时文本每
/// 几十毫秒长一截，于是"重新解析 n 个字符"会被执行 n/步长 次——总代价是
/// 平方级的，而且每一帧所有段落都被判定为新视图，全部重排。
///
/// 这里换成：已经遇到过空行、不可能再变的块**只解析一次**并固化下来；只有
/// 结尾那个还在生长的块每次重解析。行内 Markdown 的 AttributedString 也在
/// 解析时就算好，渲染路径上不再做任何字符串处理。
public struct MarkdownBlock: Identifiable, Equatable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case bullet(marker: String)
        case code
        case paragraph
    }

    public let id: Int
    public var kind: Kind
    /// 代码块保留原文；其余在解析时就转成 AttributedString。
    public var text: AttributedString
    public var rawCode: String?

    public static func == (lhs: MarkdownBlock, rhs: MarkdownBlock) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind
            && lhs.text == rhs.text && lhs.rawCode == rhs.rawCode
    }
}

/// 增量解析器。持有"已固化"的部分，只对结尾未收尾的一段重复工作。
public struct MarkdownDocument {
    public private(set) var blocks: [MarkdownBlock] = []
    /// 已固化内容在原文里的长度。下一次只从这里往后看。
    private var committedLength = 0
    private var committedBlocks: [MarkdownBlock] = []
    private var nextID = 0

    public init() {}

    public mutating func update(raw: String) {
        // 内容被换掉了（新的一次提问/检索），而不是在原文后面接着长。
        if !raw.hasPrefix(String(raw.prefix(committedLength)))
            || raw.count < committedLength {
            self = MarkdownDocument()
        }

        let tail = String(raw.dropFirst(committedLength))
        // 最后一个空行之前的内容不会再变，可以固化；之后的还在生长。
        let boundary = tail.range(of: "\n\n", options: .backwards)
        let settled = boundary.map { String(tail[tail.startIndex..<$0.upperBound]) } ?? ""
        let live = boundary.map { String(tail[$0.upperBound...]) } ?? tail

        if !settled.isEmpty {
            let parsed = Self.parse(settled, startingAt: nextID)
            committedBlocks += parsed
            nextID += parsed.count
            committedLength += settled.count
        }
        blocks = committedBlocks + Self.parse(live, startingAt: nextID)
    }

    private static func parse(_ raw: String, startingAt firstID: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inCode = false
        var id = firstID

        func emit(_ kind: MarkdownBlock.Kind, _ text: String, code rawCode: String? = nil) {
            blocks.append(MarkdownBlock(
                id: id,
                kind: kind,
                text: rawCode == nil ? inline(text) : AttributedString(text),
                rawCode: rawCode
            ))
            id += 1
        }

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            emit(.paragraph, paragraph.joined(separator: " "))
            paragraph.removeAll()
        }

        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    let body = code.joined(separator: "\n")
                    emit(.code, body, code: body)
                    code.removeAll()
                } else {
                    flushParagraph()
                }
                inCode.toggle()
                continue
            }
            if inCode { code.append(line); continue }
            if trimmed.isEmpty { flushParagraph(); continue }

            if trimmed.hasPrefix("#") {
                flushParagraph()
                let level = trimmed.prefix(while: { $0 == "#" }).count
                emit(
                    .heading(level: level),
                    trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                )
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                emit(.bullet(marker: "•"), String(trimmed.dropFirst(2)))
                continue
            }
            if let marker = orderedMarker(trimmed) {
                flushParagraph()
                emit(
                    .bullet(marker: marker.trimmingCharacters(in: .whitespaces)),
                    String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                )
                continue
            }
            paragraph.append(trimmed)
        }
        if inCode, !code.isEmpty {
            let body = code.joined(separator: "\n")
            emit(.code, body, code: body)
        }
        flushParagraph()
        return blocks
    }

    /// 行内 Markdown 只在解析时算一次，渲染路径上不再碰字符串。
    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
    }

    /// "1. " / "2) " 这类有序列表前缀。
    private static func orderedMarker(_ line: String) -> String? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")",
              rest.dropFirst().first == " " else { return nil }
        return String(line.prefix(digits.count + 2))
    }
}
