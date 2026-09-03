import AppKit
import Carbon.HIToolbox

/// 全局快捷键。
///
/// 用 Carbon 的 `RegisterEventHotKey` 而不是 `NSEvent` 全局监听：
/// 前者不需要辅助功能权限，注册即生效；后者要用户先去系统设置里授权。
/// 对「按一下就 Pin」这种要求零摩擦的动作，权限弹窗本身就是失败。
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var installed = false
    private var nextID: UInt32 = 1

    private init() {}

    /// - Parameters:
    ///   - key: `kVK_ANSI_*` 虚拟键码
    ///   - modifiers: `cmdKey` / `controlKey` / `optionKey` / `shiftKey` 的按位或
    @discardableResult
    func register(key: Int, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x504C4E44), id: id)  // 'PLND'
        let status = RegisterEventHotKey(UInt32(key), modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return false }
        handlers[id] = action
        refs.append(ref)
        return true
    }

    func unregisterAll() {
        for r in refs { if let r { UnregisterEventHotKey(r) } }
        refs.removeAll()
        handlers.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hit = id.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.handlers[hit]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
