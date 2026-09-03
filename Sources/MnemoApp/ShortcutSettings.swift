import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 一个全局快捷键的按键组合。
///
/// 修饰键用 Carbon 的掩码存（`cmdKey` / `optionKey` / `controlKey` / `shiftKey`），
/// 因为最终要交给 `RegisterEventHotKey`；显示时再翻译成符号。
struct KeyCombination: Codable, Equatable, Hashable, Sendable {
    var keyCode: Int
    var carbonModifiers: UInt32

    static let command = UInt32(cmdKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)
    static let shift = UInt32(shiftKey)

    /// 至少要有一个修饰键。
    ///
    /// 没有修饰键的全局热键会把那个字母从整个系统里抢走——用户在任何输入框里
    /// 都打不出它。这不是"不推荐"，是绝对不能允许。
    var isValid: Bool { carbonModifiers != 0 }

    var displayString: String {
        var text = ""
        if carbonModifiers & Self.control != 0 { text += "⌃" }
        if carbonModifiers & Self.option != 0 { text += "⌥" }
        if carbonModifiers & Self.shift != 0 { text += "⇧" }
        if carbonModifiers & Self.command != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= command }
        if flags.contains(.option) { value |= option }
        if flags.contains(.control) { value |= control }
        if flags.contains(.shift) { value |= shift }
        return value
    }

    /// 键码到可读名字。
    ///
    /// 只列真正会被用来当快捷键的那些。查不到就显示键码本身——总比显示一个
    /// 猜错的字母强，用户至少知道"这个键我认不出来"。
    static func keyName(_ code: Int) -> String {
        let named: [Int: String] = [
            kVK_Space: "空格", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
            kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
            kVK_F11: "F11", kVK_F12: "F12",
            kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
            kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
            kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        ]
        if let name = named[code] { return name }

        let letters: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        ]
        return letters[code] ?? "键 \(code)"
    }
}

/// Mnemo 会注册的全局动作。
enum ShortcutAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case togglePanel
    case ingestClipboard
    case captureSelection
    case recommendSelection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .togglePanel: "打开 / 收起 Mnemo"
        case .ingestClipboard: "收纳剪贴板"
        case .captureSelection: "收纳选中内容"
        case .recommendSelection: "检索选中内容"
        }
    }

    var detail: String {
        switch self {
        case .togglePanel: "展开刘海面板，再按一次收起"
        case .ingestClipboard: "把当前剪贴板内容存成一个 Pin"
        case .captureSelection: "抓取前台应用的选区并存下来，需要辅助功能权限"
        case .recommendSelection: "拿选中的文字去库里找，结果直接落在刘海上"
        }
    }

    /// 默认组合。
    ///
    /// 全部避开系统占用：原来的 ⌘Space 是聚焦搜索、⌘P 是打印，Mnemo 一运行
    /// 就把它们从所有应用手里抢走，代价远超收益。⌃⌘ 这一族基本没有系统占用。
    /// 只有 ⌘G 例外——它在多数应用里是"查找下一个"，但这是用户明确要求保留的，
    /// 而且这条路径本来就是"拿选中的文字去找东西"，语义并不冲突。
    var defaultCombination: KeyCombination {
        switch self {
        case .togglePanel:
            KeyCombination(keyCode: kVK_ANSI_N, carbonModifiers: KeyCombination.control | KeyCombination.command)
        case .ingestClipboard:
            KeyCombination(keyCode: kVK_ANSI_V, carbonModifiers: KeyCombination.control | KeyCombination.command)
        case .captureSelection:
            KeyCombination(keyCode: kVK_ANSI_C, carbonModifiers: KeyCombination.control | KeyCombination.command)
        case .recommendSelection:
            KeyCombination(keyCode: kVK_ANSI_G, carbonModifiers: KeyCombination.command)
        }
    }
}

/// 快捷键设置。
@MainActor
@Observable
final class ShortcutSettingsModel {
    private static let persistenceKey = "Pinland.shortcuts.v1"

    private struct Persisted: Codable {
        var combinations: [String: KeyCombination]
        var disabled: [String]
    }

    private(set) var combinations: [ShortcutAction: KeyCombination]
    private(set) var disabled: Set<ShortcutAction>
    /// 注册失败的动作。多半是这个组合被系统或别的应用先占了。
    private(set) var unavailable: Set<ShortcutAction> = []

    /// 有任何改动时重新注册。
    @ObservationIgnored var didChange: (() -> Void)?

    init() {
        let saved = UserDefaults.standard.data(forKey: Self.persistenceKey)
            .flatMap { try? JSONDecoder().decode(Persisted.self, from: $0) }
        var values: [ShortcutAction: KeyCombination] = [:]
        for action in ShortcutAction.allCases {
            values[action] = saved?.combinations[action.rawValue] ?? action.defaultCombination
        }
        combinations = values
        disabled = Set((saved?.disabled ?? []).compactMap(ShortcutAction.init(rawValue:)))
    }

    func combination(for action: ShortcutAction) -> KeyCombination {
        combinations[action] ?? action.defaultCombination
    }

    func isEnabled(_ action: ShortcutAction) -> Bool { !disabled.contains(action) }

    /// 这个组合是不是已经被别的动作占了。
    ///
    /// 只查 Mnemo 自己的：系统和别的应用占没占，只有真的去注册才知道，
    /// 那种情况由 `unavailable` 事后反映。
    func conflict(with combination: KeyCombination, excluding action: ShortcutAction) -> ShortcutAction? {
        combinations.first {
            $0.key != action && $0.value == combination && isEnabled($0.key)
        }?.key
    }

    @discardableResult
    func set(_ combination: KeyCombination, for action: ShortcutAction) -> ShortcutAction? {
        guard combination.isValid else { return nil }
        if let conflicting = conflict(with: combination, excluding: action) { return conflicting }
        combinations[action] = combination
        disabled.remove(action)
        persist()
        return nil
    }

    func setEnabled(_ enabled: Bool, for action: ShortcutAction) {
        if enabled { disabled.remove(action) } else { disabled.insert(action) }
        persist()
    }

    func reset(_ action: ShortcutAction) {
        combinations[action] = action.defaultCombination
        disabled.remove(action)
        persist()
    }

    func resetAll() {
        for action in ShortcutAction.allCases { combinations[action] = action.defaultCombination }
        disabled.removeAll()
        persist()
    }

    func markUnavailable(_ actions: Set<ShortcutAction>) { unavailable = actions }

    /// 设置页显式保存时重写偏好并重新注册全部组合。
    func saveSettings() { persist() }

    private func persist() {
        let value = Persisted(
            combinations: Dictionary(
                uniqueKeysWithValues: combinations.map { ($0.key.rawValue, $0.value) }
            ),
            disabled: disabled.map(\.rawValue).sorted()
        )
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.persistenceKey)
        }
        didChange?()
    }
}

/// 录一个按键组合。
///
/// 用 AppKit 的本地事件监听而不是 SwiftUI 的 `onKeyPress`：后者拿不到裸修饰键
/// 状态，也无法在按下 ⌘Q 这类系统组合时先于菜单拦下来。
struct ShortcutRecorder: NSViewRepresentable {
    var combination: KeyCombination
    var isRecording: Bool
    var onRecord: (KeyCombination) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = onRecord
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onRecord = onRecord
        nsView.onCancel = onCancel
        nsView.isRecording = isRecording
    }

    final class RecorderView: NSView {
        var onRecord: ((KeyCombination) -> Void)?
        var onCancel: (() -> Void)?
        private var monitor: Any?

        var isRecording = false {
            didSet {
                guard isRecording != oldValue else { return }
                isRecording ? startMonitoring() : stopMonitoring()
            }
        }

        /// 视图被移出窗口时就把监听撤掉。
        ///
        /// 不放在 deinit 里：`Any?` 不是 Sendable，nonisolated 的 deinit 碰不到它；
        /// 而且视图从层级里移走的那一刻本来就该停止抢按键，等到被释放才停太晚。
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { isRecording = false }
        }

        private func startMonitoring() {
            stopMonitoring()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // Esc 取消录制，不把它录成快捷键——那会让人再也退不出这个状态。
                if event.keyCode == UInt16(kVK_Escape) {
                    self.onCancel?()
                    return nil
                }
                let modifiers = KeyCombination.carbonModifiers(from: event.modifierFlags)
                let combination = KeyCombination(
                    keyCode: Int(event.keyCode),
                    carbonModifiers: modifiers
                )
                // 没有修饰键的组合直接丢弃：注册它等于把这个字母从全系统抢走。
                guard combination.isValid else { return nil }
                self.onRecord?(combination)
                return nil
            }
        }

        private func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
