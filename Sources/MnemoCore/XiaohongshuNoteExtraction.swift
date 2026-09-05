import Foundation

/// 小红书笔记页里一次性抽出的结构化内容。
///
/// 标题、正文和配图必须来自**同一条 noteDetailMap 记录**。过去三个出口各自
/// 从 `"noteDetailMap"` 后面找“第一个同名字段”：在当前页面结构里通常碰巧
/// 正确，可一旦平台在目标记录前插入状态字段，标题和图片就可能各自拿到别的
/// 模块或别的笔记的数据。一次定位、一次解码，三个结果天然绑定在同一条笔记上。
public struct XiaohongshuNoteExtraction: Sendable, Equatable {
    public var title: String?
    public var text: String
    public var imageURLs: [URL]
    public var segments: [String]?

    public init(title: String?, text: String, imageURLs: [URL], segments: [String]? = nil) {
        self.title = title
        self.text = text
        self.imageURLs = imageURLs
        self.segments = segments
    }
}
