// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

/// 替身只负责宿主边界：收取 API 调用、重放网络已经排队的事件。
@MainActor
final class RuntimeHost {
    enum State { case ready }
    var state: State = .ready
    let rootDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chat-state-" + UUID().uuidString)
    init() { try! FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: rootDirectory) }
    var observer: ((String, String) -> Void)?
    var writes: [[String: Any]] = []
    var aborts = 0
    var requestID = ""
    var lastPayload: [String: Any] = [:]
    var failAssistantWrites = false
    var failUserWrites = false
    var failPrefix = ""
    var listResponse = "[]"
    var loadResponse: String?

    func addChatObserver(owner: AnyObject, _ callback: @escaping (String, String) -> Void) -> UUID {
        observer = callback
        return UUID()
    }

    func appJSONOr(_ expression: String, fallback: String = "{}", timeout: TimeInterval = 30) -> String {
        (try? appJSON(expression, timeout: timeout)) ?? fallback
    }

    func appJSON(_ expression: String, timeout: TimeInterval = 30) throws -> String? {
        if !failPrefix.isEmpty, expression.hasPrefix(failPrefix) {
            throw NSError(domain: "fixture-write-failure", code: 1)
        }
        if expression.hasPrefix("ShudengApp.renameThread") {
            return String(decoding: try JSONSerialization.data(withJSONObject: ["ok": true, "title": payload(expression)["title"]!]), as: UTF8.self)
        }
        if expression.hasPrefix("ShudengApp.setThreadBook") { return #"{"ok":true}"# }
        if expression.hasPrefix("ShudengApp.listThreads") { return listResponse }
        if expression.hasPrefix("ShudengApp.createThread") { return #"{"id":"A"}"# }
        if expression.hasPrefix("ShudengApp.loadThread") {
            if let loadResponse { return loadResponse }
            return #"{"id":"B","messages":[{"id":"reply-B","role":"assistant","content":"B原回答"}]}"#
        }
        if expression.hasPrefix("ShudengApp.appendMessage") {
            let message = payload(expression)
            let assistant = message["role"] as? String == "assistant"
            if assistant ? failAssistantWrites : failUserWrites {
                throw NSError(domain: "fixture-write-failure", code: 1)
            }
            writes.append(message)
            return String(decoding: try JSONSerialization.data(withJSONObject: ["id": message["id"] ?? "saved", "createdAt": 1]), as: UTF8.self)
        }
        if expression.hasPrefix("ShudengApp.deleteThread") { return "ok" }
        return "{}"
    }

    func startApp(_ expression: String) throws {
        lastPayload = payload(expression)
        requestID = lastPayload["requestId"] as! String
    }

    func evaluate(_ expression: String) -> String? {
        if expression.hasPrefix("ShudengApp.abortChat") { aborts += 1 }
        return nil
    }

    func emit(_ type: String, text: String = "") {
        let data = try! JSONSerialization.data(withJSONObject: ["type": type, "text": text, "message": "端点错误"])
        observer?(requestID, String(decoding: data, as: UTF8.self))
    }

    var assistantWrites: [[String: Any]] { writes.filter { $0["role"] as? String == "assistant" } }

    private func payload(_ expression: String) -> [String: Any] {
        let start = expression.index(after: expression.firstIndex(of: "(")!)
        let json = expression[start..<expression.index(before: expression.endIndex)]
        return try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }
}

struct LibraryStore { struct Book { let id: String; let filePath: String; let title: String; let author: String } }
struct AISettings {
    enum Provider: String { case openai }
    let provider = Provider.openai
    let baseURL = "http://fixture.invalid/v1"
    let apiKey = "fixture"
    let model = "fixture"
    let isConfigured = true
}
struct AISkill { let id: String; let inputParam: String? }
struct HostEnvironment { static func deviceLocaleIdentifier() -> String { "zh-CN" } }

@main struct ChatServiceStateTests {
    @MainActor static func main() {
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        func start() -> (RuntimeHost, ChatService) {
            let runtime = RuntimeHost()
            let chat = ChatService()
            chat.attach(to: runtime)
            chat.send("问A", book: nil, contextText: nil, settings: AISettings())
            runtime.emit("chunk", text: "A半截回答")
            return (runtime, chat)
        }

        let (clearedRuntime, cleared) = start()
        cleared.clear()
        expect(!cleared.isStreaming && cleared.messages.isEmpty && cleared.activeThreadId == nil,
               "清空后应立即可以发起新对话")
        expect(clearedRuntime.aborts == 1 && clearedRuntime.assistantWrites.count == 1,
               "清空应停止旧请求并保存已有回答")
        clearedRuntime.emit("chunk", text: "迟到A")
        clearedRuntime.emit("done")
        expect(cleared.messages.isEmpty && clearedRuntime.assistantWrites.count == 1,
               "清空后旧事件不得重建气泡或重复保存")

        let (switchedRuntime, switched) = start()
        switched.open(ChatThread(id: "B", title: "B", bookId: nil, updatedAt: 0, messageCount: nil, lastMessage: nil),
                      using: switchedRuntime)
        switchedRuntime.emit("chunk", text: "迟到A")
        switchedRuntime.emit("done")
        expect(switched.activeThreadId == "B" && switched.messages.last?.text == "B原回答",
               "A 的迟到事件不得修改 B 的历史")
        expect(switchedRuntime.assistantWrites.count == 1 && switchedRuntime.assistantWrites[0]["threadId"] as? String == "A",
               "切换会话应将半截回答保存到原会话")

        for terminal in ["done", "error"] {
            let (runtime, chat) = start()
            runtime.emit(terminal)
            runtime.emit("chunk", text: "终态后迟到")
            runtime.emit("done")
            expect(!chat.isStreaming && chat.messages.last?.text == "A半截回答",
                   "\(terminal) 后的事件不得继续修改回答")
            expect(runtime.assistantWrites.count == 1,
                   "\(terminal) 必须且只能保存一次回答")
        }
        let (failedRuntime, failedChat) = start()
        failedRuntime.failAssistantWrites = true
        failedRuntime.emit("done")
        expect(failedChat.error != nil && failedChat.hasUnsavedReply && failedRuntime.assistantWrites.isEmpty,
               "回答保存失败必须显示错误")
        failedChat.startNewThread()
        expect(failedChat.activeThreadId == "A" && failedChat.messages.last?.text == "A半截回答",
               "保存失败时新建对话不得覆盖未保存回答")
        failedChat.open(ChatThread(id: "B", title: "B", bookId: nil, updatedAt: 0, messageCount: nil, lastMessage: nil), using: failedRuntime)
        expect(failedChat.activeThreadId == "A", "保存失败时切换历史不得丢失回答")
        failedChat.send("下一轮", book: nil, contextText: nil, settings: AISettings())
        expect(!failedChat.isStreaming && failedChat.messages.last?.text == "A半截回答",
               "保存失败时下一轮不能覆盖旧回答")
        let replyID = failedChat.messages.last?.id
        failedRuntime.failAssistantWrites = false
        failedChat.stop()
        expect(!failedChat.hasUnsavedReply && failedChat.error == nil,
               "重试成功后应清除未保存标记与对应提示")
        expect(failedRuntime.assistantWrites.count == 1 && failedRuntime.assistantWrites.first?["id"] as? String == replyID,
               "恢复后应使用稳定消息 ID 重试保存")
        failedChat.startNewThread()
        expect(failedChat.messages.isEmpty && failedRuntime.assistantWrites.count == 1,
               "重试成功后可新建且不会重复保存")

        let userRuntime = RuntimeHost()
        let userChat = ChatService()
        userChat.attach(to: userRuntime)
        userRuntime.failUserWrites = true
        userChat.send("不能落库的问题", book: nil, contextText: nil, settings: AISettings())
        expect(userChat.error != nil && !userChat.isStreaming && userChat.messages.isEmpty && userRuntime.requestID.isEmpty,
               "用户消息保存失败不得发送模型请求或制造虚假历史")

        let metadataHost = RuntimeHost(), metadata = ChatService()
        metadata.attach(to: metadataHost)
        let thread = ChatThread(id: "B", title: "original", bookId: "book-A", updatedAt: 0, messageCount: nil, lastMessage: nil)
        metadata.open(thread, using: metadataHost)
        metadataHost.failPrefix = "ShudengApp.renameThread"
        metadata.rename(thread, to: "new title", using: metadataHost)
        expect(metadata.activeThreadTitle == "original" && metadata.error != nil,
               "失败的重命名不能更改当前标题")
        metadataHost.failPrefix = "ShudengApp.setThreadBook"
        metadata.setBook("book-B", using: metadataHost)
        expect(metadata.activeBookId == "book-A" && metadata.error != nil,
               "换书失败不能把当前上下文改成另一书")
        metadata.move(thread, to: nil, using: metadataHost)
        expect(metadata.activeBookId == "book-A" && metadata.error != nil,
               "移动会话失败不能更改当前分组")
        metadataHost.failPrefix = ""
        metadata.rename(thread, to: "new title", using: metadataHost)
        metadata.setBook("book-B", using: metadataHost)
        expect(metadata.activeThreadTitle == "new title" && metadata.activeBookId == "book-B" && metadata.error == nil,
               "恢复后重试必须改变已持久化的元数据")


        let readHost = RuntimeHost(), readChat = ChatService()
        readHost.listResponse = #"[{"id":"B","title":"B","updatedAt":0}]"#
        readChat.attach(to: readHost)
        readHost.failPrefix = "ShudengApp.listThreads"
        readChat.refreshThreads(using: readHost)
        expect(readChat.threads.map(\.id) == ["B"] && readChat.error != nil,
               "读取历史失败不能把已加载列表清空，必须显示错误")
        readHost.failPrefix = ""
        readHost.listResponse = "{}"
        readChat.refreshThreads(using: readHost)
        expect(readChat.threads.map(\.id) == ["B"] && readChat.error != nil,
               "无效列表响应不能伪装成空历史")
        readHost.listResponse = "[]"
        readChat.refreshThreads(using: readHost)
        expect(readChat.threads.isEmpty && readChat.error == nil,
               "重试成功的真实空列表应生效并清除读取错误")
        readHost.failPrefix = "ShudengApp.loadThread"
        readChat.open(ChatThread(id: "C", title: "C", bookId: nil, updatedAt: 0, messageCount: nil, lastMessage: nil), using: readHost)
        expect(readChat.activeThreadId == "B" && readChat.messages.last?.text == "B原回答" && readChat.error != nil,
               "打开失败应保留旧内容并报告错误")
        readHost.failPrefix = ""
        readHost.loadResponse = #"{"id":"wrong","messages":[]}"#
        readChat.open(ChatThread(id: "C", title: "C", bookId: nil, updatedAt: 0, messageCount: nil, lastMessage: nil), using: readHost)
        expect(readChat.activeThreadId == "B" && readChat.error != nil,
               "错误会话ID的响应不能替换当前对话")

        let retryHost = RuntimeHost(), retryChat = ChatService()
        retryChat.attach(to: retryHost)
        let book = LibraryStore.Book(id: "book-A", filePath: "a.epub", title: "A", author: "作者")
        retryChat.send("原问题", book: book, contextText: "选中的原文", settings: AISettings(),
                       skill: AISkill(id: "explain", inputParam: "term"))
        let originalID = retryChat.messages.first?.id
        let originalRequest = retryHost.requestID
        retryHost.emit("reasoning", text: "只有思考，没有答案")
        retryHost.emit("error")
        expect(retryChat.canRetryResponse && retryChat.messages.count == 1 && retryHost.assistantWrites.isEmpty,
               "只有思考的失败请求不能保存为回答，必须能重试")
        expect(retryChat.retryResponse(settings: AISettings()), "失败请求应能直接重试")
        expect(retryChat.messages.first?.id == originalID && retryHost.writes.count == 1,
               "重试必须复用原问题，不能重复写入用户消息")
        expect((retryHost.lastPayload["history"] as? [[String: String]])?.isEmpty == true,
               "重试的 history 不能再包含本次问题")
        expect(retryHost.lastPayload["contextText"] as? String == "选中的原文"
               && retryHost.lastPayload["skillId"] as? String == "explain"
               && (retryHost.lastPayload["book"] as? [String: Any])?["id"] as? String == "book-A",
               "重试必须保留原书籍、选区和技能上下文")
        retryHost.observer?(originalRequest, #"{"type":"chunk","text":"旧请求迟到"}"#)
        expect(retryChat.messages.last?.text == "" && !retryChat.canRetryResponse,
               "重试期间不能重复发送，旧请求不得污染新回答")
        retryHost.emit("error")
        expect(retryChat.retryResponse(settings: AISettings()) && retryHost.writes.count == 1,
               "连续失败重试不能复制用户消息")
        retryHost.emit("chunk", text: "成功答案")
        retryHost.emit("done")
        expect(!retryChat.canRetryResponse && retryChat.messages.count == 2 && retryHost.assistantWrites.count == 1,
               "重试成功后只保存一条有效答案")

        let (partialHost, partialChat) = start()
        partialHost.emit("error")
        expect(!partialChat.canRetryResponse && partialChat.messages.last?.text == "A半截回答",
               "已有部分答案时不能用空回答重试覆盖它")
        retryChat.send("新问题", book: nil, contextText: nil, settings: AISettings())
        retryHost.emit("error")
        retryChat.startNewThread()
        expect(!retryChat.canRetryResponse && !retryChat.retryResponse(settings: AISettings()),
               "离开失败会话后不能误重试上一会话")

        guard failures == 0 else { exit(1) }
        print("ChatService state regression tests passed (12 scenarios)")
    }
}
