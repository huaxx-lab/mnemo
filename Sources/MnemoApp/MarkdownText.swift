import SwiftUI
import MnemoCore

/// 模型输出的是 Markdown，直接当纯文本显示会满屏 `**` 和 `-`。
struct MarkdownText: View {
    /// 文字配色。刘海是固定深色底，所以 Style.* 全是白系；放进普通窗口
    /// （系统浅色底）就成了白字压浅灰，完全看不清。谁用谁指定。
    struct Palette {
        var primary: Color
        var secondary: Color
        var tertiary: Color
        var surface: Color

        /// 刘海：深色底上的白系文字。
        static let notch = Palette(
            primary: Style.primary,
            secondary: Style.secondary,
            tertiary: Style.tertiary,
            surface: Style.surface
        )

        /// 普通窗口：跟随系统浅色/深色。
        static let window = Palette(
            primary: Color(nsColor: .labelColor),
            secondary: Color(nsColor: .secondaryLabelColor),
            tertiary: Color(nsColor: .tertiaryLabelColor),
            surface: Color(nsColor: .textBackgroundColor)
        )
    }

    let raw: String
    var font: Font = .system(size: 12)
    var palette: Palette = .notch

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
                .foregroundStyle(palette.primary)
        case .bullet(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(font)
                    .monospacedDigit()
                    .foregroundStyle(palette.tertiary)
                Text(block.text)
                    .font(font)
                    .foregroundStyle(palette.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .code:
            Text(block.rawCode ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 6))
        case .paragraph:
            Text(block.text)
                .font(font)
                .foregroundStyle(palette.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
