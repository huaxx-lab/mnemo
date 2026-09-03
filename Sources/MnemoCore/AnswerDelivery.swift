import Foundation

/// 一次快捷回答的落点。
public enum AnswerDeliveryRoute: Sendable, Equatable {
    /// 光标正停在别的应用的输入框里：边生成边写进去，用户不用等整段生成完
    /// 再自己粘一次。
    case focusedInput
    /// 没有可写的输入框：仍然整段生成完再进剪贴板，行为与从前一致。
    case clipboard
}

/// 按下快捷键那一刻，前台聚焦控件的事实快照。
///
/// 这里只放辅助功能树读出来的原始事实，"算不算输入框"交给策略——AX 调用在
/// 单元测试里跑不起来，事实与判断分开，规则才测得到。
public struct FocusedInputSnapshot: Sendable, Equatable {
    /// AXRole，例如 AXTextField / AXTextArea。
    public var role: String
    /// AXSelectedText 或 AXValue 可写。只读的正文视图不是输入框。
    public var acceptsInsertion: Bool
    /// 焦点在 Mnemo 自己的窗口上（设置页、搜索框）。往自己身上写没有意义。
    public var isOwnedByMnemo: Bool
    /// 微信 / Electron / WebKit 常把可编辑宿主暴露成 AXGroup / AXWebArea，
    /// 不能只靠 role 判断；AXIsEditable / AXEditableAncestor 是更可靠的事实。
    public var isEditableHost: Bool
    /// 应用整棵辅助功能树里都没有可编辑焦点——微信这类自绘客户端就是如此
    /// （实测其 AX 树中可写 AXSelectedText 元素为 0）。这种应用只能靠合成键盘
    /// 事件写入，因此必须由"本轮选区已验证 + 目标应用仍在前台"两道闸门兜底。
    public var isOpaqueApplication: Bool
    /// 密码框永远排除。默认开启的便利功能不能向敏感输入控件主动写字。
    public var isSecure: Bool

    public init(
        role: String,
        acceptsInsertion: Bool,
        isOwnedByMnemo: Bool = false,
        isEditableHost: Bool = false,
        isOpaqueApplication: Bool = false,
        isSecure: Bool = false
    ) {
        self.role = role
        self.acceptsInsertion = acceptsInsertion
        self.isOwnedByMnemo = isOwnedByMnemo
        self.isEditableHost = isEditableHost
        self.isOpaqueApplication = isOpaqueApplication
        self.isSecure = isSecure
    }

    /// 只认真正的文本输入控件。AXStaticText、AXWebArea 这类偶尔也报告可写，
    /// 但往里写等于篡改别人的正文，不是"填进输入框"。
    public static let insertableRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
    ]

    public var isInsertable: Bool {
        acceptsInsertion && !isOwnedByMnemo && !isSecure
            && (Self.insertableRoles.contains(role) || isEditableHost || isOpaqueApplication)
    }
}

public enum AnswerDeliveryPolicy {
    /// 开关关掉、没有焦点、焦点不是输入框——任何一条都退回剪贴板。
    /// 默认开，但用户永远能关；关掉之后这条路径完全不碰别人的输入框。
    public static func route(
        prefersFocusedInput: Bool,
        focus: FocusedInputSnapshot?
    ) -> AnswerDeliveryRoute {
        guard prefersFocusedInput, let focus, focus.isInsertable else { return .clipboard }
        return .focusedInput
    }

    /// 写不进去时怎么收场。
    public enum Recovery: Sendable, Equatable {
        /// 一个字都还没写进去：干净地当作从来没走过输入框这条路。
        case switchToClipboard
        /// 已经写进去一部分：不能撤回，也不能继续写半截，停手并把完整回答
        /// 交到剪贴板，让用户自己决定要不要补上。
        case finishInClipboard
    }

    public static func recovery(insertedCharacters: Int) -> Recovery {
        insertedCharacters > 0 ? .finishInClipboard : .switchToClipboard
    }
}

/// 打字机节拍。
///
/// 模型的增量是"一句一坨"地到达的，直接按到达节奏写，看到的就是一坨一坨往外蹦。
/// 真正的打字机效果必须把**到达速度**和**出字速度**解耦：增量先进缓冲，再由固定
/// 节拍匀速取字。积压过多时适当加速，避免模型早就说完了、字还在慢慢爬。
public enum AnswerTypewriter: Sendable {
    /// 出字节拍。20ms 一次，配合下面的取字数约等于每秒 100 字。
    public static let tickInterval: TimeInterval = 0.02
    /// 常速每拍取几个字。
    public static let baseCharacters = 2
    /// 积压超过这个字数就进入追赶档，否则结尾会拖很久。
    public static let catchUpBacklog = 60
    /// 追赶档也有上限：约每秒 400 字。没有这个上限，供应商不流式、整段一次到达时
    /// 会在一两拍里冲完，又变回"一坨"。
    public static let maximumCharacters = 8

    /// 这一拍应该吐几个字。
    public static func charactersToEmit(backlog: Int) -> Int {
        guard backlog > 0 else { return 0 }
        let rate = backlog > catchUpBacklog ? maximumCharacters : baseCharacters
        return min(backlog, rate)
    }
}
