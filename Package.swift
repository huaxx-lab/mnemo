// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mnemo",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MnemoCore", targets: ["MnemoCore"]),
        .library(name: "MnemoStore", targets: ["MnemoStore"]),
        .executable(name: "Mnemo", targets: ["MnemoApp"]),
    ],
    dependencies: [
        // HTML 解析。链接要能被自然语言检索，就得先把网页正文取出来，
        // 而写一个正确的 HTML 解析器是别人已经做好且做得比我们好的事。
        //
        // 选它不选 readability 类的封装：SwiftSoup 自身零外部依赖、MIT、
        // 仍在维护；而现成的 Swift 版 Readability 移植把 SwiftSoup 钉在
        // branch 上，分支依赖会让构建在我们不知情时变化。正文抽取那层规则
        // 只有几十行，自己写反而可控。
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.13.0"),
        // OOXML（docx/xlsx/pptx）本质都是 zip 包 XML。解析用 ZIPFoundation
        //（WeTransfer 维护，Swift 生态的事实标准 zip 库），XML 用 Foundation
        // 自带的 XMLParser——不写自己的解压器，也不引入 CoreXLSX 那种多年
        // 未动的封装。
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20"),
    ],
    targets: [
        // 领域层：不感知 SwiftData、AppKit、任何具体存储。
        // SwiftSoup 是纯 Swift 的 HTML 解析器，不违反这条——网页正文抽取
        // 是"从一段文本里取出可检索内容"，和 OCR、PDF 取文同属领域规则，
        // 放在这里才能被评测语料直接覆盖。网络请求仍然只在 App 层。
        .target(
            name: "MnemoCore",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        // 持久化：ItemStore 的 SwiftData 实现
        .target(name: "MnemoStore", dependencies: ["MnemoCore"]),
        // 界面与刘海窗口
        .executableTarget(
            name: "MnemoApp",
            dependencies: [
                "MnemoCore",
                "MnemoStore",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            resources: [.process("Resources")]
        ),
        // 图标生成器：和菜单栏字形共用 MnemoCore 里的记号几何，避免两处各画一版
        .executableTarget(name: "MnemoIconGen", dependencies: ["MnemoCore"]),
        .testTarget(
            name: "MnemoCoreTests",
            dependencies: [
                "MnemoCore",
                "MnemoStore",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
    ]
)
