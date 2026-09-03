import AppKit
import Foundation
import MnemoCore
import SwiftUI

/// 模型理解出的展示元数据。
///
/// 它不参与「是不是待办」的判断，只负责把同一份事实用适合场景的方式展示：
/// 餐饮显示订单号和餐饮品牌，快递显示取件码与物流品牌，出行显示时间。
struct TodoPresentationMetadata: Codable, Equatable, Sendable {
    var kind: TodoRevisionDecision.Kind
    var service: String?
    var code: String?

    var isMeaningful: Bool {
        kind != .general || service?.isEmpty == false || code?.isEmpty == false
    }

    init(plan: TodoRevisionPlan) {
        kind = plan.kind
        service = plan.service
        code = plan.code
    }
}

/// 待办与来源 Pin 的展示元数据。
///
/// 用两个 namespace 存在同一个 JSON 里：来源 Pin 可以在用户还没确认待办时先
/// 显示品牌；确认后待办列表也能复用。回收站里的来源 ID 会被保留，只有彻底清空
/// 后才由 `prune` 删除。
@MainActor
enum TodoPresentationStore {
    private struct Persisted: Codable {
        var todos: [String: TodoPresentationMetadata] = [:]
        var items: [String: TodoPresentationMetadata] = [:]
    }

    private static let key = "Pinland.todoPresentation.v1"
    private static var value: Persisted = {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return Persisted()
        }
        return decoded
    }()

    static func record(todoID: UUID, plan: TodoRevisionPlan) {
        let metadata = TodoPresentationMetadata(plan: plan)
        guard metadata.isMeaningful else { return }
        value.todos[todoID.uuidString] = metadata
        persist()
    }

    static func record(itemID: UUID, plan: TodoRevisionPlan) {
        let metadata = TodoPresentationMetadata(plan: plan)
        guard metadata.isMeaningful else { return }
        value.items[itemID.uuidString] = metadata
        persist()
    }

    static func todo(_ id: UUID) -> TodoPresentationMetadata? {
        value.todos[id.uuidString]
    }

    static func item(_ id: UUID) -> TodoPresentationMetadata? {
        value.items[id.uuidString]
    }

    static func restore(todoID: UUID, metadata: TodoPresentationMetadata?) {
        let key = todoID.uuidString
        if let metadata {
            guard value.todos[key] != metadata else { return }
            value.todos[key] = metadata
        } else {
            guard value.todos.removeValue(forKey: key) != nil else { return }
        }
        persist()
    }

    static func forgetTodo(_ id: UUID) {
        restore(todoID: id, metadata: nil)
    }

    static func prune(todoIDs: Set<UUID>, itemIDs: Set<UUID>) {
        let todos = Set(todoIDs.map(\.uuidString))
        let items = Set(itemIDs.map(\.uuidString))
        let keptTodos = value.todos.filter { todos.contains($0.key) }
        let keptItems = value.items.filter { items.contains($0.key) }
        guard keptTodos.count != value.todos.count || keptItems.count != value.items.count else {
            return
        }
        value.todos = keptTodos
        value.items = keptItems
        persist()
    }

    private static func persist() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// 常用服务的视觉身份。
///
/// 别名只做「模型给出的 service 名 → 哪张图标」的归一化，不决定是否识别、
/// 不决定是否创建待办。模型返回不认识的服务时诚实退回类型图标与原名。
enum ServiceBrand: String, CaseIterable {
    case mcdonalds, kfc, taobao, tmall, jd, jdDelivery, meituan, meituanDelivery
    case eleme, cainiao, fengchao, sfExpress, chinaPost

    static func resolve(_ service: String?) -> ServiceBrand? {
        guard let raw = service?.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "'", with: "") else { return nil }
        let table: [(ServiceBrand, [String])] = [
            (.mcdonalds, ["麦当劳", "mcdonalds", "mcdonald’s", "金拱门"]),
            (.kfc, ["肯德基", "kfc"]),
            (.jdDelivery, ["京东外卖", "京东秒送"]),
            (.meituanDelivery, ["美团外卖"]),
            (.taobao, ["淘宝"]),
            (.tmall, ["天猫"]),
            (.jd, ["京东"]),
            (.meituan, ["美团"]),
            (.eleme, ["饿了么", "饿了吗", "淘宝闪购"]),
            (.cainiao, ["菜鸟"]),
            (.fengchao, ["丰巢"]),
            (.sfExpress, ["顺丰", "sfexpress"]),
            (.chinaPost, ["中国邮政", "邮政ems", "ems"]),
        ]
        return table.first { _, aliases in aliases.contains { raw.contains($0) } }?.0
    }

    var resourceName: String {
        switch self {
        case .mcdonalds: "mcdonalds"
        case .kfc: "kfc"
        case .taobao: "taobao"
        case .tmall: "tmall"
        case .jd: "jd"
        case .jdDelivery: "jd-delivery"
        case .meituan: "meituan"
        case .meituanDelivery: "meituan-delivery"
        case .eleme: "eleme"
        case .cainiao: "cainiao"
        case .fengchao: "fengchao"
        case .sfExpress: "sf-express"
        case .chinaPost: "china-post"
        }
    }

    var displayName: String {
        switch self {
        case .mcdonalds: "麦当劳"
        case .kfc: "肯德基"
        case .taobao: "淘宝"
        case .tmall: "天猫"
        case .jd: "京东"
        case .jdDelivery: "京东外卖"
        case .meituan: "美团"
        case .meituanDelivery: "美团外卖"
        case .eleme: "饿了么"
        case .cainiao: "菜鸟"
        case .fengchao: "丰巢"
        case .sfExpress: "顺丰"
        case .chinaPost: "中国邮政"
        }
    }

    var tint: Color {
        switch self {
        case .mcdonalds: Color(red: 1.0, green: 0.78, blue: 0.05)
        case .kfc, .jd, .jdDelivery, .sfExpress, .chinaPost: Color(red: 0.92, green: 0.16, blue: 0.14)
        case .taobao, .tmall: Color(red: 1.0, green: 0.30, blue: 0.05)
        case .meituan, .meituanDelivery: Color(red: 1.0, green: 0.78, blue: 0.0)
        case .eleme: Color(red: 0.12, green: 0.52, blue: 0.96)
        case .cainiao: Color(red: 0.14, green: 0.72, blue: 0.55)
        case .fengchao: Color(red: 0.96, green: 0.66, blue: 0.08)
        }
    }

    @MainActor
    var image: NSImage? {
        ServiceIconCache.image(named: resourceName)
    }
}

@MainActor
private enum ServiceIconCache {
    private static var cache: [String: NSImage?] = [:]

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let urls = [
            Bundle.module.url(forResource: name, withExtension: "jpg", subdirectory: "ServiceIcons"),
            Bundle.module.url(forResource: name, withExtension: "jpg"),
        ].compactMap { $0 }
        let image = urls.lazy.compactMap(NSImage.init(contentsOf:)).first
        cache[name] = image
        return image
    }
}

struct ServiceBrandIcon: View {
    let metadata: TodoPresentationMetadata
    var size: CGFloat

    private var brand: ServiceBrand? { ServiceBrand.resolve(metadata.service) }

    var body: some View {
        Group {
            if let brand, let image = brand.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                        .fill(fallbackTint.opacity(0.16))
                    Image(systemName: fallbackSymbol)
                        .font(.system(size: size * 0.48, weight: .semibold))
                        .foregroundStyle(fallbackTint)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
        }
        .accessibilityLabel(brand?.displayName ?? metadata.service ?? typeLabel)
    }

    private var fallbackSymbol: String {
        switch metadata.kind {
        case .foodPickup: "takeoutbag.and.cup.and.straw.fill"
        case .packagePickup, .delivery: "shippingbox.fill"
        case .travel: "location.fill"
        case .deadline: "calendar.badge.exclamationmark"
        case .appointment: "calendar"
        case .general: "checklist"
        }
    }

    private var fallbackTint: Color {
        brand?.tint ?? (metadata.kind == .travel ? Style.cool : Style.accent)
    }

    private var typeLabel: String {
        switch metadata.kind {
        case .foodPickup: "取餐"
        case .packagePickup: "取件"
        case .delivery: "配送"
        case .travel: "出行"
        case .deadline: "截止"
        case .appointment: "日程"
        case .general: "待办"
        }
    }
}
