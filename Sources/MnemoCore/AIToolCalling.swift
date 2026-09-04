import Foundation

/// 一个可以交给模型自己调用的工具。
///
/// `parametersJSON` 是 JSON Schema 的字面量。不用 `[String: Any]`：那不是
/// Sendable，而这个类型要跨 actor 传。
public struct AITool: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }

    var parameters: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(parametersJSON.utf8)))
            as? [String: Any] ?? ["type": "object", "properties": [:]]
    }
}

/// 模型这一轮要调用的一个工具。
public struct AIToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    /// 原样的 JSON 字符串。解析交给各工具自己，客户端不假设参数长什么样。
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    public func arguments() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)))
            as? [String: Any] ?? [:]
    }
}

/// 一次工具调用的结果，发回给模型继续这一轮推理。
public struct AIToolResult: Sendable, Equatable {
    public var callID: String
    public var name: String
    public var contentJSON: String

    public init(callID: String, name: String, contentJSON: String) {
        self.callID = callID
        self.name = name
        self.contentJSON = contentJSON
    }
}

/// ReAct 循环里累积的对话。第一条用户消息仍由 `ChatCompletionInput.prompt`
/// 给出，这里只装它之后的往返。
public enum AIChatTurn: Sendable, Equatable {
    case assistant(text: String?, toolCalls: [AIToolCall])
    case toolResult(AIToolResult)
}

// MARK: - 待办工具

/// 待办理解这一轮可以调用的工具。
///
/// 为什么把时间做成工具，而不是像以前那样在本地先算好、再在提示词里写
/// "绝对时间是唯一依据、禁止自行重算"：
///
/// 那种写法把本地解析的**每一个错误**都变成了模型无法纠正的事实。实测
/// "今天下午八点开会，明天早上七点买咖啡"曾被归一化成「明天 下午八点」和
/// 「今天 早上七点」——日期和钟点在两个子句之间交叉配对，两个时间全错，
/// 而模型被明令禁止重算，于是必然照着错的答。
///
/// 做成工具之后：日期算术仍然**全部由本地完成**（模型最不擅长的就是这个），
/// 但由模型决定"要算哪个表达式"。它知道"下午八点"属于"开会"那一句，本地
/// 知道"下午八点"是几点——各自做各自擅长的那一半。
public enum TodoTools {

    public static let currentTime = AITool(
        name: "current_time",
        description: """
        取当前时间。任何涉及时间的判断都必须先调用它，不要凭空假设今天是几号。
        返回当前的绝对时间、时区和星期几。
        """,
        parametersJSON: #"{"type":"object","properties":{},"required":[]}"#
    )

    public static let resolveTime = AITool(
        name: "resolve_time",
        description: """
        把一句中文时间表达换算成绝对时间，例如「明天早上七点」「下周三」
        「9月5日下午两点」「三天后」。
        **只要待办带时间，就必须用这个工具换算，禁止自己推算日期。**
        每个任务分别调用一次，把那个任务自己那半句时间原样传进来——
        不要把两件事的时间合在一起问。
        """,
        parametersJSON: #"""
        {"type":"object","properties":{
          "expression":{"type":"string","description":"原文里的时间表达，逐字复制，例如「明天早上七点」"}
        },"required":["expression"]}
        """#
    )

    public static let createTodo = AITool(
        name: "create_todo",
        description: """
        新建一条待办。一件可以独立完成的事就调用一次；并列的多件事要分别调用，
        不要concat成一条。带时间的必须先用 resolve_time 拿到 dueAt。
        """,
        parametersJSON: #"""
        {"type":"object","properties":{
          "title":{"type":"string","description":"简短可执行的标题，例如「开会」「买咖啡」"},
          "dueAt":{"type":"string","description":"resolve_time 返回的绝对时间；没有时间就省略"},
          "kind":{"type":"string","enum":["general","foodPickup","packagePickup","delivery","travel","deadline","appointment"]},
          "service":{"type":"string","description":"商家或平台原名，例如「麦当劳」"},
          "code":{"type":"string","description":"取餐码/取件码/订单号，必须逐字来自原文"},
          "evidence":{"type":"string","description":"支撑这一条的最短原文片段，逐字复制"},
          "needsConfirmation":{"type":"boolean","description":"语义明确且证据直接时为 false"}
        },"required":["title","evidence"]}
        """#
    )

    public static let rescheduleTodo = AITool(
        name: "reschedule_todo",
        description: "把清单里已有的一条待办改到新时间。dueAt 必须来自 resolve_time。",
        parametersJSON: #"""
        {"type":"object","properties":{
          "todo":{"type":"integer","description":"清单里的编号"},
          "dueAt":{"type":"string"},
          "evidence":{"type":"string"}
        },"required":["todo","dueAt","evidence"]}
        """#
    )

    public static let completeTodo = AITool(
        name: "complete_todo",
        description: "把清单里已有的一条待办标记为已完成。",
        parametersJSON: #"""
        {"type":"object","properties":{
          "todo":{"type":"integer"},"evidence":{"type":"string"}
        },"required":["todo","evidence"]}
        """#
    )

    public static let cancelTodo = AITool(
        name: "cancel_todo",
        description: "取消清单里已有的一条待办。",
        parametersJSON: #"""
        {"type":"object","properties":{
          "todo":{"type":"integer"},"evidence":{"type":"string"}
        },"required":["todo","evidence"]}
        """#
    )

    public static let renameTodo = AITool(
        name: "rename_todo",
        description: "同一件事有了更具体的说法或范围时，改写清单里那一条的标题，可同时带新时间。",
        parametersJSON: #"""
        {"type":"object","properties":{
          "todo":{"type":"integer"},"title":{"type":"string"},
          "dueAt":{"type":"string"},"evidence":{"type":"string"}
        },"required":["todo","title","evidence"]}
        """#
    )

    public static let all: [AITool] = [
        currentTime, resolveTime, createTodo,
        rescheduleTodo, renameTodo, completeTodo, cancelTodo,
    ]

    /// 只读工具由本地直接执行，结果发回模型继续推理。
    ///
    /// 日期算术全部走 `ChineseDateParser`——和不带工具那条路是同一份实现，
    /// 两条路不会对"明天早上七点"给出不同答案。
    public static func execute(
        _ call: AIToolCall,
        now: Date,
        calendar: Calendar
    ) -> AIToolResult? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime]

        switch call.name {
        case currentTime.name:
            let weekdaySymbols = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            let index = calendar.component(.weekday, from: now) - 1
            return AIToolResult(
                callID: call.id,
                name: call.name,
                contentJSON: json([
                    "now": formatter.string(from: now),
                    "timeZone": calendar.timeZone.identifier,
                    "weekday": weekdaySymbols[max(0, min(6, index))],
                ])
            )

        case resolveTime.name:
            guard let expression = call.arguments()["expression"] as? String,
                  !expression.trimmingCharacters(in: .whitespaces).isEmpty else {
                return AIToolResult(
                    callID: call.id, name: call.name,
                    contentJSON: json(["error": "缺少 expression"])
                )
            }
            guard let reference = ChineseDateParser.firstDate(
                in: expression, now: now, calendar: calendar
            ) else {
                return AIToolResult(
                    callID: call.id, name: call.name,
                    contentJSON: json([
                        "expression": expression,
                        "resolved": false,
                        "hint": "这句话里没有可换算的时间；没有时间的待办可以不填 dueAt",
                    ])
                )
            }
            // 没写钟点的截止类说法（"周五交"）按当天 23:59 处理，和本地
            // 确定性层同一条规则；模型仍可按语境自己覆盖。
            let resolved = reference.hasExplicitTime
                ? reference.date
                : ChineseDateParser.endOfDay(reference.date, calendar: calendar)
            return AIToolResult(
                callID: call.id,
                name: call.name,
                contentJSON: json([
                    "expression": expression,
                    "resolved": true,
                    "absolute": formatter.string(from: resolved),
                    "hasExplicitTime": reference.hasExplicitTime,
                    "matched": reference.matchedText,
                ])
            )

        default:
            // 建/改/删这类不是"读"，不在这里执行：它们是本轮的结论，
            // 由调用方收集、逐条本地校验后才可能落库。
            return nil
        }
    }

    /// 这个工具是不是"模型给出的结论"，而不是可以本地直接执行的只读查询。
    public static func isDecision(_ name: String) -> Bool {
        [createTodo, rescheduleTodo, renameTodo, completeTodo, cancelTodo]
            .contains { $0.name == name }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
