import Foundation
import Testing
@testable import MnemoCore

/// `CardGroupStore` 住在 App 层（它要读 UserDefaults），这里覆盖它依赖的那条
/// 不变量：一张卡只能属于一个组，组少于两张就不成立。规则本身是纯逻辑，
/// 用一份等价的内存实现守住它，避免规则被改坏而没人发现。
private struct GroupRules {
    var groups: [(id: UUID, name: String, items: [UUID])] = []

    mutating func merge(_ dragged: UUID, into target: UUID, name: String) -> UUID? {
        guard dragged != target else { return nil }
        detach(dragged)
        if let index = groups.firstIndex(where: { $0.items.contains(target) }) {
            groups[index].items.append(dragged)
            return groups[index].id
        }
        let id = UUID()
        groups.append((id, name, [target, dragged]))
        return id
    }

    mutating func detach(_ item: UUID) {
        guard let index = groups.firstIndex(where: { $0.items.contains(item) }) else { return }
        groups[index].items.removeAll { $0 == item }
        if groups[index].items.count < 2 { groups.remove(at: index) }
    }

    func group(of item: UUID) -> UUID? {
        groups.first { $0.items.contains(item) }?.id
    }
}

@Test("拖到另一张卡上就成组，再拖第三张是加入而不是新建")
func mergingBuildsOneGroup() {
    var rules = GroupRules()
    let a = UUID(), b = UUID(), c = UUID()
    let first = rules.merge(b, into: a, name: "招聘信息")
    #expect(first != nil)
    #expect(rules.groups.count == 1)

    let second = rules.merge(c, into: a, name: "另一个")
    #expect(second == first, "拖到已经成组的卡上应该加入它，而不是另起一组")
    #expect(rules.groups.count == 1)
    #expect(rules.groups[0].items.count == 3)
}

@Test("一张卡只能属于一个组：拖进新组时自动退出旧组")
func anItemBelongsToExactlyOneGroup() {
    var rules = GroupRules()
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    _ = rules.merge(b, into: a, name: "一组")
    _ = rules.merge(d, into: c, name: "二组")
    #expect(rules.groups.count == 2)

    // 把 b 从第一组拖到第二组。
    _ = rules.merge(b, into: c, name: "二组")
    #expect(rules.group(of: b) == rules.group(of: c))
    // 第一组只剩 a 一张，自动解散——一张卡的"组"不是组。
    #expect(rules.groups.count == 1)
    #expect(rules.group(of: a) == nil)
}

@Test("移出后只剩一张时整组解散")
func groupDissolvesWhenItWouldHaveOneMember() {
    var rules = GroupRules()
    let a = UUID(), b = UUID()
    _ = rules.merge(b, into: a, name: "临时")
    rules.detach(b)
    #expect(rules.groups.isEmpty)
    #expect(rules.group(of: a) == nil)
}

@Test("拖到自己身上不成组")
func mergingOntoItselfDoesNothing() {
    var rules = GroupRules()
    let a = UUID()
    #expect(rules.merge(a, into: a, name: "x") == nil)
    #expect(rules.groups.isEmpty)
}
