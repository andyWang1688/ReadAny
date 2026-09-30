// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// 会话列表里的一行（core threads 表的摘要）。
struct ChatThread: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let bookId: String?
    let updatedAt: Double
    let messageCount: Double?
    let lastMessage: String?
}

/// 对话状态机：把 token 事件拼成气泡；对话本身落 core 的 threads / messages 表，
/// 杀掉 App 再回来还能从「会话」里接着聊。
@MainActor
final class ChatService: ObservableObject {
    struct Message: Identifiable {
        enum Role {
            case user
            case assistant
        }

        let id: String
        let role: Role
        var text: String
        /// 模型给出的思考过程（没有就是空串）。只留在内存里，不落库。
        var reasoning: String
        /// 这一轮思考花了多少秒；没有思考过程时为 nil。
        var thinkingSeconds: Double?

        init(
            id: String = UUID().uuidString,
            role: Role,
            text: String,
            reasoning: String = "",
            thinkingSeconds: Double? = nil
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.reasoning = reasoning
            self.thinkingSeconds = thinkingSeconds
        }
    }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var threads: [ChatThread] = []
    @Published private(set) var isStreaming = false
    @Published var error: String?
    /// 这一轮回答引用了书里几段原文（书建过语义索引时才有）。
    @Published private(set) var contextNote: String?
    @Published private(set) var activeThreadId: String?
    /// 当前这段对话的标题（nav 标题用）。
    @Published private(set) var activeThreadTitle: String?

    private weak var runtime: RuntimeHost?
    private var requestID: String?
    private var observerID: UUID?
    private var loadedInitialThread = false
    private var thinkingStartedAt: Date?

    func attach(to runtime: RuntimeHost) {
        self.runtime = runtime
        if observerID == nil {
            observerID = runtime.addChatObserver(owner: self) { [weak self] requestID, eventJSON in
                self?.handle(requestID: requestID, eventJSON: eventJSON)
            }
        }
        guard runtime.state == .ready else { return }
        refreshThreads(using: runtime)
        if !loadedInitialThread, messages.isEmpty, let latest = threads.first {
            loadedInitialThread = true
            open(latest, using: runtime)
        }
    }

    // MARK: - 会话线程

    func refreshThreads(using runtime: RuntimeHost) {
        guard runtime.state == .ready else { return }
        let json = runtime.appJSONOr("ShudengApp.listThreads({})", fallback: "[]", timeout: 60)
        threads = (try? JSONDecoder().decode([ChatThread].self, from: Data(json.utf8))) ?? []
    }

    func startNewThread() {
        // 手动开的新对话不能被 attach() 的「自动续上一段」顶掉。
        loadedInitialThread = true
        activeThreadId = nil
        activeThreadTitle = nil
        messages.removeAll()
        error = nil
    }

    func open(_ thread: ChatThread, using runtime: RuntimeHost) {
        guard !isStreaming, runtime.state == .ready else { return }
        struct Loaded: Decodable {
            struct Stored: Decodable {
                let id: String
                let role: String
                let content: String
            }

            let id: String
            let messages: [Stored]
        }
        let json = runtime.appJSONOr(
            "ShudengApp.loadThread(\(Self.payload(["id": thread.id])))",
            fallback: "{}",
            timeout: 60
        )
        guard let loaded = try? JSONDecoder().decode(Loaded.self, from: Data(json.utf8)) else { return }
        activeThreadId = loaded.id
        activeThreadTitle = thread.title
        messages = loaded.messages.map {
            Message(id: $0.id, role: $0.role == "assistant" ? .assistant : .user, text: $0.content)
        }
        error = nil
    }

    func delete(_ thread: ChatThread, using runtime: RuntimeHost) {
        guard runtime.state == .ready else { return }
        _ = runtime.appJSONOr(
            "ShudengApp.deleteThread(\(Self.payload(["id": thread.id])))",
            fallback: "\"ok\"",
            timeout: 60
        )
        if activeThreadId == thread.id { startNewThread() }
        refreshThreads(using: runtime)
    }

    // MARK: - 对话

    func send(
        _ text: String,
        book: LibraryStore.Book?,
        contextText: String?,
        settings: AISettings,
        skill: AISkill? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming, let runtime, runtime.state == .ready else { return }

        guard settings.isConfigured else {
            error = "先在设置里填模型名和端点"
            return
        }

        ensureThread(book: book, firstMessage: trimmed, using: runtime)
        messages.append(Message(role: .user, text: trimmed))
        messages.append(Message(role: .assistant, text: ""))
        isStreaming = true
        error = nil
        contextNote = nil
        thinkingStartedAt = nil

        if let threadId = activeThreadId {
            _ = runtime.appJSONOr(
                "ShudengApp.appendMessage(\(Self.payload(["threadId": threadId, "role": "user", "content": trimmed])))",
                fallback: "{}",
                timeout: 30
            )
        }

        let requestID = UUID().uuidString
        self.requestID = requestID

        var payload: [String: Any] = [
            "requestId": requestID,
            "provider": settings.provider.rawValue,
            "baseUrl": settings.baseURL,
            "apiKey": settings.apiKey,
            "model": settings.model,
            "text": trimmed,
            "language": HostEnvironment.deviceLocaleIdentifier(),
        ]
        if let skill {
            payload["skillId"] = skill.id
            if let param = skill.inputParam {
                // 需要输入参数的技能（解释概念 / 查术语 / 翻译）：输入框那段文字就是参数值。
                payload["skillParams"] = [param: trimmed]
            }
        }
        if let contextText, !contextText.isEmpty {
            payload["contextText"] = String(contextText.prefix(6000))
        }
        if let book {
            payload["book"] = [
                "id": book.id,
                "filePath": book.filePath,
                "format": "epub",
                "meta": ["title": book.title, "author": book.author],
                "progress": 0,
                "isVectorized": false,
                "vectorizeProgress": 0,
                "tags": [String](),
                "addedAt": 0,
                "updatedAt": 0,
            ]
        }
        payload["history"] = Array(messages.dropLast(2)).suffix(20).map { message in
            ["role": message.role == .user ? "user" : "assistant", "text": message.text]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }

        do {
            // 不阻塞主线程：token 由 __nativeChatEvent 推给 handle()，结束时再收 done。
            try runtime.startApp("ShudengApp.chat(\(json))")
        } catch {
            self.error = String(describing: error)
            isStreaming = false
        }
    }

    func stop() {
        guard let runtime, let requestID else { return }
        _ = runtime.evaluate("ShudengApp.abortChat('\(requestID)')")
        isStreaming = false
    }

    /// 顶部「清空」：开一段新对话，旧对话留在「会话」列表里，不会丢。
    func clear() {
        startNewThread()
    }

    // MARK: - 内部

    private func ensureThread(book: LibraryStore.Book?, firstMessage: String, using runtime: RuntimeHost) {
        guard activeThreadId == nil else { return }
        var body: [String: Any] = ["title": String(firstMessage.prefix(24))]
        if let book { body["bookId"] = book.id }
        struct Created: Decodable { let id: String }
        let json = runtime.appJSONOr(
            "ShudengApp.createThread(\(Self.payload(body)))",
            fallback: "{}",
            timeout: 30
        )
        guard let created = try? JSONDecoder().decode(Created.self, from: Data(json.utf8)) else { return }
        activeThreadId = created.id
    }

    private func persistAssistantReply(using runtime: RuntimeHost) {
        guard let threadId = activeThreadId,
              let reply = messages.last,
              reply.role == .assistant,
              !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        _ = runtime.appJSONOr(
            "ShudengApp.appendMessage(\(Self.payload(["threadId": threadId, "role": "assistant", "content": reply.text])))",
            fallback: "{}",
            timeout: 30
        )
        refreshThreads(using: runtime)
    }

    private func handle(requestID: String, eventJSON: String) {
        guard requestID == self.requestID,
              let data = eventJSON.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else { return }

        switch type {
        case "chunk":
            guard let text = event["text"] as? String, !text.isEmpty else { return }
            appendToAssistant(text)
        case "reasoning":
            guard let text = event["text"] as? String, !text.isEmpty else { return }
            if thinkingStartedAt == nil { thinkingStartedAt = Date() }
            appendReasoning(text)
        case "context":
            let count = event["count"] as? Int ?? 0
            guard count > 0 else { return }
            let chapters = (event["chapters"] as? [String] ?? []).filter { !$0.isEmpty }
            contextNote = chapters.isEmpty
                ? "已引用书里的 \(count) 段原文"
                : "已引用：\(chapters.prefix(2).joined(separator: "、"))"
        case "done":
            isStreaming = false
            finishThinking()
            if let runtime { persistAssistantReply(using: runtime) }
        case "error":
            error = event["message"] as? String ?? "未知错误"
            isStreaming = false
            finishThinking()
        default:
            break
        }
    }

    private func appendToAssistant(_ text: String) {
        guard let index = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        messages[index].text += text
    }

    private func appendReasoning(_ text: String) {
        guard let index = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        messages[index].reasoning += text
    }

    /// 思考结束：把「想了多久」记到这轮回答上，界面上折叠成一条「已思考 N 秒」。
    private func finishThinking() {
        defer { thinkingStartedAt = nil }
        guard let started = thinkingStartedAt,
              let index = messages.lastIndex(where: { $0.role == .assistant }),
              !messages[index].reasoning.isEmpty
        else { return }
        messages[index].thinkingSeconds = max(0.5, Date().timeIntervalSince(started))
    }

    private static func payload(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
