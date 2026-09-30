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
    /// 已经落库的回答 id：用户点「停止」和稍后到达的 done 都走持久化，别插两条。
    private var persistedReplyID: String?
    /// 端点没回应时的看门狗：连续这么长时间一个事件都没有就中断这一轮。
    private static let idleTimeout: TimeInterval = 90
    private var watchdog: Task<Void, Never>?

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
        // 一条脏数据不该让整个历史列表消失：逐条解，坏行跳过。
        guard let rows = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] else {
            threads = []
            return
        }
        let decoder = JSONDecoder()
        threads = rows.compactMap { row in
            guard let data = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            return try? decoder.decode(ChatThread.self, from: data)
        }
    }

    func startNewThread() {
        // 手动开的新对话不能被 attach() 的「自动续上一段」顶掉。
        loadedInitialThread = true
        activeThreadId = nil
        activeThreadTitle = nil
        messages.removeAll()
        persistedReplyID = nil
        error = nil
    }

    func open(_ thread: ChatThread, using runtime: RuntimeHost) {
        guard runtime.state == .ready else { return }
        // 正在生成时点了别的会话：先把这一轮停掉（半截回答照样落库），再切过去。
        if isStreaming { stop() }
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
        persistedReplyID = messages.last?.role == .assistant ? messages.last?.id : nil
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

        guard ensureThread(book: book, firstMessage: trimmed, using: runtime) else { return }
        messages.append(Message(role: .user, text: trimmed))
        messages.append(Message(role: .assistant, text: ""))
        persistedReplyID = nil
        isStreaming = true
        error = nil
        contextNote = nil
        thinkingStartedAt = nil
        armWatchdog()

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
            watchdog?.cancel()
            self.error = String(describing: error)
            isStreaming = false
        }
    }

    func stop() {
        guard let runtime, let requestID else { return }
        _ = runtime.evaluate("ShudengApp.abortChat('\(requestID)')")
        watchdog?.cancel()
        isStreaming = false
        finishThinking()
        dropEmptyAssistant()
        // 停下来的半截回答也是回答：落库，别让历史里只剩提问。
        persistAssistantReply(using: runtime)
    }

    /// 顶部「清空」：开一段新对话，旧对话留在「会话」列表里，不会丢。
    func clear() {
        startNewThread()
    }

    // MARK: - 内部

    @discardableResult
    private func ensureThread(
        book: LibraryStore.Book?,
        firstMessage: String,
        using runtime: RuntimeHost
    ) -> Bool {
        guard activeThreadId == nil else { return true }
        var body: [String: Any] = ["title": String(firstMessage.prefix(24))]
        if let book { body["bookId"] = book.id }
        struct Created: Decodable { let id: String }
        let json = runtime.appJSONOr(
            "ShudengApp.createThread(\(Self.payload(body)))",
            fallback: "{}",
            timeout: 30
        )
        guard let created = try? JSONDecoder().decode(Created.self, from: Data(json.utf8)) else {
            // 静默失败的话，问题问了、回答也回来了，历史里却什么都没有。
            self.error = "这段对话没能存到本地，先检查一下存储空间再问一次。"
            return false
        }
        activeThreadId = created.id
        activeThreadTitle = String(firstMessage.prefix(24))
        // 会话建出来就立刻刷进会话列表：等回答结束才刷新的话，
        // 用户在生成过程中打开「会话」会以为这段对话没存下来。
        refreshThreads(using: runtime)
        return true
    }

    private func persistAssistantReply(using runtime: RuntimeHost) {
        guard let threadId = activeThreadId,
              let reply = messages.last,
              reply.role == .assistant,
              reply.id != persistedReplyID,
              !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        persistedReplyID = reply.id
        _ = runtime.appJSONOr(
            "ShudengApp.appendMessage(\(Self.payload(["threadId": threadId, "role": "assistant", "content": reply.text])))",
            fallback: "{}",
            timeout: 30
        )
        refreshThreads(using: runtime)
    }

    // MARK: - 看门狗

    /// 端点连不上或不再吐字时，界面以前会一直停在「正在生成…」，历史里也什么都留不下。
    /// 每次收到事件就重新计时，连续 90 秒没有任何动静就当这一轮失败。
    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isStreaming else { return }
            self.abortForTimeout()
        }
    }

    private func abortForTimeout() {
        guard isStreaming else { return }
        if let runtime, let requestID {
            _ = runtime.evaluate("ShudengApp.abortChat('\(requestID)')")
        }
        isStreaming = false
        finishThinking()
        dropEmptyAssistant()
        error = "模型 \(Int(Self.idleTimeout)) 秒没有回应，已经中断这一轮。检查一下端点和网络，或者再发一次。"
        if let runtime { persistAssistantReply(using: runtime) }
    }

    private func handle(requestID: String, eventJSON: String) {
        guard requestID == self.requestID,
              let data = eventJSON.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else { return }

        // 有事件就说明连接活着，重新计时。
        if type == "chunk" || type == "reasoning" || type == "context" { armWatchdog() }

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
            watchdog?.cancel()
            isStreaming = false
            finishThinking()
            if let runtime { persistAssistantReply(using: runtime) }
        case "error":
            watchdog?.cancel()
            error = event["message"] as? String ?? "未知错误"
            isStreaming = false
            finishThinking()
            dropEmptyAssistant()
            // 出错前半截回答已经显示在屏幕上了，也存下来。
            if let runtime { persistAssistantReply(using: runtime) }
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

    /// 这一轮一个字都没回来（连不上 / 立刻停止）：别在屏幕上留一个空的「…」气泡。
    private func dropEmptyAssistant() {
        guard let last = messages.last, last.role == .assistant,
              last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              last.reasoning.isEmpty
        else { return }
        messages.removeLast()
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
