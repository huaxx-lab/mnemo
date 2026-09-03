import Foundation
import Testing
@testable import MnemoCore

@Test("光标停在别的应用的输入框里才走直接写入，其余一律回剪贴板")
func answerRouteOnlyTargetsRealForeignInputs() {
    let chatBox = FocusedInputSnapshot(role: "AXTextArea", acceptsInsertion: true)
    #expect(AnswerDeliveryPolicy.route(prefersFocusedInput: true, focus: chatBox) == .focusedInput)

    // 开关是用户的，关掉之后这条路径不许碰任何输入框。
    #expect(AnswerDeliveryPolicy.route(prefersFocusedInput: false, focus: chatBox) == .clipboard)

    // 压根没有焦点（桌面、访达图标）。
    #expect(AnswerDeliveryPolicy.route(prefersFocusedInput: true, focus: nil) == .clipboard)

    // 只读正文：能读不能写，往里写等于篡改别人的文章。
    #expect(AnswerDeliveryPolicy.route(
        prefersFocusedInput: true,
        focus: FocusedInputSnapshot(role: "AXStaticText", acceptsInsertion: true)
    ) == .clipboard)
    // 微信 / Electron 的真正可编辑宿主可能只是 AXGroup；AXIsEditable
    // 明确为真时不能因为 role 不在原生白名单就漏掉 SSE。
    #expect(AnswerDeliveryPolicy.route(
        prefersFocusedInput: true,
        focus: FocusedInputSnapshot(
            role: "AXGroup",
            acceptsInsertion: true,
            isEditableHost: true
        )
    ) == .focusedInput)
    #expect(AnswerDeliveryPolicy.route(
        prefersFocusedInput: true,
        focus: FocusedInputSnapshot(role: "AXTextField", acceptsInsertion: false)
    ) == .clipboard)

    // 焦点在 Mnemo 自己的搜索框上：那不是"用户正在别处写字"。
    #expect(AnswerDeliveryPolicy.route(
        prefersFocusedInput: true,
        focus: FocusedInputSnapshot(
            role: "AXTextField",
            acceptsInsertion: true,
            isOwnedByMnemo: true
        )
    ) == .clipboard)

    // 密码框永远不写，哪怕它暴露了可写文本属性。
    #expect(AnswerDeliveryPolicy.route(
        prefersFocusedInput: true,
        focus: FocusedInputSnapshot(
            role: "AXTextField",
            acceptsInsertion: true,
            isSecure: true
        )
    ) == .clipboard)
}

@Test("完全不暴露可编辑焦点的应用仍可交付，但要靠已验证选区兜底")
func opaqueApplicationsStillReceiveAnswer() {
    // 微信实测：AX 树里没有任何可写文本元素，role 也无从判断。
    let wechat = FocusedInputSnapshot(
        role: "",
        acceptsInsertion: true,
        isOpaqueApplication: true
    )
    #expect(AnswerDeliveryPolicy.route(prefersFocusedInput: true, focus: wechat) == .focusedInput)
    // 开关关掉就完全不碰这类应用。
    #expect(AnswerDeliveryPolicy.route(prefersFocusedInput: false, focus: wechat) == .clipboard)
    // Mnemo 自己的窗口即使不透明也不写。
    #expect(AnswerDeliveryPolicy.route(
        prefersFocusedInput: true,
        focus: FocusedInputSnapshot(
            role: "",
            acceptsInsertion: true,
            isOwnedByMnemo: true,
            isOpaqueApplication: true
        )
    ) == .clipboard)
}



@Test("写不进去时：一个字没写就当没走过，写了一半就停手交剪贴板")
func answerInsertionRecoveryDependsOnWhatAlreadyLanded() {
    #expect(AnswerDeliveryPolicy.recovery(insertedCharacters: 0) == .switchToClipboard)
    #expect(AnswerDeliveryPolicy.recovery(insertedCharacters: 1) == .finishInClipboard)
    #expect(AnswerDeliveryPolicy.recovery(insertedCharacters: 380) == .finishInClipboard)
}

@Test("打字机按固定节拍匀速吐字，积压多了才追赶")
func typewriterPacesOutputInsteadOfDumping() {
    // 没有积压就不出字。
    #expect(AnswerTypewriter.charactersToEmit(backlog: 0) == 0)
    // 常速：每拍两个字，约每秒 100 字，肉眼是连续打字而不是一坨。
    #expect(AnswerTypewriter.charactersToEmit(backlog: 5) == AnswerTypewriter.baseCharacters)
    #expect(AnswerTypewriter.charactersToEmit(backlog: 60) == AnswerTypewriter.baseCharacters)
    // 模型一次吐一大段时进入追赶档，但有上限：整段到达也必须是看得见的打字过程，
    // 不能一两拍冲完又变回"一坨"。
    #expect(AnswerTypewriter.charactersToEmit(backlog: 400) == AnswerTypewriter.maximumCharacters)
    #expect(AnswerTypewriter.charactersToEmit(backlog: 61) == AnswerTypewriter.maximumCharacters)
    // 永远不会超过实际积压。
    #expect(AnswerTypewriter.charactersToEmit(backlog: 1) == 1)
}
