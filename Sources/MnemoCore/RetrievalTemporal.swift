import Foundation

/// 一次检索里"要新的还是要旧的"。
///
/// "tii 那篇论文"和"tii 那篇论文最新一版"是两个问题：后者在主题匹配之上
/// 还有一个排序约束。没有这个字段时两句话在检索层完全一样，模型只能在一堆
/// 不带时间的候选里猜——而候选的顺序恰好是按相似度排的，猜中纯属运气。
public enum RecencyPreference: String, Sendable, Equatable, Codable {
    case newest
    case oldest
}

/// 说"最新 / 最旧"的那些说法。
///
/// 和 `ContentTypeVocabulary` 摆在一起是同一个理由：判断"这句话在要什么"的
/// 词表只能有一份。之前类型词表分散在两处，给一处补了词另一处不认，同一句话
/// 在搜索页和剪贴板路径得到不同结论。
public enum RecencyVocabulary {
    public static let newest = [
        "最新版", "最新一版", "最新", "最近一版", "最后一版", "最后那版",
        "新版", "新的那版", "更新的那", "改完的那",
        "latest version", "latest", "newest", "most recent", "last version",
    ]

    public static let oldest = [
        "最早的那", "最早那", "最早", "最旧", "旧版", "老版本",
        "第一版", "初版", "原始版本", "原来那版",
        "earliest", "oldest", "first version", "original version",
    ]

    /// 只判一次，且"最新"优先。
    ///
    /// "要最新的那版，不是最早那版"两个词都在，但主语是前者；反过来的说法
    /// 在真实提问里几乎不出现。与其做一套脆弱的否定解析，不如认定先出现的
    /// 意图词——判错的代价只是排序偏好，候选一个都不会少。
    public static func preference(in query: String) -> RecencyPreference? {
        let newestAt = firstIndex(of: newest, in: query)
        let oldestAt = firstIndex(of: oldest, in: query)
        switch (newestAt, oldestAt) {
        case (nil, nil): return nil
        case (.some, nil): return .newest
        case (nil, .some): return .oldest
        case (.some(let lhs), .some(let rhs)): return lhs <= rhs ? .newest : .oldest
        }
    }

    /// 这些词只表达排序意图，不是要找的东西：留在语义查询里会污染向量。
    /// 长的排前面，"最新版"要在"最新"之前被剥掉，否则会剩一个孤零零的"版"。
    public static var allWords: [String] {
        (newest + oldest).sorted { $0.count > $1.count }
    }

    private static func firstIndex(of words: [String], in query: String) -> Int? {
        words.compactMap { word -> Int? in
            guard let range = query.range(of: word, options: [.caseInsensitive]) else { return nil }
            return query.distance(from: query.startIndex, to: range.lowerBound)
        }.min()
    }
}

/// 条目在时间轴上的位置。
///
/// 分成两个时间，因为它们回答的是不同的问题：
///
/// - `contentDate` 是**内容自己的时间**。拖进来的文件用它自己的修改时间，
///   一篇三月定稿、今天才收进来的论文，内容时间就是三月。
/// - `capturedAt` 是它进入 Mnemo 的时间。
///
/// "最新一版"问的几乎总是前者：同一篇论文的两版很可能同一天被一起存进来，
/// 但文件自己的时间差着两个月。只有文件时间缺席（剪贴板文字、截图、链接）
/// 时才用入库时间顶替，并且如实标注给模型——否则它会把"我今天存的"误当成
/// "这是今天写的"。
public struct ItemTemporalFacts: Sendable, Equatable {
    public var contentDate: Date
    public var capturedAt: Date
    /// `contentDate` 是文件自己的时间（true），还是拿入库时间顶替的（false）。
    public var contentDateIsFromSource: Bool

    public init(contentDate: Date, capturedAt: Date, contentDateIsFromSource: Bool) {
        self.contentDate = contentDate
        self.capturedAt = capturedAt
        self.contentDateIsFromSource = contentDateIsFromSource
    }

    public init(item: Item) {
        capturedAt = item.createdAt
        if let source = item.sourceModificationDate {
            contentDate = source
            contentDateIsFromSource = true
        } else {
            contentDate = item.createdAt
            contentDateIsFromSource = false
        }
    }
}

/// 交给模型的时间一律是绝对时间。
///
/// 这条规则和待办提取那边是同一条：相对说法（"上周"、"三天前"）要求模型
/// 先知道"现在"，再自己做一次日期算术，而这正是它最容易错的地方。所以
/// 时间字段全部写成 ISO-8601，只把"现在"作为唯一的参照点单独给一次。
/// 相对说法仍然给，但只作为人类可读的补充，排序永远依据绝对值。
public enum RetrievalTemporalFormat {
    public static func absolute(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: date)
    }

    /// 只到天的键。给"最新 / 最近"这类相对结论的缓存划一条自然过期线：
    /// 同一句话跨天之后正确答案可能就变了。
    public static func dayKey(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        return formatter.string(from: date)
    }

    /// 人看的那一列。只说过去，因为库里的东西不会来自未来；真出现未来时间
    /// （文件系统时钟错乱）就如实说"晚于现在"，不要硬掰成"0 天前"。
    public static func relative(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < -60 { return "晚于当前时间" }
        if seconds < 3_600 { return "\(max(0, Int(seconds / 60))) 分钟前" }
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        // 按日历天算，不按流逝秒数除以 86400。前天中午到今天早上只有 46 小时，
        // 除下来是"1 天前"，而人说的是前天——上面两行本来就在用日历口径，
        // 这里再改用秒数等于同一个函数里有两套算法。
        let start = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        if days < 30 { return "\(max(1, days)) 天前" }
        if days < 365 { return "\(days / 30) 个月前" }
        return "\(days / 365) 年前"
    }
}

/// 同一份东西的不同版本。
public struct VersionedDocument: Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var filename: String?
    public var kind: ItemKind
    public var contentDate: Date
    /// 文档自己首页上印着的标题。
    ///
    /// 同一篇论文投两个地方，文件名会是 `iwqos2026-paper333-2.pdf` 和
    /// `Communication_Semantic_Aware_..._9_-6.pdf`，AI 起的标题又分别是
    /// "IWQoS2026论文摘要整理"和"面向MoE训练的通信语义感知RDMA丢包恢复"。
    /// 三个名字两两都对不上，只有首页上那行标题两版几乎一模一样。
    public var documentTitle: String?

    public init(
        id: UUID,
        title: String,
        filename: String?,
        kind: ItemKind,
        contentDate: Date,
        documentTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.filename = filename
        self.kind = kind
        self.contentDate = contentDate
        self.documentTitle = documentTitle
    }
}

/// 一族版本。`orderedIDs` 从新到旧。
public struct DocumentVersionFamily: Sendable, Equatable {
    /// 归一化后的名字主干，同时用作给模型看的分组名。
    public var stem: String
    public var kind: ItemKind
    public var orderedIDs: [UUID]

    public init(stem: String, kind: ItemKind, orderedIDs: [UUID]) {
        self.stem = stem
        self.kind = kind
        self.orderedIDs = orderedIDs
    }
}

/// 认出"这几条其实是同一份东西的不同版本"。
///
/// 全部本地、确定性，而且**只增加信息，不删除候选**。判断依据是名字主干：
/// 去掉扩展名、版本记号和日期戳之后剩下的部分相同，就当作一族。
///
/// 偏保守是刻意的。漏判一族只是回到现状——模型仍然拿到全部候选和每条的
/// 绝对时间，自己也能比出先后；而误判一族会把两份不相干的文件说成"同一份
/// 的新旧两版"，直接把错的那份顶到第一位。所以记号表宁短勿长，主干太短
/// 或太通用时一律不分族。
public enum DocumentVersioning {
    /// 主干短于这个长度就不足以指认一份文件。"报告"两个字在任何库里都能撞上。
    public static let minimumStemLength = 4

    /// 剥掉之后谁都一样的名字。它们不是主干，是分类词。
    private static let genericStems: Set<String> = [
        "论文", "文献", "报告", "文档", "笔记", "截图", "图片", "附件", "资料",
        "未命名", "新建文档", "无标题", "剪贴板",
        "paper", "report", "document", "doc", "notes", "note", "screenshot",
        "image", "img", "photo", "untitled", "clipboard", "download", "file",
        "pinlandclipboard", "mnemoclipboard",
    ]

    /// 版本记号。剥掉它们剩下的才是主干。
    private static let markerPatterns: [String] = [
        // v2 / V1.1 / _v3，前面允许有分隔符
        #"[ _\-.]*[vV]\d+(\.\d+)*"#,
        // 20260901 / 2026-09-01 / 2026_09_01
        #"[ _\-.]*\d{4}[-_.]?\d{2}[-_.]?\d{2}"#,
        // macOS / 浏览器的重名后缀：(1)、（2）、 2 副本
        #"[ _\-]*[\(（]\s*\d+\s*[\)）]"#,
        // 中文版本记号
        #"(第)?[一二三四五六七八九十百\d]+版"#,
        #"(最终版|终版|终稿|定稿|初稿|草稿|修改版|修订版|送审稿|副本|旧版|新版)"#,
        // 英文版本记号：必须整词出现，否则 "finalcut" 会被剥成 "cut"
        #"[ _\-.](final|draft|revised|rev\d*|copy|updated|update)(?=[ _\-.]|$)"#,
    ]

    /// 剥掉结尾序号之后，主干至少还要这么长才算数。
    ///
    /// 它比 `minimumStemLength` 高一截，因为这里要区分的是两种长得一样的东西：
    /// `..._Training__9_-6` 结尾那串数字是下载序号，`gpt-4`、`chapter-2` 结尾
    /// 那串是名字本身。没有语义可依靠时，长度是唯一还算可靠的信号——剥完只
    /// 剩三五个字符的，多半剥掉的是正主。
    public static let minimumCounterStemLength = 8

    /// 反复剥掉结尾的"分隔符 + 序号"。
    ///
    /// 真实文件名里的版本记号常常不写 v：Overleaf 导出是 `__9_-6`，浏览器
    /// 重复下载是 `-2`，而且可能叠加两层。一次只剥一层、剥到不能再剥为止，
    /// 比写一个能一次吃掉所有情况的巨型正则容易看懂，也容易在出错时定位。
    private static func strippingTrailingCounters(_ input: String) -> String {
        var value = input
        while true {
            let trimmed = value.replacingOccurrences(
                of: #"[ _\-.]+\d{1,3}[ _\-.]*$"#,
                with: "",
                options: .regularExpression
            )
            guard trimmed != value else { break }
            // 再剥就把名字本身剥掉了，就停在这一步。
            guard identifyingLength(of: trimmed) >= minimumCounterStemLength else { break }
            value = trimmed
        }
        return value
    }

    private static func identifyingLength(of value: String) -> Int {
        value.unicodeScalars.count { CharacterSet.alphanumerics.contains($0) }
    }

    /// 去掉扩展名。只砍最后一段，且长度可信——"报告.2026"里那不是扩展名。
    private static func dropExtension(_ filename: String) -> String {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return filename }
        let ext = filename[filename.index(after: dot)...]
        guard (1...5).contains(ext.count), ext.allSatisfy(\.isLetter) else { return filename }
        return String(filename[filename.startIndex..<dot])
    }

    /// 名字主干。判定不出来（太短、太通用）时返回 nil，表示"这条不参与分族"。
    public static func stem(title: String, filename: String?) -> String? {
        // 文件名优先：标题常常是 AI 生成的概括，同一份文件的两版可能被起成
        // 两个完全不同的标题，而文件名还带着原来的主干。
        let raw = filename.map(dropExtension) ?? title
        var value = raw.lowercased()
        for pattern in markerPatterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        value = strippingTrailingCounters(value)
        // 分隔符与标点全部去掉：tii_paper、tii-paper、tii paper 是同一个主干。
        value = value.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        guard value.count >= minimumStemLength, !genericStems.contains(value) else { return nil }
        return value
    }

    /// 一份文档手里所有能用来认亲的名字。
    private static func names(of document: VersionedDocument) -> [String] {
        [document.documentTitle, document.filename.map(dropExtension), document.title]
            .compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// 名字相似度参与分族的规模上限。
    ///
    /// 这一步是两两比较，O(n²)。库大到一定程度时代价不划算，而那时按名字
    /// 主干分族本来就够用——退化的后果只是少认出几组，不会错认。
    private static let similarityBudget = 300

    /// 把候选分族。只返回**成员多于一条**的族：一条的族不携带任何信息，
    /// 塞进提示词只会占预算。
    ///
    /// 两道判据，先严后松：
    /// 1. 名字主干完全相同——同一个文件下载了两次、改了个 v2，这一步就够；
    /// 2. 名字词集足够重合——同一篇论文改投一次，文件名和 AI 标题可能三个
    ///    名字两两都对不上，只有首页上那行标题还认得出来。
    ///
    /// 第二步做并查集合并，所以"A 和 B 像、B 和 C 像"会归成一族，即使 A 和 C
    /// 直接比不够像。版本链就是这么长出来的。
    public static func families(_ documents: [VersionedDocument]) -> [DocumentVersionFamily] {
        guard !documents.isEmpty else { return [] }
        var parent = Array(documents.indices)
        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var walk = index
            while parent[walk] != walk { let next = parent[walk]; parent[walk] = root; walk = next }
            return root
        }
        func union(_ lhs: Int, _ rhs: Int) {
            let a = find(lhs), b = find(rhs)
            guard a != b else { return }
            // 小的当根：族名取字典序最小的主干，结果与输入顺序无关。
            parent[max(a, b)] = min(a, b)
        }

        let stems = documents.map { stem(title: $0.title, filename: $0.filename) }

        // 第一步：主干相同的直接并。
        var byStem: [String: Int] = [:]
        for (index, document) in documents.enumerated() {
            guard let stem = stems[index] else { continue }
            let key = "\(document.kind.rawValue)\u{1}\(stem)"
            if let first = byStem[key] { union(first, index) } else { byStem[key] = index }
        }

        // 第二步：名字词集够像的再并。只在同一种类型之间比。
        if documents.count <= similarityBudget {
            let tokenized = documents.map(names)
            for i in documents.indices {
                for j in documents.index(after: i)..<documents.endIndex {
                    guard documents[i].kind == documents[j].kind,
                          find(i) != find(j),
                          DocumentNameSimilarity.namesTheSameDocument(tokenized[i], tokenized[j])
                    else { continue }
                    union(i, j)
                }
            }
        }

        var clusters: [Int: [Int]] = [:]
        for index in documents.indices { clusters[find(index), default: []].append(index) }

        return clusters
            .filter { $0.value.count > 1 }
            .compactMap { root, members -> DocumentVersionFamily? in
                // 族名取成员里字典序最小的那个主干；一个主干都没有（三份文件
                // 名字全是"未命名"之类）时，用最新那版的标题兜底。
                let stem = members.compactMap { stems[$0] }.min()
                let ordered = members
                    .map { documents[$0] }
                    // 同一时刻的两条要有稳定顺序，否则同一次查询两次跑出
                    // 不同的"最新版"。
                    .sorted {
                        $0.contentDate == $1.contentDate
                            ? $0.id.uuidString > $1.id.uuidString
                            : $0.contentDate > $1.contentDate
                    }
                guard let newest = ordered.first else { return nil }
                return DocumentVersionFamily(
                    stem: stem ?? newest.title,
                    kind: documents[root].kind,
                    orderedIDs: ordered.map(\.id)
                )
            }
            .sorted { $0.stem < $1.stem }
    }

    /// 每条候选在自己这一族里排第几（1 = 最新）。不属于任何一族的不出现。
    public static func ranks(_ documents: [VersionedDocument]) -> [UUID: (stem: String, rank: Int, total: Int)] {
        var result: [UUID: (stem: String, rank: Int, total: Int)] = [:]
        for family in families(documents) {
            for (index, id) in family.orderedIDs.enumerated() {
                result[id] = (family.stem, index + 1, family.orderedIDs.count)
            }
        }
        return result
    }
}

/// 从文档首页正文里抠出"这份文档自己叫什么"。
///
/// 只用首页：标题一定在那儿，而往后翻一页就全是正文，噪声远大于信号。
public enum DocumentTitleExtraction {
    /// 到这些行为止，标题肯定已经结束了。
    private static let stopPrefixes = [
        "abstract", "摘要", "keywords", "key words", "关键词", "index terms",
        "目录", "contents", "table of contents", "introduction", "1 introduction",
    ]

    /// 页眉页脚一类的固定件，夹在标题行之间也要剔掉。
    private static let boilerplatePatterns = [
        // IEEE TRANSACTIONS ON …, VOL. XX, NO. XX
        #"vol\.\s"#, #"\bno\.\s"#, #"issn"#, #"doi:"#, #"arxiv:"#,
        // "10 pages total" / "Paper #333, 10 pages total"
        #"pages?\s+total"#, #"^paper\s*#"#,
        // 纯页码、纯日期、邮箱、网址
        #"^\d+$"#, #"^page\s+\d+"#, #"@"#, #"https?://"#,
    ]

    /// 最多认几行、多长。标题超过四行的极少，而没有 Abstract 的文档如果不
    /// 设上限，会把整页正文都当成标题。
    private static let maximumLines = 4
    private static let maximumLength = 200

    public static func title(fromFirstPage text: String) -> String? {
        var picked: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let lowered = line.lowercased()
            if stopPrefixes.contains(where: { lowered.hasPrefix($0) }) { break }
            if isBoilerplate(lowered) {
                // 页眉出现在标题之前很常见（期刊名那一行）。标题还没开始就
                // 跳过它；已经开始了就说明标题结束了。
                if picked.isEmpty { continue }
                break
            }
            picked.append(line)
            if picked.count >= maximumLines { break }
        }
        guard !picked.isEmpty else { return nil }
        let joined = picked.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard joined.count >= 4 else { return nil }
        return String(joined.prefix(maximumLength))
    }

    private static func isBoilerplate(_ lowered: String) -> Bool {
        boilerplatePatterns.contains {
            lowered.range(of: $0, options: [.regularExpression]) != nil
        }
    }
}

/// 两个名字说的是不是同一份东西。
///
/// 用词集重合度，不用编辑距离：同一篇论文改投一次，标题里换掉一两个词
/// （"Hyperscale AI Training" → "MoE Training"）是常事，而按字符算距离时
/// 这种改动和"完全不同的标题"差不多远。词集看的是"多少个词是同一批"，
/// 正好对上"同一份东西的不同版本"这件事。
public enum DocumentNameSimilarity {
    /// 判为同一份东西的下限。0.6 是"三分之二的词一样"，一次改标题过得去，
    /// 两篇不同的论文过不去。
    public static let threshold = 0.6
    /// 光有比例不够：两个各两个词的名字撞上一个词就是 0.33，撞上两个就是 1。
    /// 必须同时有足够多的词真的重合。
    public static let minimumSharedTokens = 4

    /// 到处都是、不指认任何东西的词。
    private static let stopWords: Set<String> = [
        "the", "a", "an", "of", "for", "and", "or", "to", "in", "on", "with",
        "by", "at", "from", "via", "using", "based", "towards", "toward",
        "final", "draft", "copy", "version", "revised", "revision", "new", "old",
        "pdf", "docx", "doc", "paper", "report", "submission", "camera", "ready",
    ]

    /// 切词。
    ///
    /// 中文没有空格，按字符二元组切：连续两个汉字算一个词。分词器在这里不
    /// 划算——它要么带一本词典，要么切错专有名词，而二元组对"两段文字是不是
    /// 同一批字"这个问题已经足够。
    public static func tokens(_ text: String) -> Set<String> {
        var result: Set<String> = []
        var latin = ""
        var cjk: [Character] = []

        func flushLatin() {
            let word = latin.lowercased()
            latin = ""
            guard word.count >= 2, !stopWords.contains(word) else { return }
            result.insert(word)
        }
        func flushCJK() {
            defer { cjk = [] }
            guard cjk.count >= 2 else { return }
            for index in 0..<(cjk.count - 1) {
                result.insert(String(cjk[index...(index + 1)]))
            }
        }

        for character in text {
            if character.isCJK {
                flushLatin()
                cjk.append(character)
            } else if character.isLetter || character.isNumber {
                flushCJK()
                latin.append(character)
            } else {
                flushLatin()
                flushCJK()
            }
        }
        flushLatin()
        flushCJK()
        return result
    }

    public static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let shared = lhs.intersection(rhs).count
        guard shared >= minimumSharedTokens else { return 0 }
        return Double(shared) / Double(lhs.union(rhs).count)
    }

    /// 两份文档是不是同一份东西的两个版本。
    ///
    /// 每份文档手里有几个名字（首页标题、文件名、库里的标题），两两比，取最像
    /// 的一对。用最大值而不是把所有名字并成一袋：并起来会让"文件名很长"的
    /// 那一份稀释掉分母，本来该判亲的判不出来。
    public static func namesTheSameDocument(
        _ lhs: [String], _ rhs: [String]
    ) -> Bool {
        let left = lhs.map(tokens).filter { !$0.isEmpty }
        let right = rhs.map(tokens).filter { !$0.isEmpty }
        for a in left {
            for b in right where jaccard(a, b) >= threshold { return true }
        }
        return false
    }
}

private extension Character {
    /// 汉字区段。只用来决定按二元组还是按空格切词，不追求覆盖全部 CJK 扩展区。
    var isCJK: Bool {
        unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}
