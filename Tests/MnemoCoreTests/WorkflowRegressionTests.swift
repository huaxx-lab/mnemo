import Foundation
import Testing
@testable import MnemoCore

private let sampleText = "今天下午八点开会，明天早上七点要买一杯咖啡"
private let fixedNow = ISO8601DateFormatter().date(from: "2026-09-05T06:00:00+08:00")!
private var testCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}
private func call(_ id: String, _ name: String, _ args: String = "{}") -> AIToolCall {
    .init(id: id, name: name, argumentsJSON: args)
}

@Test("真实工具循环：时间查询之后创建两个独立提案，每次调用都有回执")
func todoToolRoundTrip() async throws {
    var round = 0
    let decisions = try await TodoToolSession.run(
        text: sampleText, candidateIndices: [], now: fixedNow, calendar: testCalendar
    ) { turns in
        defer { round += 1 }
        switch round {
        case 0:
            #expect(turns.isEmpty)
            return .init(text: "", toolCalls: [call("t", "current_time")])
        case 1:
            #expect(turns.count == 2)
            return .init(text: "", toolCalls: [
                call("r1", "resolve_time", #"{"expression":"今天下午八点"}"#),
                call("r2", "resolve_time", #"{"expression":"明天早上七点"}"#)
            ])
        case 2:
            let results = turns.compactMap { turn -> AIToolResult? in
                if case .toolResult(let result) = turn { return result }; return nil
            }
            #expect(results.count == 3)
            #expect(results[1].contentJSON.contains("2026-09-05T20:00:00+08:00"))
            #expect(results[2].contentJSON.contains("2026-09-06T07:00:00+08:00"))
            return .init(text: "", toolCalls: [
                call("c1", "create_todo", #"{"title":"开会","dueAt":"2026-09-05T20:00:00+08:00","evidence":"今天下午八点开会","highUncertainty":false}"#),
                call("c2", "create_todo", #"{"title":"买咖啡","dueAt":"2026-09-06T07:00:00+08:00","evidence":"明天早上七点要买一杯咖啡","highUncertainty":false}"#)
            ])
        default:
            #expect(turns.count == 8)
            return .init(text: "完成")
        }
    }
    #expect(round == 4)
    #expect(decisions.count == 2)
    #expect(decisions[0].dueAt == fixedNow.addingTimeInterval(14 * 3600))
    #expect(decisions[1].dueAt == fixedNow.addingTimeInterval(25 * 3600))
}

@Test("无待办不会重跑 JSON；未查询时间的结论不能执行")
func todoEmptyAndClockGate() async throws {
    var rounds = 0
    let empty = try await TodoToolSession.run(text: "普通文字", candidateIndices: [], now: fixedNow, calendar: testCalendar) { _ in
        rounds += 1
        return .init(text: "无")
    }
    #expect(empty.isEmpty && rounds == 1)
    await #expect(throws: TodoToolSession.Failure.self) {
        try await TodoToolSession.run(text: sampleText, candidateIndices: [], now: fixedNow, calendar: testCalendar, maximumRounds: 2) { _ in
            .init(text: "", toolCalls: [call("c", "create_todo", #"{"title":"开会","dueAt":"2026-09-05T20:00:00+08:00","evidence":"今天下午八点开会"}"#)])
        }
    }
}

@Test("工具截断或达到轮数上限，不把半成品当完成")
func todoIncompleteRoundFails() async {
    await #expect(throws: TodoToolSession.Failure.self) {
        try await TodoToolSession.run(text: sampleText, candidateIndices: [], now: fixedNow, calendar: testCalendar) { _ in
            .init(text: "", wasTruncated: true, toolCalls: [call("t", "current_time")])
        }
    }
}

@Test("界面分组投影：回收站、隐私及只剩一张的组不能喂给模型")
func groupsExcludeInvisibleMembers() {
    let a = Item(title: "A", kind: .text, holding: .inline("A"))
    var b = Item(title: "B", kind: .text, holding: .inline("B"))
    let group = CardGroup(name: "截图", itemIDs: [a.id, b.id])
    #expect(group.visible(in: [a, b])?.itemIDs == [a.id, b.id])
    b.state = .trashed
    #expect(group.visible(in: [a, b]) == nil)
    b.state = .active; b.isPrivate = true
    #expect(group.visible(in: [a, b]) == nil)
    #expect(group.itemIDs.count == 2, "投影不能删除用户保存的成员")
}

@Test("旧小红书只迁移笔记，手写标题优先于 AI 和网页")
func xhsMigrationProtectsUserTitles() {
    var item = Item(title: "小红书精彩内容分享", kind: .link,
                    holding: .inline("https://www.xiaohongshu.com/explore/abc"))
    #expect(LinkRefreshPolicy.needsMigration(item))
    #expect(LinkRefreshPolicy.mayReplaceTitle(item))
    item.titleOrigin = "user"
    #expect(!LinkRefreshPolicy.mayReplaceTitle(item))
    item.linkExtractionVersion = LinkRefreshPolicy.xiaohongshuVersion
    #expect(!LinkRefreshPolicy.needsMigration(item))
    item.holding = .inline("https://www.xiaohongshu.com/search_result?keyword=a")
    item.linkExtractionVersion = nil
    #expect(!LinkRefreshPolicy.needsMigration(item))
}

@Test("Mac 临时截图与文字均禁止处理，Pin 与手机来源可处理")
func strictTemporaryWorkPolicy() {
    for kind in [ItemKind.image, .text, .link] {
        var item = Item(title: "临时", kind: kind, holding: .inline("内容"), origin: .clipboard, isPinned: false)
        #expect(!ClipboardContentProcessingPolicy.permitsBackgroundWork(item, isFromNearbyDevice: false))
        #expect(ClipboardContentProcessingPolicy.permitsBackgroundWork(item, isFromNearbyDevice: true))
        item.isPinned = true
        #expect(ClipboardContentProcessingPolicy.permitsBackgroundWork(item, isFromNearbyDevice: false))
        item.isPrivate = true
        #expect(!ClipboardContentProcessingPolicy.permitsBackgroundWork(item, isFromNearbyDevice: true))
    }
}


@Test("显式启用的 MiniMax 待办工具联调，不写用户待办")
func liveTodoToolsWhenRequested() async throws {
    guard ProcessInfo.processInfo.environment["MNEMO_LIVE_TODO"] == "1" else { return }
    let credentialsURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".mnemo/credentials.json")
    struct Credentials: Decodable { var providers: [String: String] }
    let credentials = try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: credentialsURL))
    let key = try #require(credentials.providers["minimax"])
    let engine = AIExecutionEngine(client: AIProviderClient())
    let profile = AIRoutingProfile(fast: .init(providerID: "minimax", modelID: "MiniMax-M3", reasoningEffort: .low))
    var rounds = 0
    let decisions = try await TodoToolSession.run(text: sampleText, candidateIndices: [], now: fixedNow, calendar: testCalendar) { turns in
        rounds += 1
        let result = try await engine.complete(
            feature: .todoRevision, profile: profile, providers: ProviderPresets.all,
            catalog: BundledModelCatalog.snapshot, credentialLoader: { _ in key },
            system: TodoRevisionPrompt.toolSystem,
            prompt: TodoRevisionPrompt.toolUserMessage(text: sampleText, candidates: []),
            privacyText: sampleText, maxTokens: 2_400,
            tools: TodoTools.all, turns: turns
        )
        print("live round \(rounds): \(result.output.toolCalls.map(\.name).joined(separator: ","))")
        return result.output
    }
    #expect(decisions.count == 2)
    #expect(Set(decisions.compactMap(\.dueAt)) == Set([fixedNow.addingTimeInterval(14 * 3600), fixedNow.addingTimeInterval(25 * 3600)]))
    for decision in decisions {
        print("live decision: \(decision.title ?? "") @ \(decision.dueAt.map { ISO8601DateFormatter().string(from: $0) } ?? "nil")")
    }
}

@Test("全部页折叠手动组，链接页保留全部链接卡且不显示手动组筛选")
func groupedLinksRemainVisibleInLinkTab() {
    #expect(CardGroupProjection.shouldFold(tabKind: nil))
    #expect(CardGroupProjection.shouldShowManualFilters(tabKind: nil))
    #expect(!CardGroupProjection.shouldFold(tabKind: .link))
    #expect(!CardGroupProjection.shouldShowManualFilters(tabKind: .link))
    let links = [
        Item(title: "A", kind: .link, holding: .inline("https://example.com/a")),
        Item(title: "B", kind: .link, holding: .inline("https://example.com/b")),
    ]
    let group = CardGroup(name: "收藏", itemIDs: links.map(\.id))
    #expect(group.visible(in: links) != nil)
    #expect(links.filter { $0.kind == .link }.count == 2,
            "手动组只能改变全部页投影，不能从链接页数据源移除成员")
}

@Test("明确新建不默认确认，只有带具体不确定理由才确认")
func confirmationDefaultsToCertain() throws {
    let clear = try #require(TodoRevisionPrompt.decision(fromToolCall: call(
        "a", "create_todo", #"{"title":"开会","evidence":"今天开会","highUncertainty":false}"#
    )))
    #expect(!clear.needsConfirmation)
    let absentLegacy = try #require(TodoRevisionPrompt.decision(fromToolCall: call(
        "b", "create_todo", #"{"title":"开会","evidence":"今天开会"}"#
    )))
    #expect(!absentLegacy.needsConfirmation)
    #expect(TodoRevisionPrompt.decision(fromToolCall: call(
        "c", "create_todo", #"{"title":"开会","evidence":"今天开会","highUncertainty":true}"#
    )) == nil, "非常不确定却不说明理由，不能泛化成所有任务都弹确认")
    let uncertain = try #require(TodoRevisionPrompt.decision(fromToolCall: call(
        "d", "create_todo", #"{"title":"开会","evidence":"今天开会","highUncertainty":true,"uncertaintyReason":"说话主体不清"}"#
    )))
    #expect(uncertain.needsConfirmation)
}
