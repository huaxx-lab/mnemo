import AppKit
import ApplicationServices
import MnemoCore

/// 按下 ⌘G 时用户正在输入的地方。
///
/// 两类应用差别巨大，必须分开处理：
/// - **暴露辅助功能的应用**（原生 App、Safari、多数编辑器）：焦点、选区和可写
///   文本都能从 AX 树读到，直接按属性写入，可逐字校验、可撤回。
/// - **不暴露的应用**（微信这类自绘客户端）：实测其整棵 AX 树里可写
///   `AXSelectedText` 元素为 0、`AXIsEditable` 为 0，聊天输入框根本不在树里，
///   系统级 `AXFocusedUIElement` 直接返回空。这种应用只能向它的进程发送合成
///   键盘事件，所以必须由"本轮选区已验证 + 目标应用仍在前台"两道闸门兜底。
@MainActor
struct FocusedInputTarget {
    private enum Kind {
        /// AX 可用：宿主、写入载体、选区载体与按键时的选区。
        case accessibility(
            host: AXUIElement,
            writer: AXUIElement,
            carrier: AXUIElement,
            range: CFRange?
        )
        /// AX 不可用，只能对整个应用合成键盘事件。
        case opaqueApplication
    }

    private let kind: Kind
    private let targetPID: pid_t
    /// 只用于诊断日志，不参与任何判断。
    var diagnosticKind: String {
        switch kind {
        case .accessibility: "ax"
        case .opaqueApplication: "opaque"
        }
    }
    private var capturedSelectedText: String?
    let snapshot: FocusedInputSnapshot

    /// - Parameter ownerPID: 按下快捷键那一刻的前台应用。必须由调用方在任何
    ///   Mnemo 界面变化之前取好：之后再问"谁在前台"可能已经是 Mnemo 自己。
    static func capture(ownerPID: pid_t?) -> FocusedInputTarget? {
        guard AXIsProcessTrusted() else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = ownerPID
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let frontPID, frontPID != ownPID,
              let frontmost = NSRunningApplication(processIdentifier: frontPID) else { return nil }

        if let focused = focusedElement(),
           let host = editableHost(startingAt: focused), !isSecure(host) {
            var hostPID: pid_t = 0
            AXUIElementGetPid(host, &hostPID)
            let writer = writableElement(focused: focused, host: host) ?? host
            let carrier = selectionElement(focused: focused, host: host)
            return FocusedInputTarget(
                kind: .accessibility(
                    host: host,
                    writer: writer,
                    carrier: carrier,
                    range: selectedRange(carrier)
                ),
                targetPID: hostPID,
                capturedSelectedText: string(carrier, kAXSelectedTextAttribute),
                snapshot: FocusedInputSnapshot(
                    role: string(host, kAXRoleAttribute) ?? "",
                    acceptsInsertion: true,
                    isOwnedByMnemo: hostPID == ProcessInfo.processInfo.processIdentifier,
                    isEditableHost: true,
                    isSecure: isSecure(host)
                )
            )
        }

        // 访达 / 程序坞把普通字符当成"输入首字母跳转"，不是文本输入场景，
        // 盲写只会让选中项乱跳。这类应用宁可不写。
        let excluded: Set<String> = ["com.apple.finder", "com.apple.dock"]
        guard let bundleID = frontmost.bundleIdentifier, !excluded.contains(bundleID) else {
            return nil
        }

        // 这个应用没有可用的辅助功能焦点。只有当本轮选区随后被验证为"当前选区"
        // 时，AppModel 才会真的启用它；否则这个目标会被丢弃。
        return FocusedInputTarget(
            kind: .opaqueApplication,
            targetPID: frontPID,
            capturedSelectedText: nil,
            snapshot: FocusedInputSnapshot(
                role: "",
                acceptsInsertion: true,
                isOwnedByMnemo: false,
                isOpaqueApplication: true
            )
        )
    }

    /// 选区经 AXSelectedText 或本轮 Command-C 验证后回填。对微信这类应用，
    /// 这是"用户确实刚在这个应用里选中并提问"的唯一凭据。
    mutating func bindVerifiedSelection(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        capturedSelectedText = trimmed
    }

    func prepareForInsertion() async -> FocusedInputSession? {
        guard snapshot.isInsertable else { return nil }
        switch kind {
        case .opaqueApplication:
            guard capturedSelectedText?.isEmpty == false,
                  await Self.ensureFrontmost(targetPID) else { return nil }
            return keyboardOnlySession()

        case .accessibility(let host, let writer, let carrier, let capturedRange):
            guard await Self.ensureFrontmost(targetPID) else { return nil }
            // 焦点回不去，但用户仍停在这个应用里：不要退回剪贴板。输入法就是
            // 在这种情况下照样把文字交给应用的——聊天类应用收到字符会自己把
            // 输入框重新聚焦。
            guard restoreFocusIfPossible(host: host),
                  let focused = Self.focusedElement(),
                  let currentHost = Self.editableHost(startingAt: focused),
                  CFEqual(currentHost, host) else {
                return keyboardOnlySession()
            }

            let currentCarrier = Self.selectionElement(focused: focused, host: currentHost)
            let hostRange = Self.selectedRange(currentCarrier)
            let hostSelectedText = Self.string(currentCarrier, kAXSelectedTextAttribute)
            // 能给出事实的应用必须完全一致；给不出的保留键盘事件路径。
            let currentRange: CFRange?
            if let capturedRange, let hostRange {
                guard hostRange.location == capturedRange.location,
                      hostRange.length == capturedRange.length else { return nil }
                currentRange = hostRange
            } else {
                currentRange = hostRange ?? capturedRange
            }
            if let capturedSelectedText, !capturedSelectedText.isEmpty,
               let hostSelectedText {
                guard hostSelectedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    == capturedSelectedText else { return nil }
            }

            let selectedTextWritable = Self.isSettable(writer, kAXSelectedTextAttribute)
            let valueWritable = Self.isSettable(writer, kAXValueAttribute)
            let rangeWritable = Self.isSettable(currentCarrier, kAXSelectedTextRangeAttribute)

            guard let currentRange, rangeWritable, selectedTextWritable || valueWritable else {
                return keyboardOnlySession()
            }
            // 不再折叠选区：用户要的是"回答直接把问题替换掉"，所以第一段写入
            // 落在选区上，输入框里只剩答案。原文留在会话里，回滚时写得回去。
            return FocusedInputSession(
                mode: .accessibility(
                    writer: writer,
                    rangeElement: currentCarrier,
                    canSetSelectedText: selectedTextWritable,
                    canSetValue: valueWritable
                ),
                focusMatches: { Self.hostOfCurrentFocus().map { CFEqual($0, host) } == true },
                originalRange: currentRange,
                startLocation: currentRange.location,
                expectedCaretLocation: currentRange.location,
                replacementLength: currentRange.length,
                originalSelectedText: hostSelectedText ?? capturedSelectedText
            )
        }
    }

    /// 只靠合成按键写入的会话：应用不暴露输入框，或焦点回不去时用它。
    /// 只靠合成按键写入的会话。这里**不发**方向键去折叠选区——保留选区，
    /// 第一个字符落下时应用会自然地用它替换掉用户的问题，正好是"先清空输入框"。
    private func keyboardOnlySession() -> FocusedInputSession {
        let pid = targetPID
        return FocusedInputSession(
            mode: .keyboardEvents(targetPID: pid),
            focusMatches: {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            },
            originalRange: nil,
            startLocation: 0,
            expectedCaretLocation: 0,
            replacementLength: 0,
            originalSelectedText: capturedSelectedText
        )
    }

    /// 目标应用还在前台吗。
    ///
    /// 按下 ⌘G 之后刘海会出现，前台有可能变成 Mnemo 自己——用户看到的就是
    /// "输入框光标没了"。这属于我们自己造成的副作用，所以只纠正这一种：把前台
    /// 还给按键时那个应用。用户主动切到第三个应用时不纠正，老实退回剪贴板。
    private static func ensureFrontmost(_ pid: pid_t) async -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid) else { return false }
        app.activate()
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(25))
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
        }
        return false
    }

    /// 触发快捷键之后输入框常常不再是焦点——用户得"再点一下"才能打字。
    /// 写之前把焦点还回去，但只在目标应用仍在前台时做。
    private func restoreFocusIfPossible(host: AXUIElement) -> Bool {
        if Self.hostOfCurrentFocus().map({ CFEqual($0, host) }) == true { return true }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
        else { return false }
        _ = AXUIElementSetAttributeValue(host, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return Self.hostOfCurrentFocus().map { CFEqual($0, host) } == true
    }

    fileprivate static func hostOfCurrentFocus() -> AXUIElement? {
        guard let focused = focusedElement() else { return nil }
        return editableHost(startingAt: focused)
    }

    fileprivate static func focusedElement() -> AXUIElement? {
        element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
    }

    private static func editableHost(startingAt focused: AXUIElement) -> AXUIElement? {
        if let ancestor = element(focused, kAXEditableAncestorAttribute),
           !isSecure(ancestor) { return ancestor }
        if let ancestor = element(focused, kAXHighestEditableAncestorAttribute),
           !isSecure(ancestor) { return ancestor }

        var current: AXUIElement? = focused
        var visited = 0
        while let candidate = current, visited < 12 {
            let role = string(candidate, kAXRoleAttribute) ?? ""
            // 只认原生文本角色或明确的 AXIsEditable。"AXValue 恰好可写"不算证据，
            // 否则容器、文档视图都会被当成输入框。
            if !isSecure(candidate),
               FocusedInputSnapshot.insertableRoles.contains(role)
                || bool(candidate, kAXIsEditableAttribute) == true {
                return candidate
            }
            current = element(candidate, kAXParentAttribute)
            visited += 1
        }
        return nil
    }

    private static func selectionElement(
        focused: AXUIElement,
        host: AXUIElement
    ) -> AXUIElement {
        var current: AXUIElement? = focused
        var visited = 0
        while let candidate = current, visited < 12 {
            if selectedRange(candidate) != nil
                || string(candidate, kAXSelectedTextAttribute) != nil {
                return candidate
            }
            if CFEqual(candidate, host) { break }
            current = element(candidate, kAXParentAttribute)
            visited += 1
        }
        return host
    }

    private static func writableElement(
        focused: AXUIElement,
        host: AXUIElement
    ) -> AXUIElement? {
        var current: AXUIElement? = focused
        var visited = 0
        while let candidate = current, visited < 12 {
            if isSettable(candidate, kAXSelectedTextAttribute)
                || isSettable(candidate, kAXValueAttribute) { return candidate }
            if CFEqual(candidate, host) { break }
            current = element(candidate, kAXParentAttribute)
            visited += 1
        }
        return isSettable(host, kAXSelectedTextAttribute)
            || isSettable(host, kAXValueAttribute) ? host : nil
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        (string(element, kAXSubroleAttribute) ?? "") == "AXSecureTextField"
    }

    private static func element(_ source: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, attribute as CFString, &value) == .success,
              let value else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? Bool
    }

    fileprivate static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value
        ) == .success, let value else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    fileprivate static func setSelectedRange(_ range: CFRange, on element: AXUIElement) -> Bool {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, value
        ) == .success
    }

    fileprivate static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func characterBefore(location: Int, in element: AXUIElement) -> Character? {
        guard let text = string(element, kAXValueAttribute) else { return nil }
        let units = Array(text.utf16)
        guard location > 0, location <= units.count else { return nil }
        return String(decoding: units[..<location].suffix(8), as: UTF16.self).last
    }

    fileprivate static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element, attribute as CFString, &settable
        ) == .success else { return false }
        return settable.boolValue
    }
}

enum FocusedInputInsertionResult {
    case inserted
    case failedBeforeInsertion
    case insertedButCannotContinue
}

@MainActor
struct FocusedInputSession {
    enum Mode {
        case accessibility(
            writer: AXUIElement,
            rangeElement: AXUIElement,
            canSetSelectedText: Bool,
            canSetValue: Bool
        )
        case keyboardEvents(targetPID: pid_t)
    }

    let mode: Mode
    let focusMatches: () -> Bool
    let originalRange: CFRange?
    let startLocation: Int
    private(set) var expectedCaretLocation: Int
    /// 首次写入要替换掉的选区长度（UTF-16）。这就是"清空输入框里的问题"。
    let replacementLength: Int
    /// 被替换掉的问题原文，回滚时写回去。
    let originalSelectedText: String?
    private var insertedText = ""
    private var didReplaceSelection = false

    private var insertedUTF16Count: Int { insertedText.utf16.count }
    var insertedCharacterCount: Int { insertedText.count }
    var usesKeyboardEvents: Bool {
        if case .keyboardEvents = mode { return true }
        return false
    }

    @discardableResult
    mutating func rollback() -> Bool {
        guard focusMatches() else { return false }
        guard case .accessibility(
            let writer, let rangeElement, let canSetSelectedText, let canSetValue
        ) = mode else {
            // 键盘事件路径没有可原子验证的写入 API。宁可保留明确标注的半成品，
            // 也绝不发送猜测性退格删除用户内容。
            return false
        }
        guard let range = FocusedInputTarget.selectedRange(rangeElement),
              range.length == 0, range.location == expectedCaretLocation else { return false }
        if insertedUTF16Count == 0 { return restoreOriginalSelection(on: rangeElement) }

        if canSetValue, let current = FocusedInputTarget.string(writer, kAXValueAttribute) {
            var units = Array(current.utf16)
            if startLocation >= 0, expectedCaretLocation <= units.count,
               Array(units[startLocation..<expectedCaretLocation]) == Array(insertedText.utf16) {
                units.replaceSubrange(
                    startLocation..<expectedCaretLocation,
                    with: Array((originalSelectedText ?? "").utf16)
                )
                if AXUIElementSetAttributeValue(
                    writer,
                    kAXValueAttribute as CFString,
                    String(decoding: units, as: UTF16.self) as CFString
                ) == .success {
                    expectedCaretLocation = startLocation
                    insertedText = ""
                    _ = restoreOriginalSelection(on: rangeElement)
                    return true
                }
            }
        }

        let insertedRange = CFRange(location: startLocation, length: insertedUTF16Count)
        // 我们替换掉了用户的问题，所以回滚要把原文写回去，而不是留下一个空框。
        let restored = originalSelectedText ?? ""
        guard canSetSelectedText,
              FocusedInputTarget.setSelectedRange(insertedRange, on: rangeElement),
              FocusedInputTarget.string(writer, kAXSelectedTextAttribute) == insertedText,
              AXUIElementSetAttributeValue(
                  writer, kAXSelectedTextAttribute as CFString, restored as CFString
              ) == .success else { return false }
        expectedCaretLocation = startLocation
        insertedText = ""
        _ = restoreOriginalSelection(on: rangeElement)
        return true
    }

    private func restoreOriginalSelection(on element: AXUIElement) -> Bool {
        guard let originalRange else { return true }
        return FocusedInputTarget.setSelectedRange(originalRange, on: element)
    }

    @discardableResult
    mutating func insert(_ text: String) -> FocusedInputInsertionResult {
        guard !text.isEmpty, focusMatches() else { return .failedBeforeInsertion }
        switch mode {
        case .keyboardEvents(let targetPID):
            // 不折叠选区：首个字符自然替换掉选中的问题，输入框里只剩答案。
            guard Self.postUnicode(text, to: targetPID) else { return .failedBeforeInsertion }
            insertedText += text
            expectedCaretLocation += text.utf16.count
            return .inserted

        case .accessibility(
            let writer, let rangeElement, let canSetSelectedText, let canSetValue
        ):
            // 第一段落在选区上（替换问题），之后都是零长度光标续写。
            let expectedLength = didReplaceSelection ? 0 : replacementLength
            guard let range = FocusedInputTarget.selectedRange(rangeElement),
                  range.length == expectedLength,
                  range.location == expectedCaretLocation else {
                return .failedBeforeInsertion
            }
            if canSetSelectedText,
               AXUIElementSetAttributeValue(
                   writer, kAXSelectedTextAttribute as CFString, text as CFString
               ) == .success {
                expectedCaretLocation += text.utf16.count
                insertedText += text
                didReplaceSelection = true
                if let current = FocusedInputTarget.selectedRange(rangeElement),
                   current.length == 0, current.location == expectedCaretLocation {
                    return .inserted
                }
                guard FocusedInputTarget.setSelectedRange(
                    CFRange(location: expectedCaretLocation, length: 0), on: rangeElement
                ) else { return .insertedButCannotContinue }
                return .inserted
            }

            if canSetValue, let current = FocusedInputTarget.string(writer, kAXValueAttribute) {
                var units = Array(current.utf16)
                if expectedCaretLocation + expectedLength <= units.count {
                    if expectedLength > 0 {
                        units.removeSubrange(
                            expectedCaretLocation..<(expectedCaretLocation + expectedLength)
                        )
                    }
                    units.insert(contentsOf: text.utf16, at: expectedCaretLocation)
                    if AXUIElementSetAttributeValue(
                        writer,
                        kAXValueAttribute as CFString,
                        String(decoding: units, as: UTF16.self) as CFString
                    ) == .success {
                        expectedCaretLocation += text.utf16.count
                        insertedText += text
                        didReplaceSelection = true
                        guard FocusedInputTarget.setSelectedRange(
                            CFRange(location: expectedCaretLocation, length: 0), on: rangeElement
                        ) else { return .insertedButCannotContinue }
                        return .inserted
                    }
                }
            }
            return .failedBeforeInsertion
        }
    }

    /// 事件走和代按 Command-C 相同的 HID 通道——那条路在微信里已被证实有效，
    /// 而 `postToPid` 会绕开正常事件路由，自绘客户端可能直接忽略。
    /// 用 privateState 并清空 flags：⌘G 的物理修饰键可能还按着，绝不能让正文
    /// 变成快捷键。调用前已确认目标应用在前台。
    private static func postKey(virtualKey: CGKeyCode, to pid: pid_t) -> Bool {
        guard AXIsProcessTrusted(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(
                  keyboardEventSource: source, virtualKey: virtualKey, keyDown: true
              ), let up = CGEvent(
                  keyboardEventSource: source, virtualKey: virtualKey, keyDown: false
              ) else { return false }
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// 每个事件只带一小段 Unicode，兼容按 keyDown 处理文本的自绘控件。
    /// 不带任何修饰键，因此只会被当成文本输入，不会触发快捷键。
    private static func postUnicode(_ text: String, to pid: pid_t) -> Bool {
        guard AXIsProcessTrusted(), !text.isEmpty,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let source = CGEventSource(stateID: .privateState) else { return false }
        var remainder = text[...]
        while !remainder.isEmpty {
            let end = remainder.index(
                remainder.startIndex, offsetBy: 16, limitedBy: remainder.endIndex
            ) ?? remainder.endIndex
            let piece = String(remainder[..<end])
            guard let down = CGEvent(
                keyboardEventSource: source, virtualKey: 0, keyDown: true
            ), let up = CGEvent(
                keyboardEventSource: source, virtualKey: 0, keyDown: false
            ) else { return false }
            let units = Array(piece.utf16)
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(
                    stringLength: buffer.count, unicodeString: buffer.baseAddress
                )
                up.keyboardSetUnicodeString(
                    stringLength: buffer.count, unicodeString: buffer.baseAddress
                )
            }
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            remainder = remainder[end...]
        }
        return true
    }
}
