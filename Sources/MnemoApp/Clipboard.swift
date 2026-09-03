import AppKit
import MnemoCore
import UniformTypeIdentifiers

/// 剪贴板读写与「复制选中内容」。
@MainActor
enum Clipboard {

    /// Mnemo 自己写入产生的所有 changeCount。
    ///
    /// 只记"最后一次"是不够的：一次写入里 `clearContents` 和 `declareTypes`
    /// 都会让 changeCount 自增，中间那个值就会被监听器当成"别的应用改了剪贴板"，
    /// 于是自己复制出去的东西又被自己收了一遍。
    private static var applicationWriteChangeCounts: Set<Int> = []

    private static func markSelfWrite(_ pasteboard: NSPasteboard) {
        applicationWriteChangeCounts.insert(pasteboard.changeCount)
        // 只留最近几个，别无限长。
        if applicationWriteChangeCounts.count > 16 {
            applicationWriteChangeCounts = Set(applicationWriteChangeCounts.sorted().suffix(8))
        }
    }

    enum Payload {
        case text(String)
        case files([URL])
        case image(Data, fileExtension: String)
    }

    /// 读取当前剪贴板。顺序有讲究：文件优先于文本，
    /// 否则从访达复制的文件会被当成路径字符串 Pin 进来。
    static func read() -> Payload? {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        if let png = pb.data(forType: .png) {
            return .image(png, fileExtension: "png")
        }
        if let tiff = pb.data(forType: .tiff) {
            return .image(tiff, fileExtension: "tiff")
        }
        if let s = pb.string(forType: .string), !s.isEmpty {
            return .text(s)
        }
        return nil
    }

    /// 系统给"通用剪贴板"内容打的私有标记。
    ///
    /// iPhone / iPad 复制之后，Mac 这边的 `changeCount` 会**先**加一，真正的
    /// 字节还在从对端传。此时读到的是一个空壳：`read()` 返回 nil，或者只拿到
    /// 类型没有数据。旧实现在这一拍就放弃了，于是"手机复制的东西 Mac 收不到"。
    private static let remoteClipboardType = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")

    /// 当前剪贴板内容是不是从别的苹果设备同步过来的。
    static func isRemoteContent() -> Bool {
        let pasteboard = NSPasteboard.general
        if pasteboard.types?.contains(remoteClipboardType) == true { return true }
        return pasteboard.pasteboardItems?.contains { $0.types.contains(remoteClipboardType) } == true
    }

    /// 读取剪贴板，并给通用剪贴板留出到达时间。
    ///
    /// 本机复制的内容第一拍就在，直接返回；只有当系统标记了"这是远端内容"
    /// 而数据还没到时才轮询等待。等待期间一旦 `changeCount` 再变，说明用户
    /// 又复制了别的东西，立刻放弃这一轮——不能把上一次的内容记到这一次头上。
    ///
    /// - Parameter changeCount: 触发这次读取的那个 changeCount。
    /// - Returns: 内容，以及它是否来自其他设备。
    static func readAwaitingRemoteArrival(
        changeCount: Int,
        timeout: Duration = .seconds(6)
    ) async -> (payload: Payload, isRemote: Bool)? {
        let pasteboard = NSPasteboard.general
        var isRemote = isRemoteContent()
        if let payload = read() { return (payload, isRemote) }
        // 不是远端内容却读不出东西，就是真的没有可收的东西（例如只有私有类型）。
        guard isRemote else { return nil }

        let step = Duration.milliseconds(200)
        var waited = Duration.zero
        while waited < timeout {
            try? await Task.sleep(for: step)
            waited += step
            guard pasteboard.changeCount == changeCount else { return nil }
            isRemote = isRemoteContent() || isRemote
            if let payload = read() { return (payload, isRemote) }
        }
        return nil
    }

    @discardableResult
    static func write(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        markSelfWrite(pb)
        let wrote = pb.setString(text, forType: .string)
        markSelfWrite(pb)
        return wrote
    }

    /// 旧的路径数组类型。微信、QQ 这类接收方到今天仍然只认它；
    /// 只写 public.file-url 的话，粘过去什么都不会发生。
    private static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    /// 复制一个文件。
    ///
    /// 两种表示，接收方各认各的：
    /// - `public.file-url`：现代 API 走这条；
    /// - `NSFilenamesPboardType`：微信、QQ 等只认这条旧的。
    ///
    /// **不写纯文本路径**。写了之后偏好文本的接收方会优先取它，粘出来是
    /// 一串 `/Users/…/xxx.pdf` 而不是一个文件——这正是"复制出来是个地址"的原因。
    @discardableResult
    static func write(fileAt url: URL) -> Bool {
        // 只写一个路径字符串永远"成功"，哪怕那个文件谁都读不出来——用户看到的
        // 就是对号亮了、粘贴却什么都没有。先确认真能读到字节。
        guard DroppedSourceTrust.isReadable(url) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        markSelfWrite(pb)
        // 图片再多写一份位图数据：聊天输入框、富文本编辑器这类接收方只认
        // 图片数据，给它们一个文件引用是粘不进去的。
        let bitmap = imagePayload(for: url)
        var types: [NSPasteboard.PasteboardType] = [.fileURL, filenamesType]
        if bitmap != nil { types.append(.png) }
        pb.declareTypes(types, owner: nil)
        markSelfWrite(pb)
        let wroteURL = pb.setString(url.absoluteString, forType: .fileURL)
        let wroteFilenames = pb.setPropertyList([url.path], forType: filenamesType)
        if let bitmap { pb.setData(bitmap, forType: .png) }
        markSelfWrite(pb)
        return wroteURL && wroteFilenames
    }

    /// 小体积图片转成 PNG 一并放上剪贴板；大图只给文件引用，避免几十 MB
    /// 的位图卡住每一次复制。
    private static func imagePayload(for url: URL) -> Data? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 12 * 1024 * 1024,
              let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// 一次主动选区抓取。只把**实际观察到**的最终 changeCount 登记为自写；旧实现
    /// 预先猜 `base...base+3`，连续触发时这些未来数字会撞上下一次真实复制，表现为
    /// 第二次 Command-G 被频率限制。这里没有频率阈值，每次按键都有独立 token。
    struct SelectionCapture: Sendable, Equatable {
        var changeCountBeforeCopy: Int
        var textBeforeCopy: String?
        var baselineWasMnemoOwned: Bool
    }

    static func beginSelectionCapture() -> SelectionCapture {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SelectionCapture(
            changeCountBeforeCopy: count,
            textBeforeCopy: text?.isEmpty == false ? text : nil,
            baselineWasMnemoOwned: applicationWriteChangeCounts.contains(count)
        )
    }

    /// 读取前台应用刚写入的**新**文字，并精确登记这一次 changeCount。
    ///
    /// 如果目标应用没有更新剪贴板（无选区、复制失败），绝不能拿上次 Mnemo 自动
    /// 写入的回答再跑一遍。返回 nil 让调用方给出明确反馈。
    static func finishSelectionCapture(
        _ capture: SelectionCapture,
        allowsBaselineFallback: Bool = false,
        rememberedText: String? = nil
    ) -> (text: String, changeCount: Int, source: SelectionCaptureObservationPolicy.Source)? {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = SelectionCaptureObservationPolicy.source(
            hasAccessibilitySelection: false,
            changeCount: changeCount,
            baseline: capture.changeCountBeforeCopy,
            currentWriteIsMnemoOwned: applicationWriteChangeCounts.contains(changeCount),
            baselineWriteWasMnemoOwned: capture.baselineWasMnemoOwned,
            hasCurrentText: text?.isEmpty == false,
            hasBaselineText: allowsBaselineFallback && capture.textBeforeCopy?.isEmpty == false,
            hasRememberedSelectionForApplication: allowsBaselineFallback
                && rememberedText?.isEmpty == false
        )
        guard let source else { return nil }
        let selectedText: String
        switch source {
        case .accessibilitySelection:
            return nil // 由 `selectedTextFromFrontmostApp()` 的直接路径处理。
        case .newPasteboardWrite:
            guard let text else { return nil }
            selectedText = text
            applicationWriteChangeCounts.insert(changeCount)
        case .existingAutoCopiedSelection:
            guard let baseline = capture.textBeforeCopy else { return nil }
            selectedText = baseline
            // 这份值由外部应用在选择时写入，不伪装成 Mnemo 自写；监控器的
            // `lastPasteboardChangeCount` 会同步，避免重复收纳。
        case .rememberedExplicitSelection:
            guard let rememberedText else { return nil }
            selectedText = rememberedText
        }
        if applicationWriteChangeCounts.count > 16 {
            applicationWriteChangeCounts = Set(applicationWriteChangeCounts.sorted().suffix(8))
        }
        return (selectedText, changeCount, source)
    }

    /// 优先从辅助功能树直接读取真正的当前选区，不改动系统剪贴板。
    /// 不支持该属性的应用返回 nil，再走 Command-C / 自动复制回退。
    static func selectedTextFromFrontmostApp() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue else { return nil }
        let focused = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success,
              let text = selectedValue as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 这次剪贴板变化是不是 Mnemo 自己造成的。
    /// 是的话既不入库，也不触发场景识别——只有别的应用的复制才算数。
    static func wasLastChangeWrittenByMnemo(_ changeCount: Int) -> Bool {
        applicationWriteChangeCounts.contains(changeCount)
    }

    /// 向前台应用发一次 Command-C，再读剪贴板。
    ///
    /// 需要「辅助功能」权限——这是系统的硬性要求，无法绕开。
    /// 未授权时返回 nil，由调用方提示，而不是静默失败。
    static func copySelectionFromFrontmostApp() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let src = CGEventSource(stateID: .combinedSessionState)
        let cDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true)   // C
        let cUp = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        cDown?.flags = .maskCommand
        cUp?.flags = .maskCommand
        cDown?.post(tap: .cghidEventTap)
        cUp?.post(tap: .cghidEventTap)
        return true
    }

    /// 引导用户授权辅助功能。只在用户主动用了需要它的功能时才弹。
    static func promptForAccessibility() {
        // 使用公开键名避免 Swift 6 把 C 全局变量判为共享可变状态。
        let opts = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }
}
