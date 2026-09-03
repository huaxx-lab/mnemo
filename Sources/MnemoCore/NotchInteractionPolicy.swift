import Foundation

public enum NotchInteractionPolicy {
    /// 始终存在但透明的拖拽磁吸区深度。Finder 指针在离屏幕顶边仍有一段
    /// 距离时就先进入 Mnemo，避免继续撞上 Mission Control / Space 热区。
    public static let dragCaptureDepth: CGFloat = 148

    /// Cursor polling arms the actual destination before the drag reaches it. This
    /// avoids depending on cross-application mouse-drag monitors, which may require
    /// accessibility permission and can miss the first drag update.
    public static let dragActivationMargin: CGFloat = 96

    /// 悬停展开的驻留毫秒数：指针要在刘海上**停住**这么久才展开。
    ///
    /// 数值的取舍：扫过刘海去点菜单栏的人停留远小于这个数，不会误开；
    /// 真想要展开的人停一下就触发。boring.notch 一类 notch 应用走的是
    /// 同一条路（可配置 hover delay）。
    ///
    /// 400 而不是 250：刘海正下方就是菜单栏和一排状态图标，指针经过那里
    /// 是常态而不是意图。停留门槛太低时，"去点一下电池图标"半路就会被
    /// 展开的面板挡住——多等的那 150ms 用户想要展开时几乎察觉不到，
    /// 不想展开时却挡掉了绝大多数误开。
    public static let hoverExpandDwellMilliseconds = 400

    public static func dragCaptureWidth(notchWidth: CGFloat) -> CGFloat {
        max(520, notchWidth + 320)
    }

    public struct RoutedURLs: Equatable, Sendable {
        public let files: [URL]
        public let links: [URL]

        public init(files: [URL], links: [URL]) {
            self.files = files
            self.links = links
        }
    }

    public static func route(urls: [URL]) -> RoutedURLs {
        RoutedURLs(
            files: urls.filter(\.isFileURL),
            links: urls.filter { !$0.isFileURL && ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        )
    }
}

/// 连续 Command-G 没有冷却时间：每次按键生成新 token，只有最后一次可以发布。
/// 这和检索 generation 使用同一条 latest-wins 原则，不以“每分钟几次”限频。
public struct SelectionCaptureCoordinator: Sendable, Equatable {
    public private(set) var generation = 0

    public init() {}

    public mutating func begin() -> Int {
        generation &+= 1
        return generation
    }

    public func isCurrent(_ candidate: Int) -> Bool { candidate == generation }
}

/// 主动选区抓取只接受“基线之后、不是 Mnemo 自写、且含非空文字”的观察。
/// 将这条规则做成纯函数，才能覆盖上一轮回答在下一轮 Cmd-C 等待期间写回的竞态。
public enum SelectionCaptureObservationPolicy {
    public enum Source: Sendable, Equatable {
        case accessibilitySelection
        case newPasteboardWrite
        case existingAutoCopiedSelection
        case rememberedExplicitSelection
    }

    public static func source(
        hasAccessibilitySelection: Bool,
        changeCount: Int,
        baseline: Int,
        currentWriteIsMnemoOwned: Bool,
        baselineWriteWasMnemoOwned: Bool,
        hasCurrentText: Bool,
        hasBaselineText: Bool,
        hasRememberedSelectionForApplication: Bool = false
    ) -> Source? {
        if hasAccessibilitySelection { return .accessibilitySelection }
        if changeCount != baseline,
           !currentWriteIsMnemoOwned,
           hasCurrentText {
            return .newPasteboardWrite
        }
        // 某些应用在“选中”动作发生时已经自动复制，随后收到 Command-C 不再写
        // pasteboard。显式 Command-G 可以使用这份基线文字，但 Mnemo 上一轮自动
        // 写入的回答 / 文件永远不能作为这种回退。
        if changeCount == baseline,
           !baselineWriteWasMnemoOwned,
           hasBaselineText {
            return .existingAutoCopiedSelection
        }
        // 第一轮回答会自动覆盖剪贴板，但不会改变前台应用仍保持的选区。该应用不
        // 暴露 AXSelectedText、Command-C 又不重写时，主动 Command-G 复用上次在
        // **同一前台应用**验证过的选区；没有 TTL，也不参与被动收纳。
        if hasRememberedSelectionForApplication {
            return .rememberedExplicitSelection
        }
        return nil
    }

    public static func accepts(
        changeCount: Int,
        baseline: Int,
        mnemoWriteCounts: Set<Int>,
        hasNonemptyText: Bool
    ) -> Bool {
        source(
            hasAccessibilitySelection: false,
            changeCount: changeCount,
            baseline: baseline,
            currentWriteIsMnemoOwned: mnemoWriteCounts.contains(changeCount),
            baselineWriteWasMnemoOwned: mnemoWriteCounts.contains(baseline),
            hasCurrentText: hasNonemptyText,
            hasBaselineText: hasNonemptyText
        ) != nil
    }
}

/// 预览窗的存活规则。
///
/// 预览是一个独立窗口，自带关闭键，还能被用户拖走、拉大。它不该跟着刘海的
/// 展开/收起走——用户点开一个链接的预览，正是为了对着里面的网址去别处做事；
/// 一点别的应用就把工作台和预览一起收掉，等于每看一眼都要重开一次。
public enum DetailPresentationPolicy {
    /// 预览窗在不在屏幕上。只看"有没有要预览的东西"和"是不是收纳模式"，
    /// 与工作台的开合无关。
    public static func isPresented(hasDetailItem: Bool, isStashMode: Bool) -> Bool {
        hasDetailItem && isStashMode
    }


}

/// 刘海用什么手势展开。
///
/// 默认只认点击：悬停展开对"路过"和"想展开"分不清楚，而刘海正下方恰好是
/// 菜单栏——那是指针每天要经过很多次的地方。想要免点击的人可以自己打开。
public enum NotchExpandTrigger: String, CaseIterable, Sendable, Codable {
    case click
    case hover

    public var allowsClick: Bool { self == .click }
    public var allowsHover: Bool { self == .hover }

    public var displayName: String {
        switch self {
        case .click: "点击"
        case .hover: "悬停"
        }
    }

    public var explanation: String {
        switch self {
        case .click: "点一下刘海下沿才展开。默认，不会被路过的指针误触。"
        case .hover: "指针停在刘海上约 0.4 秒就展开，不用点。"
        }
    }
}
