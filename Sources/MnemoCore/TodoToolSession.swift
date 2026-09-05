import Foundation

/// 一次输入的一次工具会话。只收集提案，不写待办；工具回执必须完整返回给模型。
public enum TodoToolSession {
    public enum Failure: LocalizedError {
        case unfinished
        case truncated
        public var errorDescription: String? {
            switch self {
            case .unfinished: "待办理解未完成，请重试"
            case .truncated: "待办工具参数未完整返回，请重试"
            }
        }
    }

    public static func run(
        text: String,
        candidateIndices: Set<Int>,
        now: Date,
        calendar: Calendar,
        maximumRounds: Int = 8,
        isolation: isolated (any Actor)? = #isolation,
        complete: ([AIChatTurn]) async throws -> ChatCompletionOutput
    ) async throws -> [TodoRevisionDecision] {
        var turns: [AIChatTurn] = []
        var hasCurrentTime = false
        var resolvedDates: Set<Date> = []
        var decisions: [TodoRevisionDecision] = []
        var fingerprints: Set<String> = []
        var outstandingErrors = false
        for _ in 0..<maximumRounds {
            try Task.checkCancellation()
            let output = try await complete(turns)
            try Task.checkCancellation()
            guard !output.wasTruncated else { throw Failure.truncated }
            if output.toolCalls.isEmpty {
                guard !outstandingErrors else { throw Failure.unfinished }
                // 空结论是正常的“无待办”，不是再调用旧模型路径的理由。
                return decisions
            }
            turns.append(.assistant(text: output.text, toolCalls: output.toolCalls))
            let timeWasAvailable = hasCurrentTime
            let datesWereAvailable = resolvedDates
            outstandingErrors = false
            for call in output.toolCalls {
                var error: String?
                var result: AIToolResult?
                if call.name == TodoTools.currentTime.name {
                    result = TodoTools.execute(call, now: now, calendar: calendar)
                    hasCurrentTime = true
                } else if call.name == TodoTools.resolveTime.name {
                    if !timeWasAvailable {
                        error = "先读取 current_time 的回执，再调用 resolve_time。"
                    } else if let expression = call.arguments()["expression"] as? String,
                              text.contains(expression), !expression.isEmpty {
                        result = TodoTools.execute(call, now: now, calendar: calendar)
                        if let result,
                           let object = try? JSONSerialization.jsonObject(with: Data(result.contentJSON.utf8)) as? [String: Any],
                           let absolute = object["absolute"] as? String,
                           let date = ISO8601DateFormatter().date(from: absolute) {
                            resolvedDates.insert(date)
                        }
                    } else {
                        error = "expression 必须逐字来自这次输入，只传一件事的时间。"
                    }
                } else if TodoTools.isDecision(call.name) {
                    if !timeWasAvailable {
                        error = "先调用 current_time，读取回执后再提出待办。"
                    } else if let decision = TodoRevisionPrompt.decision(fromToolCall: call) {
                        let evidence = decision.evidence ?? ""
                        if evidence.isEmpty || !text.contains(evidence) {
                            error = "evidence 必须逐字引用这次输入，不能改写。"
                        } else if let index = decision.index, !candidateIndices.contains(index) {
                            error = "todo 编号不在本次清单中。"
                        } else if call.arguments()["dueAt"] is String, decision.dueAt == nil {
                            error = "dueAt 不是有效的 ISO 8601 时间。"
                        } else if let due = decision.dueAt, !datesWereAvailable.contains(due) {
                            error = "dueAt 必须来自此前 resolve_time 的回执，不能自行编写或同轮猜测。"
                        } else if decision.dueAt == nil,
                                  (decision.action == .create || decision.action == .reschedule),
                                  ChineseDateParser.firstDate(in: evidence, now: now, calendar: calendar) != nil {
                            error = "原文带时间，先调用 resolve_time，不能静默丢掉 dueAt。"
                        } else {
                            let key = "\(decision.action.rawValue)|\(decision.index ?? 0)|\(decision.title ?? "")|\(decision.dueAt?.timeIntervalSince1970 ?? 0)"
                            if !fingerprints.contains(key) {
                                if decisions.count < TodoRevisionPrompt.maximumDecisionCount {
                                    fingerprints.insert(key)
                                    decisions.append(decision)
                                } else { error = "本轮已达到待办数量上限，请结束。" }
                            }
                            if error == nil {
                                result = .init(callID: call.id, name: call.name,
                                               contentJSON: #"{"accepted":true,"persisted":false,"status":"已收集提案，等待本地确认策略"}"#)
                            }
                        }
                    } else { error = "工具参数缺失或无效，请按工具定义重试。" }
                } else { error = "未知工具，请使用本次提供的工具。" }
                if let error {
                    outstandingErrors = true
                    let data = try JSONSerialization.data(withJSONObject: ["error": error])
                    result = .init(callID: call.id, name: call.name,
                                   contentJSON: String(decoding: data, as: UTF8.self))
                }
                if let result { turns.append(.toolResult(result)) }
            }
        }
        throw Failure.unfinished
    }
}
