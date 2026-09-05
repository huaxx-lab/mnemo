import Foundation
import Testing
@testable import MnemoCore

@Suite("待办工具")
struct AIToolCallingTests {

    private let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }()

    private var now: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 2; c.hour = 10
        return calendar.date(from: c)!
    }

    private func call(_ name: String, _ args: [String: Any]) -> AIToolCall {
        let data = try! JSONSerialization.data(withJSONObject: args)
        return AIToolCall(
            id: "call-1",
            name: name,
            argumentsJSON: String(decoding: data, as: UTF8.self)
        )
    }

    @Test("current_time 返回当前时间与星期几")
    func currentTimeTool() throws {
        let result = try #require(TodoTools.execute(
            call(TodoTools.currentTime.name, [:]), now: now, calendar: calendar
        ))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.contentJSON.utf8)) as? [String: Any]
        )
        #expect((object["now"] as? String)?.hasPrefix("2026-09-02") == true)
        #expect(object["weekday"] as? String == "周三")
        #expect(object["timeZone"] as? String == "Asia/Shanghai")
    }

    @Test("resolve_time 把中文表达换算成绝对时间")
    func resolveTimeTool() throws {
        let result = try #require(TodoTools.execute(
            call(TodoTools.resolveTime.name, ["expression": "明天早上七点"]),
            now: now, calendar: calendar
        ))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.contentJSON.utf8)) as? [String: Any]
        )
        #expect(object["resolved"] as? Bool == true)
        #expect((object["absolute"] as? String)?.hasPrefix("2026-09-03T07:00") == true)
    }

    @Test("resolve_time 解析不了时不报错，返回 resolved=false 让模型不填时间")
    func resolveTimeUnparseable() throws {
        let result = try #require(TodoTools.execute(
            call(TodoTools.resolveTime.name, ["expression": "有空的时候"]),
            now: now, calendar: calendar
        ))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.contentJSON.utf8)) as? [String: Any]
        )
        #expect(object["resolved"] as? Bool == false)
        #expect(object["hint"] != nil)
    }

    @Test("建/改/删是结论，不在本地循环里执行")
    func decisionToolsAreNotExecuted() {
        #expect(TodoTools.execute(
            call(TodoTools.createTodo.name, ["title": "开会", "evidence": "开会"]),
            now: now, calendar: calendar
        ) == nil)
        #expect(TodoTools.isDecision(TodoTools.createTodo.name))
        #expect(!TodoTools.isDecision(TodoTools.resolveTime.name))
    }

    @Test("工具调用能翻译成本地决策，字段完整")
    func toolCallBecomesDecision() throws {
        let decision = try #require(TodoRevisionPrompt.decision(fromToolCall: AIToolCall(
            id: "c1",
            name: TodoTools.createTodo.name,
            argumentsJSON: """
            {"title":"买咖啡","dueAt":"2026-09-03T07:00:00+08:00",
             "kind":"general","evidence":"明天早上七点要买一杯咖啡","needsConfirmation":false}
            """
        )))
        #expect(decision.action == .create)
        #expect(decision.title == "买咖啡")
        #expect(decision.dueAt != nil)
        #expect(decision.evidence == "明天早上七点要买一杯咖啡")
        #expect(decision.needsConfirmation == false)
    }

    @Test("没有 dueAt 的 create 也是合法决策")
    func createWithoutDueAt() throws {
        let decision = TodoRevisionPrompt.decision(fromToolCall: AIToolCall(
            id: "c1",
            name: TodoTools.createTodo.name,
            argumentsJSON: #"{"title":"取快递","evidence":"快递到了"}"#
        ))
        #expect(decision?.action == .create)
        #expect(decision?.dueAt == nil)
    }

    @Test("缺必填参数的工具调用返回 nil，不产出决策")
    func malformedCallProducesNoDecision() {
        #expect(TodoRevisionPrompt.decision(fromToolCall: AIToolCall(
            id: "c1", name: TodoTools.createTodo.name, argumentsJSON: #"{"title":"无证据"}"#
        )) == nil)
        #expect(TodoRevisionPrompt.decision(fromToolCall: AIToolCall(
            id: "c2", name: TodoTools.rescheduleTodo.name,
            argumentsJSON: #"{"todo":1}"#   // 缺 dueAt
        )) == nil)
    }
}
