import CoreGraphics
import Foundation

/// Mnemo 的品牌记号：开口朝上的磁石，正被吸住的那一件东西悬在开口里。
///
/// 旧图标是「白底 + 刘海胶囊 + 三张卡片」：形体靠三根横条识别，缩到 16pt 只剩
/// 几根分不清的竖线，和别的效率类应用也撞形。这一版换成单一闭合轮廓——马蹄形
/// 磁石，开口正对刘海方向，开口里悬着一颗被吸住的圆点。它同时说清两件事：
/// 东西被吸进来存着，按一下又原样交回。
///
/// 中途试过「缺口朝上的圆环 + 环心圆点」，缩小后与系统电源符号几乎同形，
/// 因此改成马蹄形并把圆点移到开口里：轮廓不对称，一眼能认出不是电源键。
///
/// 坐标系是 y 向下的 1024 见方画布（SVG / CGBitmapContext 同一口径）。
public enum MnemoMark {
    public static let canvas: CGFloat = 1024
    /// 圆角方形底板。
    public static let faceCornerRadius: CGFloat = 224
    /// macOS 应用图标的内容安全区：1024 画布里内容只占 824，四周留给系统投影。
    public static let macOSContentInset: CGFloat = 100

    /// 马蹄底部圆弧的圆心。两条腿从这里垂直向上延伸到 `tipY`。
    public static let center = CGPoint(x: 512, y: 530)
    /// 磁石臂的中线半径；描边按 `armThickness` 向两侧展开。
    public static let armRadius: CGFloat = 262
    public static let armThickness: CGFloat = 148
    /// 两条腿顶端（也就是磁极端面）的 y。平口收尾，不用圆头。
    public static let tipY: CGFloat = 195
    /// 端面那一截换色，磁极的读感全靠它。
    public static let tipBandLength: CGFloat = 148

    public static let itemCenter = CGPoint(x: 512, y: 267)
    public static let itemRadius: CGFloat = 108

    public static var armOuterRadius: CGFloat { armRadius + armThickness / 2 }
    public static var armInnerRadius: CGFloat { armRadius - armThickness / 2 }
    /// 两条腿内侧之间的净宽度，也就是开口的宽度。
    public static var mouthWidth: CGFloat { 2 * armRadius - armThickness }
    public static var legLength: CGFloat { center.y - tipY }

    /// 左右腿中线的 x。
    public static var legCenterXs: (leading: CGFloat, trailing: CGFloat) {
        (center.x - armRadius, center.x + armRadius)
    }

    /// 记号的整体外接框：上到被吸住的圆点，下到马蹄底，用来检查画布留白。
    public static var contentBounds: CGRect {
        let top = min(tipY, itemCenter.y - itemRadius)
        let bottom = center.y + armOuterRadius
        return CGRect(
            x: center.x - armOuterRadius,
            y: top,
            width: 2 * armOuterRadius,
            height: bottom - top
        )
    }

    /// 磁石的中线路径：左腿向下、底部半圆、右腿向上。
    /// 调用方用 `armThickness` 描边，平口线帽、圆角连接。
    public static func bodyPath() -> CGPath {
        let path = CGMutablePath()
        let legs = legCenterXs
        path.move(to: CGPoint(x: legs.leading, y: tipY))
        path.addLine(to: CGPoint(x: legs.leading, y: center.y))
        // 角度朝 +y 增大，而画布 y 向下，所以 90° 才是底部：必须从 180° 递减到 0°
        // （clockwise: true）才走底边。写成递增会经过 270°，弧顶朝上、开口朝下。
        path.addArc(
            center: center,
            radius: armRadius,
            startAngle: .pi,
            endAngle: 0,
            clockwise: true
        )
        path.addLine(to: CGPoint(x: legs.trailing, y: tipY))
        return path
    }

    /// 端面换色时的裁剪区域。调用方先把描边后的磁石设为裁剪区，再填这一块。
    public static var tipBandRect: CGRect {
        CGRect(
            x: center.x - armOuterRadius,
            y: tipY,
            width: 2 * armOuterRadius,
            height: tipBandLength
        )
    }

    public static func itemPath() -> CGPath {
        CGPath(
            ellipseIn: CGRect(
                x: itemCenter.x - itemRadius,
                y: itemCenter.y - itemRadius,
                width: itemRadius * 2,
                height: itemRadius * 2
            ),
            transform: nil
        )
    }

    /// 把 1024 画布上的长度换算到任意边长的目标画布。
    public static func scale(toSide side: CGFloat) -> CGFloat { side / canvas }
}
