# Dev：Mnemo 新版本

## 1. 环境搭建

### 1.1 实际环境

| 项 | 值 | 说明 |
|----|----|------|
| 系统 | macOS 27.0（26A5421a） | 高于 prd 声明的最低 macOS 26 |
| Swift | 6.4（swiftlang-6.4.0.33.1） | — |
| SDK | MacOSX27.0.sdk | — |
| Xcode | 27.0 beta（27A5228h），位于 `/Applications/Xcode-beta.app` | 已安装 |
| 工具链 Swift | 6.4（swiftlang-6.4.0.27.1） | 与 CLT 的 6.4.0.33.1 略有差异，行为一致 |
| 测试框架 | swift-testing（`import Testing`） | — |

### 1.2 与需求的偏差：xcode-select 未全局切换

Xcode 已安装且可用，`xcodebuild -version` 返回 `Xcode 27.0 Build version 27A5228h`，
SwiftData 的 `@Model` 宏实测可编译可运行。

**唯一残留偏差**：`xcode-select -p` 全局仍指向 `/Library/Developer/CommandLineTools`，
因为切换需要 `sudo` 且当前会话拿不到终端输入密码。两种解法任选其一：

```
sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer   # 一次性全局切换
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer   # 逐会话覆盖，无需 sudo
```

在切换或覆盖之前，`swift build` 会退回 CLT 工具链，此时 SwiftData 不可用
（CLT 的 `plugins/` 下没有 `libSwiftDataMacros.dylib`，只有 `libObservationMacros` 与 `libSwiftMacros`）。

### 1.3 构建与测试

```
swift build
swift test --scratch-path <项目外目录>
```

完整命令：

```
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift test --scratch-path <项目外目录>
```

`--scratch-path` 指向项目外是必须的：项目位于 `~/Desktop` 下，该目录的文件带扩展属性，
`codesign` 会以 `resource fork, Finder information, or similar detritus not allowed` 失败。
若必须在原地构建，先执行 `xattr -cr .`。

本项目当前直接依赖 Xcode 提供的 SwiftData 宏，不再维护 CLT 专用编译补丁。开发和 CI 都必须显式选择完整 Xcode 工具链。

---

## 2. 代码结构总览

```
mnemo/
├── Package.swift                       # SwiftPM 模块、资源与 macOS 26 最低版本
├── .gitignore                          # 拦截 *.env 等一切凭据形态
├── Sources/MnemoCore/
│   ├── Item.swift                      # 条目模型、持有方式、状态机
│   ├── ItemStore.swift                 # 持久化协议与内存实现
│   ├── Library.swift                   # 条目入库、编辑、回收与查询
│   ├── FocusTimer.swift                # 绝对时间戳专注计时
│   ├── AIProviderTypes.swift           # 供应商、模型与功能路由
│   ├── ModelCatalog.swift              # models.dev 解析与原子快照
│   ├── LibraryArchive.swift            # 版本化整库归档
│   ├── VaultError.swift                # 存储层错误与对账报告
│   └── FileVault.swift                 # 引用优先、副本去重与对账
├── Sources/MnemoStore/
│   └── SwiftDataItemStore.swift        # SwiftData 条目持久化
├── Sources/MnemoApp/
│   ├── AppModel.swift                  # 面板、队列、文件生命周期与计时状态机
│   ├── NotchRootView.swift             # 三态刘海外壳、独立详情与工作台
│   ├── DragSupport.swift               # 原生拖出、拖拽接收与明确展开命中
│   ├── ProviderSettings.swift          # Keychain、模型刷新、调用路由与成本
│   ├── SemanticIndexCoordinator.swift  # OCR、分块、索引与语义检索
│   ├── NotchGeometry.swift             # 多屏刘海几何与无刘海降级
│   └── main.swift                      # 窗口生命周期、点击关闭、快捷键
├── Tests/MnemoCoreTests/
│   ├── FileVaultTests.swift            # FileVault 边界用例
│   ├── LibraryTests.swift              # Library 与条目元数据用例
│   ├── AIProviderTests.swift           # 方言、目录、维度、隐私与场景
│   └── LibraryArchiveTests.swift       # 整库导入导出
├── scripts/
│   └── verify-providers.sh             # 供应商连通性与 embedding 维度探测
├── icon/                               # 图标资产与生成脚本
└── docs/                               # 六份规范文档与页面生成脚本
```

---

## 3. 接口说明

### Item.swift

#### `enum ItemKind: String, Codable, Sendable, CaseIterable`
`text` / `image` / `pdf` / `link` / `file` / `binary`。UTI 判定失败时归入 `binary`，仍然入库。

#### `enum Holding: Sendable, Equatable, Codable`
- `case inline(String)` — 文本直接内联，不落文件
- `case copy(hash: String, size: Int64)` — 副本，以内容 SHA-256 命名
- `case reference(bookmark: Data, size: Int64)` — 安全书签引用

- `var size: Int64` — 统一取字节数；`inline` 取 UTF-8 字节长度。

#### `enum ItemState: String, Codable, Sendable`
`active` / `broken` / `damaged` / `unavailableOnThisDevice` / `trashed`。
`broken` 只保留给旧数据迁移；当前健康巡检会把确认删除移入回收站，把卷离线保留为 active，把异地引用标为 `unavailableOnThisDevice`。

#### `struct Item: Identifiable, Sendable, Codable, Equatable`
- `var isFullyIndexed: Bool`
  - 功能：四个索引字段是否齐备
  - 返回值：`vector` 非空且 `contentHash`、`embeddingModelID`、`indexedAt` 均非 nil
  - 副作用·异常：无

### VaultError.swift

#### `enum VaultError: Error, Equatable, CustomStringConvertible`
`emptyFile` / `unreadable` / `copyFailed` / `staleBookmark` / `referenceUnavailable` / `purgeFailed`。
每个 case 对应 design 边界表的一行，`description` 提供面向用户的中文原因。

#### `struct ReconcileReport: Sendable, Equatable`
`orphansRemoved` / `missingCopies` / `retriedPurges` / `isClean`。

### FileVault.swift

#### `struct VaultConfig`
`copyThreshold: Int64`（仅旧阈值策略兼容）、`retention: TimeInterval`（默认 2592000）。

#### `actor FileVault`

##### `init(root: URL, config: VaultConfig = .init(), availableSpace: @escaping SpaceProbe = FileVault.systemFreeSpace) throws`
- 功能：建立 vault 根目录与 `copies/` 子目录，载入引用计数清单
- 参数：`root` vault 根；`config` 兼容阈值与保留期；`availableSpace` 可用空间探针
- 副作用：创建目录；读取 `manifest.json`
- 异常：`rethrows` `FileManager.createDirectory` 的错误；清单读取失败静默视为空清单

##### `func ingest(_ url: URL, preference: FileIngestPreference = .referenceFirst) throws -> Holding`
- 功能：`.referenceFirst` 先建书签、失败才副本；`.copyRequired` 用于临时来源；`.automaticBySize` 只保留旧数据兼容
- 返回值：`Holding`
- 副作用：可能写入 `copies/<sha256>`；更新并持久化引用计数
- 异常：`throws VaultError.emptyFile`（零字节）、`.unreadable`（不可读或哈希失败）、`.copyFailed`（拷贝失败，**已回滚临时文件**）
- 调用示例：`let holding = try await vault.ingest(url, preference: .referenceFirst)`

##### `func release(_ holding: Holding)` / `func retain(_ holding: Holding)`
- 功能：条目删除或恢复时增减引用计数
- 副作用：持久化清单。**计数归零不删盘**
- 异常：无

##### `func refCount(_ hash: String) -> Int`
- 副作用·异常：无

##### `func purge(_ hash: String) throws`
- 功能：回收站到期后真正删盘，仅在计数小于等于零时生效
- 副作用：删除副本文件；清除清单记录
- 异常：`throws VaultError.purgeFailed`，并把该 hash 记入待重试集合。文件已被外部删除时视为成功，不抛错

##### `@discardableResult func reconcile() throws -> ReconcileReport`
- 功能：启动时双向对账，并重试上次失败的删除
- 副作用：删除孤儿文件；可能删除待重试项
- 异常：目录读取失败时按空目录处理，不中断

##### `func activeUsage() -> Int64` / `func trashedUsage() -> Int64`
- 功能：分别统计计数大于零与小于等于零的副本占用
- 副作用·异常：无。以清单为准而非扫盘

##### `static func sha256(of url: URL) throws -> String`
- 功能：分块（1MB）计算文件 SHA-256，避免大文件整体载入内存
- 异常：`throws` `FileHandle` 的读取错误

---

## 4. 开发日志

### 4.1 做了什么

当前三层 SwiftPM 工程已经贯通本地存储、SwiftData、刘海 UI、供应商适配、语义索引、归档和效率模式；iCloud / CloudKit 已移除。边界处理采用显式结果：拒绝、回滚、冻结、排队或可读错误，不用静默失败掩盖状态。

### 4.2 遇到问题

**SwiftData 起初不可用，后已解除**。CLT 工具链下 `@Model` 报 `external macro implementation type 'SwiftDataMacros.PersistentModelMacro' could not be found`。当时的处理是不引入 SwiftData，`Item` 写成普通 `Codable` 值类型。随后 Xcode 27 beta 安装到位，`@Model` 实测可编译可运行，阻塞解除。

`Item` 保持为值类型这一点不打算回退：design 的分层规定领域层不感知存储实现，SwiftData 应当只作为 `ItemStore` 的一个实现存在，而不是渗进模型定义。

**actor 初始化不能调用隔离方法**。`init` 中调用 `loadManifest()` 报 `call to actor-isolated instance method in a synchronous nonisolated context`。改为 `private static func readManifest(at:)`，在 `init` 中赋值。

**codesign 被扩展属性拦住**。项目在 `~/Desktop` 下，签名测试 bundle 时报 `resource fork, Finder information, or similar detritus not allowed`。执行 `xattr -cr` 并把构建产物移出项目目录后解决。

**swift-testing 需要补两处路径**（仅 CLT 工具链下）。宏插件在 `plugins/testing/` 子目录而非 `plugins/` 顶层，SwiftPM 不扫描，需 `-load-plugin-library`；随后运行时依次缺 `Testing.framework` 与 `lib_TestingInterop.dylib`，需补两条 `-rpath`。三者写进 `Package.swift` 的条件分支。

**该条件分支最初写错了**：只检查 `/Applications/Xcode.app`，而实际安装的是 `Xcode-beta.app`，导致 Xcode 到位后补丁仍在生效。已改为识别任意 `Xcode*.app` 并兼顾 `DEVELOPER_DIR`。

### 4.3 验证结果

`swift test` 使用 Xcode 27 beta 工具链执行；存储、条目展示元数据和绝对时间计时用例全部通过。最新数量与逐条结果见 test-record。

### 4.4 刘海工作台重设计（2026-08-29）

- 第二轮结构审计推翻了“同一动态缩放 `NSPanel` 承载全部状态”的假设。窗口拆为固定锚点、专用拖拽接收、浅层反馈、固定工作台与独立详情；AppKit 不再动画 frame。
- 新增 `NotchPresentationState`：工作台使用 `hidden / opening / open / closing`，拖拽使用 `idle / targeted / receiving / absorbed / failed`，两条状态轴互不隐式改写。
- 展开触发改为明确点击或 `Control-Command-Space`；hover 只显示卡片局部操作，不再改变窗口状态。
- 面板状态拆成 `collapsed`、`dropTarget`、`expanded`。拖拽只打开 88pt 浅层投放区，不连带打开完整工作台。
- 收起窗口宽度按物理刘海加左右翼计算；计时文本固定在右翼，解决只按刘海宽度建窗导致 `mm:ss` 被裁掉的问题。
- `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` 按全局坐标计算，屏幕变化时重建锚点、展开唇与拖拽命中几何。
- Liquid Glass 仅用于收起条、投放区和展开面板外壳；卡片与预览使用稳定内容表面，避免嵌套玻璃。
- 拖拽反馈只在刘海左右翼显示添加与类型图标，不创建独立大块面板、梯形或张力桥。
- 图片卡片读取真实缩略图，PDF 取首页，其他文件取 Finder 图标；详情支持图片、PDF、文本和链接预览。
- 文件拖出通过 `NSItemProvider.registerFileRepresentation` 暂存原名副本，保留原文件名与 UTI；内联文字走系统字符串拖拽。
- 专注计时改为绝对结束时间结算，UI ticker 只触发刷新，休眠后不会累计漂移。
- `Control-Command-P` 收纳当前剪贴板，`Control-Command-C` 复制当前选区后收纳；只有后者在实际使用时请求辅助功能权限。

### 4.5 AI、模型目录与调用时机（2026-08-29）

- OpenAI 兼容与 Anthropic Messages 共用唯一 `AIExecutionEngine` 入口；每个功能可覆盖供应商、模型与思考强度。
- 供应商官方模型列表首次切换自动读取一次，之后只由用户按钮刷新；models.dev 能力 / 价格有独立按钮，只补同名 chat 元数据，发布完整快照前 UI 始终显示旧对象。
- Embedding 模型名和单价允许手填，维度由首次返回向量长度探测；维度变化触发全库标脏。
- 搜索输入停顿只做本地规则与全文筛选；用户按回车后才调用一次 `queryParsing` 与查询 embedding，相同查询按路由缓存。
- AI 整理与索引各有持久化串行队列。新增、真实编辑或模型变化才入队；恢复与索引字段回填不入队。详情先显示本地场景建议，模型排序按内容指纹与路由持久缓存，相同版本重复打开不调用。网络只在从离线恢复时唤醒一次，配置错误等待用户修正。
- 命名与分类路由相同时合并为一次结构化调用；非法结构只修复一次。每功能累计供应商返回的 usage，用于设置页成本估算。

### 4.6 文件与剪贴板生命周期（2026-08-29）

- `Library.ingest` 默认 `.referenceFirst`；剪贴板位图和临时图片显式 `.copyRequired`。
- 引用健康巡检每 60 秒运行且带 12 秒 tolerance：确认删除进回收站，外置卷离线不误删，内容变化重建 AI / 索引。
- 回收站保留向量；同内容重新拖入恢复原 ID。剪贴板默认保留 5 条未固定项，Mnemo 自己写回剪贴板不会被重新捕获。

### 4.7 归档、窗口与上下文检索（2026-08-30）

- iCloud / CloudKit、云容器权限和同步 UI 已移除；`.pinlandarchive` 负责显式迁移，副本导入前校验哈希。
- `NotchWindowPlan` 纯投影窗口可见性与鼠标所有权；工作台出现时锚点 order out，外部拖拽接收器只在工作台 hidden 时武装。
- `NotchAnchorLayoutMetrics` 统一面板、展开唇、推荐行与 AppKit 命中：单条留翼，多条从物理刘海与展开唇下方开始。复制 / 关闭由 SwiftUI 独占，展开唇由 AppKit 独占。
- 剪贴板上下文与主动搜索共享 OCR / PDF / 文本分块和 Embedding 索引。有效模型 ID 是最终集合；有效空清卡；格式错误与模型不可用分别降级。检索型文本不留历史；图片 OCR 完成后进入同一管线。
- SSE 支持两种方言和任意 chunk 边界；回答按 generation 与 50ms 节流发布，Markdown 使用稳定块 identity 增量渲染。
- 剪贴板只按数量保留最近 5 条未固定项，没有 TTL；全部 Mnemo 自写 changeCount 被过滤。自动文件复制只在 URL 解析与粘贴板写入成功后显示对号。
- 卡片缩略图右下角打来源应用角标：容器路径里带着对方的 bundle id，取系统里那个应用的真实图标，微信 / QQ / 飞书都自动认得。副本型条目也记录来处（`auditReferences` 只处理引用，不会误判成"原文件被删"）。
- 展开面板 600、头部 48、页签 36、内容区 236；收纳态保持单行卡片，卡片长到 176×128、缩略图 62，把多出来的高度用在预览上。曾经试过两行 100pt 卡片，加页签共 260pt 超出内容区，第二排被裁掉，看着就是重叠。效率态表盘 80、统计条 44 落在同一高度内。
- 链接详情：整块封面 + 左下角站点信息 + 右上角动作条；站点图标只按 34pt 显示，绝不拉满（180px 的图标铺满详情就是一块马赛克）。需要真读页面时按一下切到内嵌 WKWebView，只在用户主动切换时才加载。
- 「更多」从系统 `Menu` 改成画在面板自己层里的下拉：系统弹层位置由 AppKit 决定，会溢出面板盖到刘海和菜单栏上。
- 卡片轨道在超过一屏时悬停显示左右翻页把手，横向滚动照常可用但不再是唯一入口。
- 剪贴板条目的图钉常驻并改成开关：`Library.setClipboardPin(id:isPinned:)` 双向可用，取消后立刻按容量结算。之前锁定即隐藏入口，等于只能删掉重来。
- 被动剪贴板监听不再收文件，只留截图与文字；显式的 `ingestClipboard()`（⌃⌘P / 菜单）与拖入照旧接受文件。
- 剪贴板推荐的判据换成 `ContextRetrievalGate`：形态闸门（短话才看）+ 证据闸门（本地最强命中 ≥ 0.5 才显示）。词表只保留为"明确索取"的快路径，不再是链路终点；那次判断"要不要检索"的布尔模型调用整体删除。"pi agent 网址给我"这类说法既没有场景词也没有可识别标识，靠词表永远追不上。
- 检索里的类型只当偏好：带类型召回为空时退回不限类型重来一次；候选补位先补同类型再补其余。此前类型猜错等于把答案整个滤掉，表现为"搜索能找到、复制推荐没反应"。
- 类型词表收敛成 `ContentTypeVocabulary` 一份，剪贴板意图与查询解析共用；剪贴板已判定的类型直接传进 `SemanticIndexCoordinator.search(kinds:)`。
- 卡片单击复制、双击预览：双击手势必须先声明，否则单击会吃掉第一下。
- 上下文与投放诊断写进同一份 `drop-trace.log`：这条链上每一道闸门都是静默返回，NSLog 在打包应用里又看不到，出问题只能靠猜。
- 「带有 test-time 的图给我」这类请求没有场景词但点名了具体标识，现在与场景词同级，直接判为检索；图片词表补上"的图""张图""示意图"等搭配（"图"单字仍不算）。
- 实测结论（`drop-trace.log`）：微信拖出的文件只给 `public.file-url` / `NSFilenamesPboardType` 和几个 Qt 私有类型，**没有文件承诺、也没有任何数据 flavor**，路径指向它自己的容器。macOS 用 TCC 保护 `~/Library/Containers/<别的应用>`，非沙盒应用要读必须有完全磁盘访问权限——这不是能绕开的技术问题，只能明确告诉用户去授权，或先把文件存到访达。菜单栏提供直达该设置页的入口。
- 从微信这类应用的聊天里拖出文件，落到手上的是 `~/Library/Containers/<对方>/…/temp/drag/x.pdf`：目录归对方管、随时被清，且容器受 TCC 保护，我们连字节都读不到。这类来源现在强制走受管副本；直接路径读不出时按代价从低到高换路：先用发送方的文件承诺，再退到把拖拽板上的字节自己落盘（承诺缺席时仍能拿到真内容），两条都不通才失败；剪贴板写入前先真读 1 字节，读不到就明确失败并提示重新拖入，不再出现"对号亮了却粘不出来"。
- 交给系统剪贴板 / 拖拽板的文件统一走 `PinFileStaging`：受管副本在沙盒里是无扩展名的哈希文件，直接放上剪贴板接收方判不出类型、给不出文件名，表现为"显示已复制却粘不出来"；现在按原始文件名暂存一份再交出去，引用型条目名字本来就对则不复制。图片另附一份 PNG 数据，供只认位图的输入框。
- 收起态的展开唇、推荐行与关闭区统一由 AppKit 按 `NotchAnchorLayoutMetrics` 命中执行：锚点永不成为 key window，SwiftUI Button 在别的应用前台时收不到点击（"点复制没反应"）。
- 手动点推荐同样等系统粘贴板写成功后才把该行变成对号，收起态没有 toast 可用。
- 收起态展开唇不再画可见底色，可点性由宿主视图 2% 黑底保证：空闲和单条推荐时刘海下方没有任何舌头，只有候选竖排才把刘海、唇和列表连成一块黑。
- 本地判定为检索请求（含点名类型的短名词短语）的复制直接跳过入库；本地认不出但形态像短诉求的内容才问模型路由，成段正文两者都不做。
- 手册 / 教程 / 课件 / 讲义这类"资料"补进场景词表，之前意图判空会让整条链在模型之前断掉。
- ⌘G 用前台选区**直接出推荐**（刘海那一行），不是打开搜索框；主动触发时形态与证据两道闸门都让路——用户已经说了他要什么。代按的 Cmd-C 通过 `Clipboard.ignoreUpcomingChanges()` 登记为自写，不入库也不触发捕获。
- 复制不再触发推荐，只判去留：本地确信是查询就不入库，判不出但形态像短话时问一次模型（`isRetrievalQuery`），失败或未配置一律保留。
- ⌘G 的控制器用跨文档、图片、网页、表格、日志、代码和普通文字的成对 Few-shot，按用户最终想拿到原对象 / 原值还是解释 / 分析，输出互斥的 `retrieve / answer`：前者继续交付真实 Pin 或本地逐字校验的 `copyText`；后者把白名单 ID 只当内部证据，不显示文件卡，重新读取完整分块并生成简体中文回答；聚焦外部输入框且设置开启时通过 SSE 分段写入，否则完整回答自动写入剪贴板；写成功才发布对应确认，失败保留手动重试。回答卡无叉号、点外部收起；正文裁剪在标题下方、无描边，隐藏系统滚动槽并用自绘细滑块悬浮右边界。Command-G 不限频：每次按键产生独立 generation，取消旧抓取、只发布最新一次；精确登记实际选区 changeCount，不再预占未来计数；缓存重放也恢复处理中状态。 新按键在 Cmd-C 前即取消旧回答；选区等待期间若上一轮回答自动写剪贴板，会按 Mnemo 自写 count 拒绝，不会把旧回答当成新查询。 但 Command-C 与 Command-G 不冲突：优先读 AXSelectedText；应用在选中时已自动复制且 Command-C 不再改计数时，可用外部基线文字；回答覆盖剪贴板后，还可复用同一前台应用上次由 Command-G 验证的选区，不设 TTL。
- 快捷回答每轮创建全新 messages，只保留当前 Task 的候选与证据；不保存对话历史或跨轮 tool state。默认开启“聚焦输入框时直接写入”：按键时从焦点解析 AXEditableAncestor，SSE 增量经 12 字 / 90ms 节流直接插入；原生输入框写 AXSelectedText / AXValue，微信、Electron 与网页自绘输入框在 AX 拒写时向同一前台进程发送定向 Unicode 键盘事件，不使用剪贴板；第一段 SSE 到达才折叠选区，CR/LF 压成普通空格，绝不触发聊天发送。无可编辑宿主、密码 / 只读 / 自身控件、用户中途移动焦点或关闭开关时退回剪贴板。新一轮 ⌘G 接管时，在光标未被用户改变的前提下撤回旧轮已插入半截。OpenAI `finish_reason=length` / Anthropic `stop_reason=max_tokens` 在流与非流路径都会标成未完成；输入框里的半成品在光标未被用户改变时安全撤回，不能显示完成确认。
- 独立详情窗口不再跟随刘海工作台收起；预览与编辑详情均由自身关闭键控制；编辑详情自己的关闭仍执行未保存确认。
- 自动捕获的临时截图 / 文字有独立处理开关，默认关闭。开关只在**捕获当时**授予新条目后台处理资格：开启后新捕获立即 OCR / AI / Embedding；关闭后新捕获只保存，固定后才处理。切换不追溯旧条目、不删除已有索引，也不撤销之前已授权 / 已排队的任务；人工拖入与显式收纳永远立即处理。
- 快捷回答预算由 1,800 放宽到 4,096 token。答案写进输入框时，第一段 token 直接替换用户选中的问题；非输入框交付仍只写剪贴板，不清理任何外部内容。

- 收起面板不再调用 `endSearch()`：点一下别处就把正在跑的召回与流式回答全部取消，用户回来看到空白还以为没搜到。
- 检索只加载确定性过滤后候选的分块（`ItemStore.chunks(itemIDs:)`），不再每次全量读表；模型在候选内收敛到唯一一条时自动准备剪贴板，敏感字段与多候选仍只推荐。

### 4.8 当前验证边界（2026-09-01）

Xcode 27 beta 下最新干净完整 `swift test` 为 **136 / 136 通过，0 失败**；Debug 与 Release 构建成功，临时目录中的 ad-hoc 包已严格验签并启动。仍需在最终安装位置完成真实刘海点击、Finder / 浏览器 / 聊天软件拖拽、Command-G 的文件 / 网址 / 完整中文回答、真实供应商 SSE / Embedding、微信文件粘贴和多显示器视觉验收。Keychain 仍使用已弃用 ACL API，编译有警告；在取得稳定 Developer ID 签名前保留为技术债，不宣称 ad-hoc 签名下的密码提示已彻底解决。
