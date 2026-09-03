import AppKit

private extension NSPanel {
    func configureNotchSurface(
        level: NSWindow.Level,
        shadow: Bool,
        ignoresMouse: Bool = false
    ) {
        isFloatingPanel = true
        // 面板底色是固定的近黑，控件却跟随系统外观取色：浅色模式下
        // NSColor.textColor 是黑的，输入框里打的字直接看不见。把面板本身
        // 钉成深色外观，AppKit 控件的取色就跟着对了。
        appearance = NSAppearance(named: .darkAqua)
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = shadow
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = ignoresMouse
        animationBehavior = .none
        isReleasedWhenClosed = false
    }
}

/// Fixed click anchor around the physical notch. It never resizes.
final class NotchAnchorPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureNotchSurface(
            level: NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4),
            shadow: false
        )
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Stable transparent drag destination. It hosts no SwiftUI content and never resizes.
final class NotchDragReceiverPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureNotchSurface(
            level: NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3),
            shadow: false
        )
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class NotchWorkspacePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        configureNotchSurface(
            level: NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2),
            shadow: false
        )
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Detached detail and editor window below the workspace.
/// 详情窗被用户摆到哪、拉成多大。
///
/// 只存尺寸是不够的：窗口每次重新投影都会被摆回刘海正下方，于是"能拖到任意
/// 位置"实际上拖完就弹回去。位置和尺寸一起记，才是用户以为的那个行为。
enum DetailPanelFrame {
    private static let key = "Pinland.detailPanelFrame"

    static func save(_ frame: NSRect) {
        UserDefaults.standard.set(
            ["x": frame.origin.x, "y": frame.origin.y, "w": frame.width, "h": frame.height],
            forKey: key
        )
    }

    /// 只在这块 frame 仍然落在某个屏幕上时才复用；换了显示器就重新锚定。
    static func load() -> NSRect? {
        guard let saved = UserDefaults.standard.dictionary(forKey: key),
              let x = (saved["x"] as? NSNumber)?.doubleValue,
              let y = (saved["y"] as? NSNumber)?.doubleValue,
              let w = (saved["w"] as? NSNumber)?.doubleValue,
              let h = (saved["h"] as? NSNumber)?.doubleValue else { return nil }
        let frame = NSRect(x: x, y: y, width: w, height: h)
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else {
            return nil
        }
        return frame
    }
}

final class NotchDetailPanel: NSPanel {
    static let sizeDefaultsKey = "Pinland.detailPanelSize"
    static let minimumSize = CGSize(width: 460, height: 260)

    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            // PDF 预览、问答回答、提问框和动作栏要共处一室，固定 272pt 根本
            // 放不下——内容一定会被裁掉。让用户自己拉。
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        // 详情窗是唯一开过系统投影的面板，而它就挂在刘海正下方：那圈投影落在
        // 桌面上看着像"刘海下面多了一道黑边"。轮廓由 16pt 圆角和描边自己交代，
        // 不需要再靠阴影从背景里抬起来。
        configureNotchSurface(
            level: NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1),
            shadow: false
        )
        isMovable = true
        // 无边框窗口没有标题栏可抓。不允许拖背景的话，用户根本没有办法挪动它。
        isMovableByWindowBackground = true
        minSize = Self.minimumSize
        delegate = sizeKeeper
    }

    /// 记住用户拉过的尺寸，下次打开还是那么大。
    private let sizeKeeper = DetailPanelSizeKeeper()

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private final class DetailPanelSizeKeeper: NSObject, NSWindowDelegate {
    /// 拉过、挪过都记下来，下次打开还是那个样子、那个位置。
    func windowDidEndLiveResize(_ notification: Notification) { remember(notification) }
    func windowDidMove(_ notification: Notification) { remember(notification) }

    private func remember(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.isVisible else { return }
        DetailPanelFrame.save(window.frame)
        UserDefaults.standard.set(
            ["w": window.frame.width, "h": window.frame.height],
            forKey: NotchDetailPanel.sizeDefaultsKey
        )
    }
}
