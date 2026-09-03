import AppKit

/// 刘海几何。
///
/// macOS 用 `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` 描述刘海两侧的可用「耳朵」，
/// 刘海本身是两者之间的空隙——系统没有直接给出刘海矩形，得自己算。
enum NotchGeometry {

    /// 带刘海的屏幕；没有则退回主屏（design 边界 F-35）。
    static var preferredScreen: NSScreen? {
        NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main
    }

    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
    }

    /// 刘海矩形（屏幕坐标，原点左下）。无刘海时给出屏幕顶部中央的等效条带，
    /// 保证功能可用——不追求视觉一致，这是明确的降级而非模拟。
    static func notchRect(on screen: NSScreen) -> CGRect {
        let f = screen.frame
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            let w: CGFloat = 220
            let h = max(screen.safeAreaInsets.top, 32)
            return CGRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
        }

        // auxiliaryTop*Area 是全局屏幕坐标，不是相对宽度。直接使用两块安全区
        // 相邻的边界才能正确处理副屏位于主屏左侧（负坐标）的情况。
        let x = left.maxX
        let maxX = right.minX
        let bottom = min(left.minY, right.minY)
        let width = max(maxX - x, 0)
        let height = max(f.maxY - bottom, screen.safeAreaInsets.top)
        return CGRect(x: x, y: f.maxY - height, width: width, height: height)
    }
}
