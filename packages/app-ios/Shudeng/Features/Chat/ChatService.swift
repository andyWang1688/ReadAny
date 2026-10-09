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
    @Published private(set) var hasUnsavedReply = false
    /// 这一轮回答引用了书里几段原文（书建过语义索引时才有）。
    @Published private(set) var contextNote: String?
    @Published private(set) var activeThreadId: String?
    /// 当前这段对话的标题（nav 标题用）。
    @Published private(set) var activeThreadTitle: String?
    /// 当前这段对话挂在哪本书上；nil ＝ 不指定书的「临时对话」。
    @Published private(set) var activeBookId: String?

    private weak var runtime: RuntimeHost?
    private var requestID: String?
    private var observerID: UUID?
    private var loadedInitialThread = false
    private var thinkingStartedAt: Date?
    /// 已经落库的回答 id：用户点「停止」和稍后到达的 done 都走持久化，别插两条。
    private var persistedReplyID: String?
    private var pendingUser: (threadId: String, message: Message)?
    private struct PendingReply: Codable, Equatable {
        let threadId: String
        let messageId: String
        let text: String

        var isValid: Bool {
            !threadId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !messageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    private var pendingReply: PendingReply?
    private var pendingReplyBlocked = false
    private var restoredPendingReply = false
    private static let pendingReplyFileName = "pending-chat-reply.json"
    private struct LoadedThread: Decodable {
        struct Stored: Decodable {
            let id: String
            let role: String
            let content: String
        }

        let id: String
        let title: String?
        let bookId: String?
        let updatedAt: Double?
        let messages: [Stored]
    }
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
        if !isStreaming {
            restorePendingReply(using: runtime)
            if pendingReply != nil, !pendingReplyBlocked {
                persistAssistantReply(using: runtime)
            }
        }
        if !loadedInitialThread, messages.isEmpty, let latest = threads.first {
            loadedInitialThread = true
            open(latest, using: runtime)
        }
    }

    // MARK: - 会话线程

    func refreshThreads(using runtime: RuntimeHost) {
        guard runtime.state == .ready else { return }
        do {
            guard let json = try runtime.appJSON("ShudengApp.listThreads({})", timeout: 60),
                  let rows = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] else {
                throw NSError(domain: "ChatPersistence", code: 2)
            }
            // 一条脏数据不该让整个历史列表消失：逐条解，坏行跳过。
            let decoder = JSONDecoder()
            threads = rows.compactMap { row in
                guard let data = try? JSONSerialization.data(withJSONObject: row) else { return nil }
                return try? decoder.decode(ChatThread.self, from: data)
            }
            if error == "对话列表读取失败，请重试。" { error = nil }
        } catch {
            if !hasUnsavedReply { self.error = "对话列表读取失败，请重试。" }
        }
    }

    @discardableResult
    func startNewThread() -> Bool {
        guard !pendingReplyBlocked else { return false }
        if isStreaming { stop() }
        if let runtime, !persistAssistantReply(using: runtime) { return false }
        resetActiveThread()
        error = nil
        return true
    }

    private func resetActiveThread() {
        // 手动开的新对话不能被 attach() 的「自动续上一段」顶掉。
        loadedInitialThread = true
        activeThreadId = nil
        activeThreadTitle = nil
        activeBookId = nil
        messages.removeAll()
        pendingUser = nil
        persistedReplyID = nil
        contextNote = nil
    }

    @discardableResult
    func open(_ thread: ChatThread, using runtime: RuntimeHost) -> Bool {
        guard runtime.state == .ready, !pendingReplyBlocked else { return false }
        // 正在生成时点了别的会话：先把这一轮停掉（半截回答照样落库），再切过去。
        if isStreaming { stop() }
        guard persistAssistantReply(using: runtime) else { return false }
        let loaded: LoadedThread
        do {
            guard let json = try runtime.appJSON(
                "ShudengApp.loadThread(\(Self.payload(["id": thread.id])))", timeout: 60
            ) else { throw NSError(domain: "ChatPersistence", code: 2) }
            loaded = try JSONDecoder().decode(LoadedThread.self, from: Data(json.utf8))
            guard loaded.id == thread.id else { throw NSError(domain: "ChatPersistence", code: 2) }
        } catch {
            self.error = "对话读取失败，请重试。"
            return false
        }
        activeThreadId = loaded.id
        pendingUser = nil
        loadedInitialThread = true
        activeThreadTitle = thread.title
        activeBookId = thread.bookId
        messages = loaded.messages.map {
            Message(id: $0.id, role: $0.role == "assistant" ? .assistant : .user, text: $0.content)
        }
        persistedReplyID = messages.last?.role == .assistant ? messages.last?.id : nil
        contextNote = nil
        error = nil
        return true
    }

    func delete(_ thread: ChatThread, using runtime: RuntimeHost) {
        guard runtime.state == .ready else { return }
        if activeThreadId == thread.id, isStreaming { stop() }
        do {
            guard try runtime.appJSON("ShudengApp.deleteThread(\(Self.payload(["id": thread.id])))", timeout: 60) == "ok" else {
                throw NSError(domain: "ChatPersistence", code: 1)
            }
        } catch {
            self.error = "对话没能删除，请重试。"
            return
        }
        if let pending = pendingReply, pending.threadId == thread.id {
            // 用户明确删除了会话；残留备份只允许清理，不再补存。
            if removePendingReply(pending, using: runtime) {
                pendingReply = nil
                pendingReplyBlocked = false
                restoredPendingReply = true
                hasUnsavedReply = false
                error = nil
            } else {
                pendingReplyBlocked = true
                restoredPendingReply = false
                hasUnsavedReply = true
                error = "对话已删除，但回答备份未能清理；请重试清理。"
            }
        }
        if activeThreadId == thread.id {
            resetActiveThread()
            if !pendingReplyBlocked { error = nil }
        }
        refreshThreads(using: runtime)
    }

    /// 改会话标题。当前正打开的就是这段时，导航栏标题一起跟着变。
    @discardableResult
    func rename(_ thread: ChatThread, to title: String, using runtime: RuntimeHost) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "请输入对话名称。"
            return false
        }
        guard runtime.state == .ready else {
            error = "内核尚未就绪，请稍后重试。"
            return false
        }
        guard updateMetadata("ShudengApp.renameThread(\(Self.payload(["id": thread.id, "title": trimmed])))", using: runtime) else { return false }
        if activeThreadId == thread.id { activeThreadTitle = String(trimmed.prefix(40)) }
        refreshThreads(using: runtime)
        return true
    }

    /// 给「当前这段对话」换书（nil ＝ 挪回临时对话）。
    /// 对话还没建出来（一个字都没发过）时先记在内存里，第一条消息发出时随 createThread 一起落库。
    func setBook(_ bookId: String?, using runtime: RuntimeHost) {
        guard let threadId = activeThreadId else {
            activeBookId = bookId
            return
        }
        guard runtime.state == .ready else { return }
        var body: [String: Any] = ["id": threadId]
        body["bookId"] = bookId ?? NSNull()
        guard updateMetadata("ShudengApp.setThreadBook(\(Self.payload(body)))", using: runtime) else { return }
        activeBookId = bookId
        refreshThreads(using: runtime)
    }
    /// 把历史里的某段对话挪到另一本书（nil ＝ 挪回「临时对话」）。
    func move(_ thread: ChatThread, to bookId: String?, using runtime: RuntimeHost) {
        guard runtime.state == .ready else { return }
        var body: [String: Any] = ["id": thread.id]
        body["bookId"] = bookId ?? NSNull()
        guard updateMetadata("ShudengApp.setThreadBook(\(Self.payload(body)))", using: runtime) else { return }
        if activeThreadId == thread.id { activeBookId = bookId }
        refreshThreads(using: runtime)
    }

    private func updateMetadata(_ expression: String, using runtime: RuntimeHost) -> Bool {
        struct Receipt: Decodable { let ok: Bool }
        do {
            guard let json = try runtime.appJSON(expression, timeout: 30),
                  let receipt = try? JSONDecoder().decode(Receipt.self, from: Data(json.utf8)),
                  receipt.ok else {
                throw NSError(domain: "ChatPersistence", code: 1)
            }
            if !hasUnsavedReply { error = nil }
            return true
        } catch {
            self.error = "对话修改没能保存到本地，请重试。"
            return false
        }
    }

    /// 阅读器里点 ✨ 进对话：当前这段要不是这本书的，就另开一段，别把别的书的问题混进来。
    func prepareForReading(_ book: LibraryStore.Book?) {
        guard let book else { return }
        if activeBookId == book.id { return }
        guard startNewThread() else { return }
        activeBookId = book.id
    }

    /// 阅读器里选中文字提问：每次都是一段挂在当前书上的新对话。
    func prepareForSelection(_ book: LibraryStore.Book?) {
        guard startNewThread() else { return }
        activeBookId = book?.id
    }

    // MARK: - 对话

    @discardableResult
    func send(
        _ text: String,
        book: LibraryStore.Book?,
        contextText: String?,
        settings: AISettings,
        skill: AISkill? = nil
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming, !pendingReplyBlocked, let runtime, runtime.state == .ready else { return false }

        guard settings.isConfigured else {
            error = "先在设置里填模型名和端点"
            return false
        }

        guard persistAssistantReply(using: runtime),
              ensureThread(book: book, firstMessage: trimmed, using: runtime),
              let threadId = activeThreadId else { return false }
        if pendingUser?.threadId != threadId || pendingUser?.message.text != trimmed {
            pendingUser = (threadId, Message(role: .user, text: trimmed))
        }
        guard let userMessage = pendingUser?.message,
              save(userMessage, in: threadId, using: runtime) else { return false }
        pendingUser = nil
        messages.append(userMessage)
        messages.append(Message(role: .assistant, text: ""))
        persistedReplyID = nil
        isStreaming = true
        error = nil
        contextNote = nil
        thinkingStartedAt = nil
        armWatchdog()

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
        else {
            self.requestID = nil
            watchdog?.cancel()
            isStreaming = false
            finishThinking()
            dropEmptyAssistant()
            error = "这条消息无法发送，请缩短内容后再试。"
            return true
        }

        do {
            // 不阻塞主线程：token 由 __nativeChatEvent 推给 handle()，结束时再收 done。
            try runtime.startApp("ShudengApp.chat(\(json))")
        } catch {
            self.requestID = nil
            watchdog?.cancel()
            self.error = String(describing: error)
            isStreaming = false
            dropEmptyAssistant()
        }
        return true
    }

    /// 重试启动阶段未能加载的回答备份；列表页和会话页共用这条恢复路径。
    @discardableResult
    func retryPendingReply() -> Bool {
        guard !isStreaming, let runtime, runtime.state == .ready else { return false }
        return persistAssistantReply(using: runtime)
    }

    func stop() {
        let requestID = self.requestID
        self.requestID = nil
        if let runtime, let requestID {
            _ = runtime.evaluate("ShudengApp.abortChat('\(requestID)')")
        }
        watchdog?.cancel()
        isStreaming = false
        finishThinking()
        dropEmptyAssistant()
        // 停下来的半截回答也是回答：落库，别让历史里只剩提问。
        if let runtime { persistAssistantReply(using: runtime) }
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
        // 阅读器里提问时 chip 可能还没挂上书，用调用方带上来的那本兜底。
        if let book, activeBookId == nil { activeBookId = book.id }
        var body: [String: Any] = ["title": String(firstMessage.prefix(24))]
        if let activeBookId { body["bookId"] = activeBookId }
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

    @discardableResult
    private func persistAssistantReply(using runtime: RuntimeHost) -> Bool {
        if !restoredPendingReply {
            restorePendingReply(using: runtime)
            guard !pendingReplyBlocked else { return false }
        }
        guard let threadId = activeThreadId,
              let reply = messages.last,
              reply.role == .assistant,
              (reply.id != persistedReplyID || pendingReply != nil),
              !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return !hasUnsavedReply }
        let pending = PendingReply(threadId: threadId, messageId: reply.id, text: reply.text)
        pendingReply = pending
        let backupWritten = writePendingReply(pending, using: runtime)
        guard !pendingReplyBlocked else { return false }
        guard save(reply, in: threadId, using: runtime) else {
            hasUnsavedReply = true
            error = backupWritten
                ? "回答没能写入数据库，已备份，重启可恢复；请重试保存。"
                : "回答只保存在当前页面，关闭应用会丢失；请检查存储空间后重试。"
            return false
        }
        if hasUnsavedReply { error = nil }
        hasUnsavedReply = false
        persistedReplyID = reply.id
        if backupWritten, !removePendingReply(pending, using: runtime) {
            error = "回答已经保存，但临时备份清理失败；请重试清理。"
            hasUnsavedReply = true
            return false
        }
        pendingReply = nil
        refreshThreads(using: runtime)
        return true
    }

    private func pendingReplyURL(using runtime: RuntimeHost) -> URL {
        runtime.rootDirectory.appendingPathComponent(Self.pendingReplyFileName)
    }

    @discardableResult
    private func writePendingReply(_ pending: PendingReply, using runtime: RuntimeHost) -> Bool {
        let url = pendingReplyURL(using: runtime)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try JSONDecoder().decode(PendingReply.self, from: Data(contentsOf: url))
                guard existing.isValid, existing == pending else { throw NSError(domain: "ChatPersistence", code: 2) }
                pendingReplyBlocked = false
                return true
            }
            let data = try JSONEncoder().encode(pending)
            try data.write(to: url, options: .atomic)
            pendingReplyBlocked = false
            return true
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                pendingReplyBlocked = true
                hasUnsavedReply = true
                self.error = "回答备份无法读取或内容冲突，原文件已保留，未覆盖。"
            } else {
                pendingReplyBlocked = false
            }
            return false
        }
    }

    @discardableResult
    private func removePendingReply(_ pending: PendingReply, using runtime: RuntimeHost) -> Bool {
        let url = pendingReplyURL(using: runtime)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            let existing = try JSONDecoder().decode(PendingReply.self, from: Data(contentsOf: url))
            guard existing.isValid, existing == pending else { return false }
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private func restorePendingReply(using runtime: RuntimeHost) {
        guard !restoredPendingReply else { return }
        let url = pendingReplyURL(using: runtime)
        guard FileManager.default.fileExists(atPath: url.path) || pendingReply != nil else {
            restoredPendingReply = true
            if pendingReplyBlocked {
                pendingReplyBlocked = false
                hasUnsavedReply = pendingReply != nil
                if !hasUnsavedReply { error = nil }
            }
            return
        }
        let pending: PendingReply
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                pending = try JSONDecoder().decode(PendingReply.self, from: Data(contentsOf: url))
            } else if let retained = pendingReply {
                pending = retained
            } else {
                return
            }
            guard pending.isValid else { throw NSError(domain: "ChatPersistence", code: 2) }
        } catch {
            pendingReplyBlocked = true
            hasUnsavedReply = true
            self.error = "回答备份无法读取，原文件已保留，未覆盖；请修复存储后重试。"
            return
        }
        pendingReply = pending
        let loaded: LoadedThread
        do {
            guard let json = try runtime.appJSON(
                "ShudengApp.loadThread(\(Self.payload(["id": pending.threadId])))", timeout: 60
            ) else { throw NSError(domain: "ChatPersistence", code: 3) }
            loaded = try JSONDecoder().decode(LoadedThread.self, from: Data(json.utf8))
            guard loaded.id == pending.threadId else { throw NSError(domain: "ChatPersistence", code: 3) }
        } catch {
            activeThreadId = pending.threadId
            activeThreadTitle = nil
            activeBookId = nil
            pendingUser = nil
            persistedReplyID = nil
            contextNote = nil
            messages = [Message(id: pending.messageId, role: .assistant, text: pending.text)]
            loadedInitialThread = true
            pendingReplyBlocked = true
            self.error = "原对话读取失败，已保留回答备份；请重试恢复。"
            hasUnsavedReply = true
            return
        }
        guard loaded.updatedAt != nil else {
            guard loaded.title == "", loaded.bookId == nil, loaded.messages.isEmpty else {
                pendingReplyBlocked = true
                hasUnsavedReply = true
                error = "原对话返回了无效数据，已保留回答备份；请重试恢复。"
                return
            }
            if removePendingReply(pending, using: runtime) {
                pendingReply = nil
                pendingReplyBlocked = false
                restoredPendingReply = true
                hasUnsavedReply = false
                if activeThreadId == pending.threadId { resetActiveThread() }
                error = nil
            } else {
                pendingReplyBlocked = true
                hasUnsavedReply = true
                self.error = "原对话已删除，但回答备份未能清理；请重试清理。"
            }
            return
        }
        activeThreadId = loaded.id
        activeThreadTitle = loaded.title
        activeBookId = loaded.bookId
        messages = loaded.messages.map {
            Message(id: $0.id, role: $0.role == "assistant" ? .assistant : .user, text: $0.content)
        }
        loadedInitialThread = true
        pendingReplyBlocked = false
        if let existing = messages.first(where: { $0.id == pending.messageId }) {
            guard existing.role == .assistant, existing.text == pending.text else {
                pendingReplyBlocked = true
                hasUnsavedReply = true
                error = "未保存的回答与会话内容冲突，未覆盖原数据。"
                return
            }
            persistedReplyID = pending.messageId
            if removePendingReply(pending, using: runtime) {
                pendingReply = nil
                restoredPendingReply = true
                hasUnsavedReply = false
                error = nil
            } else {
                pendingReplyBlocked = true
                hasUnsavedReply = true
                error = "回答已经保存，但临时备份清理失败；请重试清理。"
            }
            return
        }
        messages.append(Message(id: pending.messageId, role: .assistant, text: pending.text))
        persistedReplyID = nil
        restoredPendingReply = true
        hasUnsavedReply = true
        error = "恢复了一条未保存的回答，请重试保存后再切换会话。"
    }

    private func save(_ message: Message, in threadId: String, using runtime: RuntimeHost) -> Bool {
        struct Receipt: Decodable { let id: String }
        let body = Self.payload(["id": message.id, "threadId": threadId,
                                 "role": message.role == .assistant ? "assistant" : "user", "content": message.text])
        do {
            guard let json = try runtime.appJSON("ShudengApp.appendMessage(\(body))", timeout: 30),
                  let receipt = try? JSONDecoder().decode(Receipt.self, from: Data(json.utf8)),
                  receipt.id == message.id else {
                throw NSError(domain: "ChatPersistence", code: 1)
            }
            return true
        } catch {
            self.error = message.role == .assistant
                ? "回答没能保存到本地，请检查存储空间后重试；当前回答会保留。"
                : "提问没能保存到本地，请检查存储空间后重新发送。"
            return false
        }
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
        let requestID = self.requestID
        self.requestID = nil
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
            self.requestID = nil
            watchdog?.cancel()
            isStreaming = false
            finishThinking()
            dropEmptyAssistant()
            if let runtime { persistAssistantReply(using: runtime) }
        case "error":
            self.requestID = nil
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
