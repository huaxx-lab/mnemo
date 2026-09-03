import Foundation
import Testing
@testable import MnemoCore

@Test("Markdown 按块解析：标题、列表、代码块、段落")
func markdownSplitsIntoBlocks() {
    var document = MarkdownDocument()
    document.update(raw: """
    # 结论

    - 第一条
    2. 第二条

    ```
    let x = 1
    ```

    正文一段。
    """)

    let kinds = document.blocks.map(\.kind)
    #expect(kinds == [
        .heading(level: 1),
        .bullet(marker: "•"),
        .bullet(marker: "2."),
        .code,
        .paragraph,
    ])
    #expect(document.blocks.last?.text.description.contains("正文一段") == true)
    #expect(document.blocks[3].rawCode == "let x = 1")
}

@Test("流式追加时，已收尾的块保持同一身份，不会整棵重建")
func markdownKeepsSettledBlockIdentityWhileStreaming() {
    var document = MarkdownDocument()
    document.update(raw: "第一段。\n\n第二段还在写")
    let firstPass = document.blocks
    #expect(firstPass.count == 2)

    // 继续往末尾追加：第一段不该被重新编号，否则 SwiftUI 会把整段判成新视图
    document.update(raw: "第一段。\n\n第二段还在写，现在写完了。")
    #expect(document.blocks.count == 2)
    #expect(document.blocks[0] == firstPass[0])
    #expect(document.blocks[1].id == firstPass[1].id)
    #expect(document.blocks[1].text != firstPass[1].text)

    // 再收一个尾，前两段身份仍然稳定
    document.update(raw: "第一段。\n\n第二段还在写，现在写完了。\n\n第三段")
    #expect(document.blocks.count == 3)
    #expect(document.blocks[0] == firstPass[0])
}

@Test("换成另一份内容时重置，不会把旧块留在前面")
func markdownResetsWhenContentIsReplaced() {
    var document = MarkdownDocument()
    document.update(raw: "旧的回答。\n\n还有一段。")
    #expect(document.blocks.count == 2)

    document.update(raw: "全新的回答。")
    #expect(document.blocks.count == 1)
    #expect(document.blocks[0].text.description.contains("全新的回答"))
}

@Test("行内 Markdown 在解析时就转好，渲染路径上不再处理字符串")
func markdownParsesInlineSyntaxUpFront() {
    var document = MarkdownDocument()
    document.update(raw: "这是 **CSA-UD** 的主论文")
    let text = document.blocks[0].text
    // 星号必须已经被消化掉，而不是原样留在展示文本里
    #expect(!text.description.contains("**"))
    #expect(text.description.contains("CSA-UD"))
}
