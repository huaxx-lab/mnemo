import Foundation

/// 把可读文本切成检索单元。
///
/// 从 App 层搬进领域层：切块规则直接决定"答案那句话会不会被切散"，
/// 必须能被评测语料覆盖。原来它待在 executable target 里，测试 import 不到。
public enum ContentChunking {
    /// 按**语义段**打包成块（论坛的一层楼、一条评论各是一段）。
    ///
    /// 通用切块是每 1,200 字硬切一刀：一刀下去经常横跨两条不相干的回复，
    /// 召回的片段前半句是甲的问题、后半句是乙的吐槽，向量表示的是一个
    /// 根本不存在的"混合语义"。这里一段绝不跨块：装得下就多装几段，
    /// 单段超长的才退回按字数切它自己。
    public static func chunks(
        itemID: UUID,
        segments: [String],
        source: ContentChunkSource,
        pageNumber: Int?,
        ordinalBase: Int
    ) -> [ContentChunk] {
        let window = 1_200
        var result: [ContentChunk] = []
        var ordinal = ordinalBase
        var pending: [String] = []
        var pendingLength = 0

        func flush() {
            guard !pending.isEmpty else { return }
            result.append(ContentChunk(
                itemID: itemID,
                ordinal: ordinal,
                pageNumber: pageNumber,
                source: source,
                text: pending.joined(separator: "\n\n")
            ))
            ordinal += 1
            pending = []
            pendingLength = 0
        }

        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // 单独一段就超过一块的容量：它自己按字数切，切完继续攒后面的。
            if trimmed.count > window {
                flush()
                let long = chunks(
                    itemID: itemID,
                    text: trimmed,
                    source: source,
                    pageNumber: pageNumber,
                    ordinalBase: ordinal
                )
                result.append(contentsOf: long)
                ordinal += long.count
                continue
            }
            if pendingLength + trimmed.count > window { flush() }
            pending.append(trimmed)
            pendingLength += trimmed.count
        }
        flush()
        return result
    }

    /// 约 1,200 字符一块并保留 120 字符重叠，既保住跨段语义，又避免把整篇论文
    /// 一次送去 Embedding。这里按 Character 切，中文不会被 UTF-8 字节截断。
    public static func chunks(
        itemID: UUID,
        text: String,
        source: ContentChunkSource,
        pageNumber: Int?,
        ordinalBase: Int
    ) -> [ContentChunk] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let window = 1_200
        let overlap = 120
        var start = normalized.startIndex
        var ordinal = ordinalBase
        var result: [ContentChunk] = []
        while start < normalized.endIndex {
            let end = normalized.index(
                start,
                offsetBy: window,
                limitedBy: normalized.endIndex
            ) ?? normalized.endIndex
            let value = String(normalized[start..<end])
            result.append(ContentChunk(
                itemID: itemID,
                ordinal: ordinal,
                pageNumber: pageNumber,
                source: source,
                text: value
            ))
            ordinal += 1
            if end == normalized.endIndex { break }
            start = normalized.index(end, offsetBy: -overlap)
        }
        return result
    }
}
