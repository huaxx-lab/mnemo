import CoreGraphics
import Foundation
import ImageIO
import MnemoCore
import UniformTypeIdentifiers

/// 应用图标生成器：把 `MnemoMark` 的几何渲染成三套 .iconset 与预览 PNG。
///
/// 图标和菜单栏字形共用 `MnemoMark`，所以「换个图标」不会变成两处各画一遍、
/// 慢慢对不上。运行：`swift run MnemoIconGen`，再用 iconutil 打成 .icns。
private struct Variant {
    var id: String
    var faceTop: String
    var faceBottom: String
    var armTop: String
    var armBottom: String
    var tip: String
    var item: String
    var rim: String
    var rimOpacity: CGFloat
    var sheenOpacity: CGFloat
}

private let variants: [Variant] = [
    // 暖象牙底 + 深靛磁石 + 琥珀磁极。日常浅色壁纸上最稳。
    Variant(
        id: "a-classic",
        faceTop: "FCF8F1", faceBottom: "EDE4D5",
        armTop: "27346F", armBottom: "141B3C",
        tip: "F2A33C", item: "1F2A5C",
        rim: "FFFFFF", rimOpacity: 0.72, sheenOpacity: 0.55
    ),
    // 深空底 + 青蓝渐变磁石 + 暖色磁极。彩色壁纸和深色模式下最跳。
    Variant(
        id: "b-staggered",
        faceTop: "171A22", faceBottom: "05060A",
        armTop: "3BE3C6", armBottom: "3A72F5",
        tip: "FFC15E", item: "F4F1EA",
        rim: "FFFFFF", rimOpacity: 0.16, sheenOpacity: 0.10
    ),
    // 纯黑底 + 象牙单色磁石。极简，和菜单栏模板字形长得最像。
    Variant(
        id: "c-dark",
        faceTop: "0C0D10", faceBottom: "060709",
        armTop: "F4F1EA", armBottom: "D5D0C4",
        tip: "8F8A7C", item: "F4F1EA",
        rim: "FFFFFF", rimOpacity: 0.14, sheenOpacity: 0.08
    ),
]

private let iconsetEntries: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

private func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
    var value: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&value)
    return CGColor(
        red: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: alpha
    )
}

private func verticalGradient(_ from: CGColor, _ to: CGColor) -> CGGradient? {
    CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [from, to] as CFArray,
        locations: [0, 1]
    )
}

private func fillVertical(
    _ context: CGContext,
    gradient: CGGradient?,
    from top: CGFloat,
    to bottom: CGFloat
) {
    guard let gradient else { return }
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: top),
        end: CGPoint(x: 0, y: bottom),
        options: []
    )
}

/// 在 y 向下的 1024 见方坐标系里画一版图标。
/// `castsShadow` 只作用于底板：投影一旦留到前景，磁臂和圆点周围会糊上一圈脏边。
private func drawArtwork(_ context: CGContext, variant: Variant, castsShadow: Bool) {
    let side = MnemoMark.canvas
    let face = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
        cornerWidth: MnemoMark.faceCornerRadius,
        cornerHeight: MnemoMark.faceCornerRadius,
        transform: nil
    )

    if castsShadow {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 24),
            blur: 30,
            color: color("0A1226", alpha: 0.32)
        )
        context.setFillColor(color(variant.faceBottom))
        context.addPath(face)
        context.fillPath()
        context.restoreGState()
    }

    context.saveGState()
    context.addPath(face)
    context.clip()
    fillVertical(
        context,
        gradient: verticalGradient(color(variant.faceTop), color(variant.faceBottom)),
        from: 0,
        to: side
    )

    // 顶部一层很淡的高光，让底板不是一块死色。
    if variant.sheenOpacity > 0 {
        fillVertical(
            context,
            gradient: verticalGradient(
                color("FFFFFF", alpha: variant.sheenOpacity),
                color("FFFFFF", alpha: 0)
            ),
            from: 0,
            to: side * 0.52
        )
    }

    // 磁石本体：平口收尾的马蹄形，开口朝上。
    let body = MnemoMark.bodyPath().copy(
        strokingWithWidth: MnemoMark.armThickness,
        lineCap: .butt,
        lineJoin: .round,
        miterLimit: 10
    )
    context.saveGState()
    context.addPath(body)
    context.clip()
    let bodyBox = body.boundingBox
    fillVertical(
        context,
        gradient: verticalGradient(color(variant.armTop), color(variant.armBottom)),
        from: bodyBox.minY,
        to: bodyBox.maxY
    )
    // 两个磁极端面换色：磁石的读感全靠这一截。
    context.setFillColor(color(variant.tip))
    context.fill(MnemoMark.tipBandRect)
    context.restoreGState()

    // 正被吸住的那一件东西。
    context.setFillColor(color(variant.item))
    context.addPath(MnemoMark.itemPath())
    context.fillPath()
    context.restoreGState()

    // 内描边：给底板一道边，缩到 16pt 时轮廓不糊在壁纸里。
    let rimInset: CGFloat = 3
    let rim = CGPath(
        roundedRect: CGRect(x: rimInset, y: rimInset, width: side - 2 * rimInset, height: side - 2 * rimInset),
        cornerWidth: MnemoMark.faceCornerRadius - rimInset,
        cornerHeight: MnemoMark.faceCornerRadius - rimInset,
        transform: nil
    )
    context.setStrokeColor(color(variant.rim, alpha: variant.rimOpacity))
    context.setLineWidth(6)
    context.addPath(rim)
    context.strokePath()
}

private func render(variant: Variant, pixels: Int, inset: Bool) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    // 统一成 y 向下的 1024 画布，和 MnemoMark / SVG 同一口径。
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: 1, y: -1)
    context.scaleBy(x: CGFloat(pixels) / MnemoMark.canvas, y: CGFloat(pixels) / MnemoMark.canvas)

    if inset {
        // macOS 应用图标：内容缩进安全区，四周留给系统投影。
        let content = MnemoMark.canvas - 2 * MnemoMark.macOSContentInset
        let scale = content / MnemoMark.canvas
        context.translateBy(x: MnemoMark.macOSContentInset, y: MnemoMark.macOSContentInset)
        context.scaleBy(x: scale, y: scale)
    }
    drawArtwork(context, variant: variant, castsShadow: inset)
    return context.makeImage()
}

private func write(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconRoot = root.appending(path: "icon")
var written = 0

for variant in variants {
    let iconset = iconRoot.appending(path: "build/\(variant.id).iconset")
    for entry in iconsetEntries {
        guard let image = render(variant: variant, pixels: entry.pixels, inset: true) else {
            FileHandle.standardError.write(Data("渲染失败：\(variant.id) \(entry.name)\n".utf8))
            exit(1)
        }
        try write(image, to: iconset.appending(path: "\(entry.name).png"))
        written += 1
    }
    // 预览图：一张纯画面、一张 macOS 版式，供文档和图标对比页使用。
    if let art = render(variant: variant, pixels: 1024, inset: false) {
        try write(art, to: iconRoot.appending(path: "mnemo-\(variant.id).png"))
        written += 1
    }
    if let macOS = render(variant: variant, pixels: 1024, inset: true) {
        try write(macOS, to: iconRoot.appending(path: "mnemo-\(variant.id)-macos.png"))
        written += 1
    }
}

print("已生成 \(written) 张 PNG，覆盖 \(variants.count) 套变体")
