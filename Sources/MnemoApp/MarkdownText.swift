import SwiftUI
import MnemoCore

/// 模型输出的是 Markdown，直接当纯文本显示会满屏 `**` 和 `-`。
struct MarkdownText: View {
    let raw: String
    var font: Font = .system(size: 12)

    @State private var document = MarkdownDocument()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 块的 id 在固化后就不再变，所以流式追加时 SwiftUI 只会重建
            // 末尾那一个，而不是整棵子树。
            ForEach(document.blocks) { block in
                row(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .onAppear { document.update(raw: raw) }
        .onChange(of: raw) { document.update(raw: raw) }
    }

    @ViewBuilder
    private func row(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text)
                .font(.system(size: level <= 1 ? 14 : 13, weight: .semibold))
                .foregroundStyle(Style.primary)
        case .bullet(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(font)
                    .monospacedDigit()
                    .foregroundStyle(Style.tertiary)
                Text(block.text)
                    .font(font)
                    .foregroundStyle(Style.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .code:
            Text(block.rawCode ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Style.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Style.surface, in: RoundedRectangle(cornerRadius: 6))
        case .paragraph:
            Text(block.text)
                .font(font)
                .foregroundStyle(Style.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
