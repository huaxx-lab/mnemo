import CoreGraphics
import Foundation

/// 收起态刘海的视觉尺寸与交互分区。
///
/// 坐标使用从面板左上角开始的 top-down 坐标。窗口、SwiftUI 根视图与 AppKit
/// 命中测试必须共用这一个结果；否则列表已经长高而窗口还停在旧尺寸时，第一行会
/// 被裁进物理刘海，或者复制按钮落进“展开”热区。
public struct NotchAnchorLayoutMetrics: Equatable, Sendable {
    public var notchSize: CGSize
    public var wingWidth: CGFloat
    public var clickLipHeight: CGFloat
    public var suggestionRowHeight: CGFloat
    public var suggestionListPadding: CGFloat
    public var suggestionCount: Int
    /// 推荐列表的显式宽度。不能让 SwiftUI 内容自己把抽屉撑宽，否则视觉上的
    /// 复制图标会跑到 AppKit 共享 metrics 的命中框外，看得到却点不到。
    public var suggestionListWidth: CGFloat
    /// 推荐 Agent 的解释答案等自定义内容。宽内容只在菜单栏下方展开；顶部刘海
    /// 状态带仍保持克制宽度，不覆盖右侧系统图标。
    public var supplementalContentSize: CGSize
    /// 补充正文底部有几个按钮。
    ///
    /// 锚点面板永远不是 key window，SwiftUI 的 Button 在别的应用在前台时
    /// 收不到那一下点击——推荐行早就因此改成由 AppKit 按 metrics 命中。
    /// 待办候选卡和提醒卡各有两个按钮，同样必须在这里算出框来。
    public var supplementalActionCount: Int

    public init(
        notchSize: CGSize,
        wingWidth: CGFloat,
        clickLipHeight: CGFloat,
        suggestionRowHeight: CGFloat,
        suggestionListPadding: CGFloat,
        suggestionCount: Int,
        suggestionListWidth: CGFloat = 0,
        supplementalContentSize: CGSize = .zero,
        supplementalActionCount: Int = 0
    ) {
        self.notchSize = notchSize
        self.wingWidth = max(0, wingWidth)
        self.clickLipHeight = max(0, clickLipHeight)
        self.suggestionRowHeight = max(0, suggestionRowHeight)
        self.suggestionListPadding = max(0, suggestionListPadding)
        self.suggestionCount = max(0, suggestionCount)
        self.suggestionListWidth = max(0, suggestionListWidth)
        self.supplementalContentSize = CGSize(
            width: max(0, supplementalContentSize.width),
            height: max(0, supplementalContentSize.height)
        )
        self.supplementalActionCount = max(0, supplementalActionCount)
    }

    /// 按钮带的内边距与高度。SwiftUI 卡片按同样的数字排版，两边共用一套常量。
    public static let supplementalActionInset: CGFloat = 10
    public static let supplementalActionHeight: CGFloat = 24
    public static let supplementalActionSpacing: CGFloat = 8

    public var suggestionListHeight: CGFloat {
        // 每条推荐都在展开唇下面占一行整宽。塞回刘海两翼看着省地方，实际只剩
        // 五十来点放标题——图标和对号都在，唯独看不出推荐的是哪一条。
        guard suggestionCount >= 1 else { return 0 }
        return CGFloat(suggestionCount) * suggestionRowHeight + suggestionListPadding * 2
    }

    public var panelSize: CGSize {
        CGSize(
            width: max(
                notchSize.width + wingWidth * 2,
                suggestionListWidth,
                supplementalContentSize.width
            ),
            height: notchSize.height + clickLipHeight + suggestionListHeight
                + supplementalContentSize.height
        )
    }

    /// 真正能点到的展开唇，只在物理刘海正下方；不会覆盖推荐按钮或两侧菜单栏。
    public var openRegion: CGRect {
        let statusWidth = notchSize.width + wingWidth * 2
        let statusOriginX = (panelSize.width - statusWidth) / 2
        return CGRect(
            x: statusOriginX + wingWidth,
            y: notchSize.height,
            width: notchSize.width,
            height: clickLipHeight
        )
    }

    /// 右翼那一格。有推荐时它整块就是"关闭推荐"，没有别的控件挤在里面。
    public var trailingWingRegion: CGRect {
        let statusWidth = notchSize.width + wingWidth * 2
        let statusOriginX = (panelSize.width - statusWidth) / 2
        return CGRect(
            x: statusOriginX + wingWidth + notchSize.width,
            y: 0,
            width: wingWidth,
            height: notchSize.height
        )
    }

    /// 回答 / 其他补充正文所在区域。外部点击判定和宿主命中测试共用它，不能再
    /// 各自在 AppKit 里重算一次，否则回答边缘会被误判成面板外。
    public var supplementalContentFrame: CGRect? {
        guard supplementalContentSize.width > 0, supplementalContentSize.height > 0 else {
            return nil
        }
        return CGRect(
            x: (panelSize.width - supplementalContentSize.width) / 2,
            y: notchSize.height + clickLipHeight + suggestionListHeight,
            width: supplementalContentSize.width,
            height: supplementalContentSize.height
        )
    }

    /// 补充卡右端那一排小圆按钮的命中框，从左到右。
    ///
    /// 是右端两个小方块，不是底部一整条：这张卡只在"拿不准"时出现，
    /// 出现频率必须低、占位必须小。一个对号一个叉就够了——排成两个带文字的
    /// 大按钮反而像在强调这件事很重要，而它多数时候并不重要。
    public var supplementalActionFrames: [CGRect] {
        guard supplementalActionCount > 0, let frame = supplementalContentFrame else { return [] }
        let side = Self.supplementalActionHeight
        let spacing = Self.supplementalActionSpacing
        let count = CGFloat(supplementalActionCount)
        let total = side * count + spacing * (count - 1)
        let originX = frame.maxX - Self.supplementalActionInset - total
        guard originX >= frame.minX else { return [] }
        let y = frame.midY - side / 2
        return (0..<supplementalActionCount).map { index in
            CGRect(
                x: originX + (side + spacing) * CGFloat(index),
                y: y,
                width: side,
                height: side
            )
        }
    }

    /// 推荐行一定从点击唇下方开始，绝不与展开热区相交。
    public var suggestionRowFrames: [CGRect] {
        guard suggestionCount >= 1 else { return [] }
        let width = max(0, panelSize.width - suggestionListPadding * 2)
        let firstY = notchSize.height + clickLipHeight + suggestionListPadding
        return (0..<suggestionCount).map { index in
            CGRect(
                x: suggestionListPadding,
                y: firstY + CGFloat(index) * suggestionRowHeight,
                width: width,
                height: suggestionRowHeight
            )
        }
    }
}
