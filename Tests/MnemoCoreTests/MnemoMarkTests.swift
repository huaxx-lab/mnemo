import CoreGraphics
import Foundation
import Testing
@testable import MnemoCore

@Test("品牌记号是开口朝上的磁石，被吸住的圆点悬在开口里且不压住磁臂")
func mnemoMarkGeometryIsSelfConsistent() {
    // 开口朝上：两条腿的端面在圆心上方。
    #expect(MnemoMark.tipY < MnemoMark.center.y)
    #expect(MnemoMark.legLength > MnemoMark.armThickness, "腿要够长才看得出是磁石不是圆环")

    // 左右对称。
    let legs = MnemoMark.legCenterXs
    #expect(abs((legs.leading + legs.trailing) / 2 - MnemoMark.center.x) < 0.001)

    // 开口真的敞着，且比被吸住的圆点宽——圆点是"悬在开口里"，不是卡住。
    #expect(MnemoMark.mouthWidth > 0)
    #expect(MnemoMark.mouthWidth > MnemoMark.itemRadius * 2 + 40)

    // 圆点在两条腿之间，横向不与磁臂相交。
    let legInnerEdge = legs.leading + MnemoMark.armThickness / 2
    #expect(MnemoMark.itemCenter.x == MnemoMark.center.x)
    #expect(MnemoMark.itemCenter.x - MnemoMark.itemRadius > legInnerEdge)

    // 圆点在底部圆弧的内缘之上，不会糊进磁石本体。
    let distanceToArcCenter = MnemoMark.center.y - MnemoMark.itemCenter.y
    #expect(distanceToArcCenter - MnemoMark.itemRadius > 0)

    // 端面换色的那一段只覆盖腿，不会啃到底部圆弧。
    #expect(MnemoMark.tipBandLength < MnemoMark.legLength)
    #expect(MnemoMark.tipBandRect.maxY < MnemoMark.center.y)
}

@Test("记号在 macOS 安全区内留白，缩放到菜单栏尺寸也不出血")
func mnemoMarkFitsInsideSafeAreaAndMenuBar() {
    let bounds = MnemoMark.contentBounds
    let safe = CGRect(
        x: MnemoMark.macOSContentInset,
        y: MnemoMark.macOSContentInset,
        width: MnemoMark.canvas - 2 * MnemoMark.macOSContentInset,
        height: MnemoMark.canvas - 2 * MnemoMark.macOSContentInset
    )
    #expect(safe.contains(bounds), "内容必须落在 macOS 图标安全区里，四周留给系统投影")

    // 视觉重心贴近画布中心，图标不会看着偏上或偏下。
    #expect(abs(bounds.midY - MnemoMark.canvas / 2) < 24)
    #expect(abs(bounds.midX - MnemoMark.canvas / 2) < 0.001)

    // 菜单栏 18pt：同一套几何缩下去，磁臂仍有可见宽度，且不超出画布。
    let factor = MnemoMark.scale(toSide: 18)
    #expect(MnemoMark.armThickness * factor > 1.5)
    #expect(bounds.height * factor < 18)
    #expect(bounds.width * factor < 18)
}
