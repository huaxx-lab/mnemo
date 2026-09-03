import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MnemoCore

/// The visible anchor owns the click. No SwiftUI child competes for the event.
@MainActor
final class NotchAnchorHostingView<Content: View>: NSHostingView<Content> {
    /// 面板坐标（左上原点）里的一块可点区域及其唯一动作。
    struct HitRegion {
        var rect: CGRect
        var action: () -> Void
    }

    private let openAction: () -> Void

    init(rootView: Content, openAction: @escaping () -> Void) {
        self.openAction = openAction
        super.init(rootView: rootView)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("打开 Mnemo")
    }

    @available(*, unavailable)
    required init(rootView: Content) {
        fatalError("Use init(rootView:openAction:)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 当前真正可点的尺寸，由收起条的状态逐帧提供。
    ///
    /// 旧实现是 `bounds.contains`：面板宽 352pt、高 58pt，而收起态实际
    /// 可见的只有刘海本身。多出来的部分是完全不可见的热区，压在前台应用的
    /// 菜单栏上——点在那里会莫名弹出 Mnemo。
    var visibleSize: () -> CGSize = { .zero }
    /// 面板内真正画出来 / 可以操作的矩形并不总是一个整块：快捷回答正文在
    /// 菜单栏下方变宽，但顶部只有居中的刘海状态带。分区命中可避免宽面板的
    /// 透明上角吞掉 Safari / 系统菜单栏点击。
    var visibleRegions: () -> [CGRect] = { [] }
    /// 面板坐标里的明确展开矩形。推荐行、复制图标和关闭控件绝不能落进这里。
    /// 使用矩形而不是“顶部 N 点”，因为物理刘海没有像素，真正可点的是它正下方
    /// 居中的接触唇，而不是整个两翼状态带。
    var openRegion: () -> CGRect = { .zero }
    /// 展开唇之外的其他动作区：推荐行、关闭推荐。
    ///
    /// 这些控件在 SwiftUI 里画得好好的，但锚点是 `nonactivatingPanel` 且永远
    /// 不成为 key window——别的应用在前台时，SwiftUI `Button` 收不到那一下点击，
    /// 表现就是"点了复制没反应"。所以命中和动作统一由 AppKit 这一层负责，
    /// SwiftUI 只管画。
    var actionRegions: () -> [HitRegion] = { [] }

    /// 悬停展开的命中区（面板坐标，左上原点）。参考 boring.notch 那一路的做法：
    /// 指针要在刘海那一带**停住**一小段时间才展开，扫过去不算——
    /// 误触和"想去点菜单栏"都不会误开，真想要的人停一下就到了。
    var hoverExpandRegion: () -> CGRect = { .zero }
    /// 此刻允不允许悬停展开（工作台已开、正在拖拽等时候一律不许）。
    var canHoverExpand: () -> Bool = { false }
    var onHoverExpand: (() -> Void)?

    private var hoverTrackingArea: NSTrackingArea?
    private var hoverDwellTask: Task<Void, Never>?
    private var hoverDwellGeneration = 0
    private var isTrackingOpenClick = false
    private var trackingRegionIndex: Int?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isVisible(point) else { return nil }
        if isInsideOpenRegion(point) || regionIndex(at: point) != nil { return self }
        return super.hitTest(point)
    }

    // MARK: - 悬停展开

    /// 自有跟踪区只覆盖整个可见矩形；区域判定在 mouseMoved 里按 metrics 做。
    /// `.activeAlways` 是关键：锚点面板永远不成为 key，应用也常在后头，
    /// 缺了它跟踪区根本不会投递事件。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverDwell(at: convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        cancelHoverDwell()
        super.mouseExited(with: event)
    }

    /// 进出命中区才改变驻留状态：在里面挪动不重启计时，划出边界立即作废。
    private func updateHoverDwell(at point: NSPoint) {
        guard canHoverExpand() else {
            cancelHoverDwell()
            return
        }
        if hoverExpandRegion().contains(topDown(point)) {
            startHoverDwell()
        } else {
            cancelHoverDwell()
        }
    }

    private func startHoverDwell() {
        guard hoverDwellTask == nil else { return }
        hoverDwellGeneration &+= 1
        let generation = hoverDwellGeneration
        hoverDwellTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(NotchInteractionPolicy.hoverExpandDwellMilliseconds))
            guard !Task.isCancelled, let self,
                  self.hoverDwellGeneration == generation,
                  self.canHoverExpand(),
                  // 触发前再看一眼：指针得还在命中区里、鼠标键也没被按住
                  // （按住 = 在拖拽或点击，那时展开属于帮倒忙）。
                  NSEvent.pressedMouseButtons == 0,
                  let window = self.window
            else { return }
            let point = self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            guard self.hoverExpandRegion().contains(self.topDown(point)) else { return }
            self.hoverDwellTask = nil
            self.onHoverExpand?()
        }
    }

    private func cancelHoverDwell() {
        hoverDwellGeneration &+= 1
        hoverDwellTask?.cancel()
        hoverDwellTask = nil
    }

    private func topDown(_ point: NSPoint) -> NSPoint {
        isFlipped ? point : NSPoint(x: point.x, y: bounds.maxY - point.y)
    }

    private func isInsideOpenRegion(_ point: NSPoint) -> Bool {
        openRegion().contains(topDown(point))
    }

    private func regionIndex(at point: NSPoint) -> Int? {
        let converted = topDown(point)
        return actionRegions().firstIndex { $0.rect.contains(converted) }
    }

    /// 只有按下和抬起都在同一个展开唇里才打开。其余位置完整交还给
    /// NSHostingView，SwiftUI Button 才能收到正常的按压序列。
    override func mouseDown(with event: NSEvent) {
        // 按下就不是悬停了：要么是在点展开唇，要么要拖东西，驻留计时作废。
        cancelHoverDwell()
        let point = convert(event.locationInWindow, from: nil)
        if isInsideOpenRegion(point) {
            isTrackingOpenClick = true
            return
        }
        if let index = regionIndex(at: point) {
            trackingRegionIndex = index
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isTrackingOpenClick {
            isTrackingOpenClick = false
            guard event.clickCount <= 1, isInsideOpenRegion(point) else { return }
            openAction()
            return
        }
        if let index = trackingRegionIndex {
            trackingRegionIndex = nil
            let regions = actionRegions()
            // 按下和抬起必须落在同一块，否则一次误拖也会执行动作。
            guard event.clickCount <= 1, regionIndex(at: point) == index,
                  regions.indices.contains(index) else { return }
            regions[index].action()
            return
        }
        super.mouseUp(with: event)
    }

    private func isVisible(_ point: NSPoint) -> Bool {
        let regions = visibleRegions()
        if !regions.isEmpty { return regions.contains { $0.contains(topDown(point)) } }
        return hitRect().contains(point)
    }

    private func hitRect() -> NSRect {
        let size = visibleSize()
        guard size.width > 0, size.height > 0 else { return bounds }
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: isFlipped ? bounds.minY : bounds.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}

/// Dedicated AppKit dragging destination. The panel is normally mouse-transparent
/// and is armed only during an active drag near the notch.
@MainActor
final class NotchDragReceiverView: NSView {
    private static var internalPinType: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(PinDragProvider.internalTypeIdentifier)
    }
    private static var imageTypes: [(NSPasteboard.PasteboardType, String)] {
        [
            (.png, "png"),
            (NSPasteboard.PasteboardType(UTType.jpeg.identifier), "jpg"),
            (NSPasteboard.PasteboardType(UTType.heic.identifier), "heic"),
            (NSPasteboard.PasteboardType(UTType.webP.identifier), "webp"),
            (NSPasteboard.PasteboardType(UTType.gif.identifier), "gif"),
            (NSPasteboard.PasteboardType(UTType.bmp.identifier), "bmp"),
            (.tiff, "tiff"),
        ]
    }
    private static var broadContentTypes: [NSPasteboard.PasteboardType] {
        [
            .fileContents,
            .html,
            .rtf,
            .rtfd,
            NSPasteboard.PasteboardType(UTType.item.identifier),
            NSPasteboard.PasteboardType(UTType.content.identifier),
            NSPasteboard.PasteboardType(UTType.data.identifier),
        ]
    }
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        let directTypes: [NSPasteboard.PasteboardType] = [
            Self.internalPinType,
            .fileURL,
            .URL,
            .string,
            NSPasteboard.PasteboardType(UTType.image.identifier),
        ] + Self.imageTypes.map(\.0)
        let promisedTypes = NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        }
        registerForDraggedTypes(directTypes + Self.broadContentTypes + promisedTypes)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender.draggingPasteboard) else { return [] }
        model.setDropTargeted(true, payloadKind: payloadKind(sender.draggingPasteboard))
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender.draggingPasteboard) else { return [] }
        model.setDropTargeted(true, payloadKind: payloadKind(sender.draggingPasteboard))
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        model.setDropTargeted(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        accepts(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard

        // 从 Mnemo 卡片拖回刘海只是回到原位，不得再复制一条。
        if pasteboard.availableType(from: [Self.internalPinType]) != nil {
            model.completeInternalDrop()
            return true
        }

        guard model.beginInboundDrop() else { return false }

        DropTrace.log(
            "投放 类型=[\((pasteboard.types ?? []).map(\.rawValue).joined(separator: ","))] "
            + "承诺=\(pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil))"
        )

        let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        let routed = NotchInteractionPolicy.route(urls: urls)
        let promiseReceivers = (pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver]) ?? []

        // 直接给的路径读不出来时不能就这么算了：那条路径可能在别的应用受 TCC
        // 保护的容器里（微信聊天里拖出来的文件就是这样）。按代价从低到高换路：
        // 先用对方的文件承诺，让发送方把文件写进我们的目录；没有承诺就退到
        // 拖拽板上的字节自己落盘。两条都不通才算失败——绝不建一条读不出内容
        // 的空壳 Pin。
        let unreadableFiles = routed.files.filter { !DroppedSourceTrust.isReadable($0) }
        DropTrace.log(
            "文件=\(routed.files.map(\.lastPathComponent)) 读不到=\(unreadableFiles.count) "
            + "链接=\(routed.links.count) 承诺=\(promiseReceivers.count)"
        )
        if !unreadableFiles.isEmpty {
            if !promiseReceivers.isEmpty {
                DropTrace.log("走文件承诺")
                PromisedDropBatch(model: model).start(receivers: promiseReceivers)
                return true
            }
            if let staged = Self.materializePasteboardData(pasteboard, named: unreadableFiles) {
                DropTrace.log("走拖拽板字节 \(staged.map(\.lastPathComponent))")
                let origin = unreadableFiles.first?.standardizedFileURL.path
                Task {
                    let readable = routed.files.filter { DroppedSourceTrust.isReadable($0) }
                    var report = await model.ingest(
                        urls: staged,
                        preference: .copyRequired,
                        sourcePath: origin
                    )
                    if !readable.isEmpty { report.merge(await model.ingest(urls: readable)) }
                    model.completeInboundDrop(report)
                }
                return true
            }
            // 承诺没有、字节也没有：这是 TCC 挡在别的应用容器门口。继续往下走
            // 只会拿到一句"无读取权限"，用户看不到也不知道该做什么。
            DropTrace.log("来源不可读且无替代负载，提示授权")
            let readable = routed.files.filter { DroppedSourceTrust.isReadable($0) }
            Task {
                var report = AppModel.IngestReport()
                if !readable.isEmpty { report.merge(await model.ingest(urls: readable)) }
                for link in routed.links { report.merge(await model.ingest(text: link.absoluteString)) }
                model.reportUnreadableDrop(unreadableFiles, partial: report)
            }
            return true
        }

        if !routed.files.isEmpty || !routed.links.isEmpty {
            DropTrace.log("走直接路径入库")
            Task {
                var report = AppModel.IngestReport()
                if !routed.files.isEmpty {
                    report.merge(await model.ingest(urls: routed.files))
                }
                for link in routed.links {
                    report.merge(await model.ingest(text: link.absoluteString))
                }
                model.completeInboundDrop(report)
            }
            return true
        }

        if !promiseReceivers.isEmpty {
            PromisedDropBatch(model: model).start(receivers: promiseReceivers)
            return true
        }

        for (type, fileExtension) in Self.imageTypes {
            if let data = pasteboard.data(forType: type) {
                Task {
                    let report = await model.ingest(
                        payload: .image(data, fileExtension: fileExtension)
                    )
                    model.completeInboundDrop(report)
                }
                return true
            }
        }

        if let imageType = pasteboard.types?.first(where: { type in
            UTType(type.rawValue)?.conforms(to: .image) == true
        }), let data = pasteboard.data(forType: imageType) {
            let fileExtension = UTType(imageType.rawValue)?.preferredFilenameExtension ?? "png"
            Task {
                let report = await model.ingest(
                    payload: .image(data, fileExtension: fileExtension)
                )
                model.completeInboundDrop(report)
            }
            return true
        }

        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            Task {
                let report = await model.ingest(payload: .image(png, fileExtension: "png"))
                model.completeInboundDrop(report)
            }
            return true
        }

        if let value = pasteboard.string(forType: .string),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
                let report = await model.ingest(text: value)
                model.completeInboundDrop(report)
            }
            return true
        }

        DropTrace.log("没有可用负载，投放失败")
        model.completeInboundDrop(.init(failed: 1))
        return false
    }

    /// 把拖拽板上的字节按原文件名落到我们自己的临时目录。
    ///
    /// 发送方给了路径却不给读，但内容常常同时以数据形式挂在拖拽板上
    /// （`public.file-contents` 或具体类型，如 `com.adobe.pdf`）。这条路拿到的
    /// 是真字节，落盘之后一切照常。
    private static func materializePasteboardData(
        _ pasteboard: NSPasteboard,
        named files: [URL]
    ) -> [URL]? {
        var candidates: [NSPasteboard.PasteboardType] = files
            .compactMap { UTType(filenameExtension: $0.pathExtension)?.identifier }
            .map { NSPasteboard.PasteboardType($0) }
        candidates.append(.fileContents)
        candidates.append(NSPasteboard.PasteboardType(UTType.data.identifier))
        guard let type = candidates.first(where: { pasteboard.data(forType: $0)?.isEmpty == false }),
              let data = pasteboard.data(forType: type),
              let name = files.first?.lastPathComponent else { return nil }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "mnemo-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destination = directory.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return [destination]
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    private func accepts(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) {
            return true
        }
        let directTypes: [NSPasteboard.PasteboardType] = [
            Self.internalPinType,
            .fileURL,
            .URL,
            .string,
            NSPasteboard.PasteboardType(UTType.image.identifier),
        ] + Self.imageTypes.map(\.0)
        if pasteboard.availableType(from: directTypes + Self.broadContentTypes) != nil { return true }
        return pasteboard.types?.contains { type in
            UTType(type.rawValue)?.conforms(to: .image) == true
        } == true
    }

    private func payloadKind(_ pasteboard: NSPasteboard) -> AppModel.InboundPayloadKind {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        if let url = urls.first {
            if !url.isFileURL { return .link }
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
                return .image
            }
            return .file
        }
        if pasteboard.types?.contains(where: { type in
            UTType(type.rawValue)?.conforms(to: .image) == true
        }) == true || NSImage(pasteboard: pasteboard) != nil {
            return .image
        }
        if pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) {
            return .file
        }
        if let value = pasteboard.string(forType: .string),
           let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return .link
        }
        if pasteboard.string(forType: .string) != nil { return .text }
        return .unknown
    }
}

@MainActor
private final class PromisedDropBatch {
    private let model: AppModel
    private var destination: URL?
    private var receivedURLs: [URL] = []
    private var remaining = 0
    private var failureCount = 0

    init(model: AppModel) {
        self.model = model
    }

    func start(receivers: [NSFilePromiseReceiver]) {
        do {
            let destination = FileManager.default.temporaryDirectory
                .appending(path: "mnemo-promised-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            self.destination = destination
            remaining = receivers.count

            for receiver in receivers {
                receiver.receivePromisedFiles(
                    atDestination: destination,
                    options: [:],
                    operationQueue: .main
                ) { [self] fileURL, error in
                    let message = error?.localizedDescription
                    Task { @MainActor [self, fileURL, message] in
                        receive(fileURL: fileURL, errorMessage: message)
                    }
                }
            }
        } catch {
            model.lastError = "无法接收拖拽内容：\(error.localizedDescription)"
            model.completeInboundDrop(.init(failed: receivers.count))
        }
    }

    private func receive(fileURL: URL, errorMessage: String?) {
        if let errorMessage {
            failureCount += 1
            model.lastError = "拖拽文件接收失败：\(errorMessage)"
        } else {
            receivedURLs.append(fileURL)
        }
        remaining -= 1
        guard remaining == 0 else { return }

        Task { @MainActor [self] in
            var report = await model.ingest(urls: receivedURLs, preference: .copyRequired)
            report.failed += failureCount
            if let destination { try? FileManager.default.removeItem(at: destination) }
            model.completeInboundDrop(report)
        }
    }
}

@MainActor
enum PinDragProvider {
    static let internalTypeIdentifier = "com.pinland.dragged-pin-id"

    static func make(item: Item, resolvedURL: URL?, model: AppModel) -> NSItemProvider {
        model.beginOutboundDrag(itemID: item.id)

        if case .inline(let text) = item.holding {
            let provider = NSItemProvider(object: text as NSString)
            provider.suggestedName = item.title
            attachInternalIdentity(item.id, to: provider)
            return provider
        }

        guard let source = resolvedURL else {
            let provider = NSItemProvider(object: item.title as NSString)
            attachInternalIdentity(item.id, to: provider)
            return provider
        }

        // 拖出去的文件必须在拖拽开始前就落到一个稳定路径上。
        //
        // 旧实现用 registerFileRepresentation 惰性复制，并在 completion 返回后
        // 立刻 defer 删掉暂存目录——接收方还没读完文件就没了。只认
        // public.file-url 的接收方（聊天软件、邮件的附件栏）因此什么都拿不到，
        // 表现就是"论文拖不进去"。
        let staged = stage(source: source, item: item)
        if let staged, let provider = NSItemProvider(contentsOf: staged) {
            provider.suggestedName = staged.lastPathComponent
            attachInternalIdentity(item.id, to: provider)
            return provider
        }

        let provider = NSItemProvider()
        provider.suggestedName = item.originalFilename ?? item.title
        let payload = staged ?? source
        provider.registerFileRepresentation(
            forTypeIdentifier: item.contentTypeIdentifier ?? UTType.data.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(payload, false, nil)
            return nil
        }
        attachInternalIdentity(item.id, to: provider)
        return provider
    }

    private static func stage(source: URL, item: Item) -> URL? {
        PinFileStaging.stage(source: source, item: item)
    }

    private static func attachInternalIdentity(_ id: UUID, to provider: NSItemProvider) {
        let data = Data(id.uuidString.utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: internalTypeIdentifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
    }
}

/// 交出去的文件必须带真名。
///
/// 受管副本在沙盒里叫 `vault/copies/<sha256>`——没有扩展名，也没有可读名字。
/// 直接把这个路径放上剪贴板，接收方判不出类型、给不出文件名，表现就是
/// "显示复制成功了，但粘贴不出来"。拖拽早就绕开了这一点，复制这条路没有，
/// 所以两边现在共用同一份暂存。
@MainActor
enum PinFileStaging {
    /// 暂存目录留几份再回收。剪贴板不像拖拽那样用完就结束——用户可能过几分钟
    /// 才去粘贴，删早了就又是一次"粘不出来"。
    private static let retainedDirectories = 6
    private static var directories: [URL] = []

    /// 放上剪贴板 / 拖拽板的那个 URL。名字已经对得上就直接用原文件，
    /// 不为一个几百 MB 的引用型条目白复制一遍。
    static func pasteboardURL(for item: Item, source: URL) -> URL {
        let desired = preferredFilename(for: item, source: source)
        guard source.lastPathComponent != desired else { return source }
        return stage(source: source, item: item) ?? source
    }

    static func stage(source: URL, item: Item) -> URL? {
        purge(keeping: retainedDirectories)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "mnemo-share-\(UUID().uuidString)", directoryHint: .isDirectory)
        let destination = directory.appending(path: preferredFilename(for: item, source: source))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            directories.append(directory)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    /// 原始文件名优先——那是用户认得的那个名字。没有就用标题补上扩展名；
    /// 扩展名从源文件或记录的 UTI 推断，两者都没有才交出裸名字。
    static func preferredFilename(for item: Item, source: URL) -> String {
        if let name = item.originalFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty, !name.hasPrefix("."), URL(fileURLWithPath: name).pathExtension.isEmpty == false {
            return sanitized(name)
        }
        let base = sanitized(item.originalFilename ?? item.title)
        let ext = source.pathExtension.isEmpty
            ? (item.contentTypeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension } ?? "")
            : source.pathExtension
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private static func sanitized(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Mnemo" : String(cleaned.prefix(120))
    }

    static func purge(keeping count: Int) {
        guard directories.count > count else { return }
        let excess = directories.count - count
        for url in directories.prefix(excess) { try? FileManager.default.removeItem(at: url) }
        directories.removeFirst(excess)
    }
}
