// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// 观察者表用弱引用持有 owner：弹层里的 ChatService 被销毁后不再收到事件，也不会泄漏。
private final class ChatObserverBox {
    weak var owner: AnyObject?
    let handler: (String, String) -> Void

    init(owner: AnyObject, handler: @escaping (String, String) -> Void) {
        self.owner = owner
        self.handler = handler
    }
}

/// 持有 JavaScriptCore 运行时，App 内所有 AI / 数据库调用都从这里走。
@MainActor
final class RuntimeHost: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private(set) var runtime: ReadAnyRuntime?
    /// 流式聊天事件观察者：(requestId, eventJSON)，由 core 的 __nativeChatEvent 回推。
    /// 用观察者表而不是单个闭包：AI Tab 和阅读器里的 AI 弹层同时存在时不会互相顶掉。
    private var chatObservers: [UUID: ChatObserverBox] = [:]
    /// 等 JS 结算的一次性异步调用：(token, 结果回调)。
    private var pendingAsyncResults: [String: (String) -> Void] = [:]

    @discardableResult
    func addChatObserver(owner: AnyObject, _ handler: @escaping (String, String) -> Void) -> UUID {
        chatObservers = chatObservers.filter { $0.value.owner != nil }
        let id = UUID()
        chatObservers[id] = ChatObserverBox(owner: owner, handler: handler)
        return id
    }

    func removeChatObserver(_ id: UUID) {
        chatObservers.removeValue(forKey: id)
    }

    func start() {
        guard state == .idle else { return }
        state = .loading
        do {
            guard let coreURL = Bundle.main.url(forResource: "core", withExtension: "js") else {
                throw RuntimeError.missingResource("core.js（先执行 pnpm ios:core）")
            }
            guard let bootstrapURL = Bundle.main.url(forResource: "app-bootstrap", withExtension: "js") else {
                throw RuntimeError.missingResource("app-bootstrap.js")
            }
            let runtime = try ReadAnyRuntime(
                coreScript: try String(contentsOf: coreURL, encoding: .utf8),
                appScript: try String(contentsOf: bootstrapURL, encoding: .utf8)
            )
            runtime.host.onChatEvent = { [weak self] requestID, eventJSON in
                guard let self else { return }
                // 事件是在 JS 的 __nativeChatEvent 调用里同步打上来的：观察者要是当场再同步进 JS
                //（比如把回复写进会话表），就把引擎卡在自己的回调里，表现成「回答完了界面卡 60 秒」。
                // 统一派到下一轮主队列，等这次 JS 调用退栈再分发。
                DispatchQueue.main.async {
                    for observer in Array(self.chatObservers.values) {
                        guard observer.owner != nil else { continue }
                        observer.handler(requestID, eventJSON)
                    }
                }
            }
            runtime.host.onAsyncResult = { [weak self] token, json in
                // 和聊天事件同理：JS 还压在这一次调用栈里，派到下一轮主队列再回调。
                DispatchQueue.main.async {
                    self?.pendingAsyncResults.removeValue(forKey: token)?(json)
                }
            }
            self.runtime = runtime
            state = .ready
            seedSampleBookIfRequested()
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func retry() {
        guard case .failed = state else { return }
        runtime = nil
        state = .idle
        start()
    }

    /// 模拟器跑 UI 测试时把包内样例书导进书库，免得每台模拟器都要手动导入。
    private func seedSampleBookIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        if environment["SHUDENG_SEED_SAMPLE_BOOK"] == "1" {
            importBundledSample(resource: "ui-test-sample")
        }
        // 英文样书：模拟器上的端侧词向量只认英文，用它验证语义检索整条链路。
        if environment["SHUDENG_SEED_SAMPLE_BOOK_EN"] == "1" {
            importBundledSample(resource: "ui-test-sample-en")
        }
        // PDF 样书：pdf.js 渲染这条路没别的办法在 UI 测试里覆盖。
        if environment["SHUDENG_SEED_SAMPLE_PDF"] == "1" {
            importBundledSample(resource: "ui-test-sample-pdf", extension: "pdf")
        }
    }

    private func importBundledSample(resource: String, extension ext: String = "epub") {
        guard let bundled = Bundle.main.url(forResource: resource, withExtension: ext)
        else { return }

        let relativePath = "books/\(resource).\(ext)"
        let destination = rootDirectory.appendingPathComponent(relativePath)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: bundled, to: destination)
            }
            let payload: [String: String] = [
                "id": resource,
                "path": relativePath,
                "fileName": "\(resource).\(ext)",
                "format": ext,
            ]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            _ = appJSONOr("ShudengApp.importBook(\(json))", fallback: "{}", timeout: 120)
        } catch {
            // 测试夹具失败不影响正常启动，只是用例会跳过开书部分。
        }
    }

    /// 调用 ShudengApp 暴露的 JS API，返回 Promise 解析后的 JSON 字符串。
    func appJSON(_ expression: String, timeout: TimeInterval = 30) throws -> String? {
        guard let runtime else { throw RuntimeError.missingResource("core 运行时尚未启动") }
        guard let promise = try runtime.evaluate(expression) else {
            throw RuntimeError.scriptFailed("\(expression) 没有返回 Promise")
        }
        return try runtime.wait(for: promise, timeout: timeout).toString()
    }

    /// 调用 JS API，失败或返回 null 时给一个兜底 JSON。
    @discardableResult
    func appJSONOr(_ expression: String, fallback: String = "{}", timeout: TimeInterval = 30) -> String {
        (try? appJSON(expression, timeout: timeout)) ?? fallback
    }

    func evaluate(_ script: String) -> String? {
        guard let runtime else { return nil }
        return (try? runtime.evaluate(script))?.toString()
    }

    /// 只发起 JS 调用，不等 Promise：流式结果靠 __nativeChatEvent 回推。
    /// 不能在「主队列 block 里再阻塞等 Promise」——宿主把网络回调派回主队列，
    /// 主队列正被堵着的话 head/chunk 永远进不了 JS，流式对话就永远停在「正在生成」。
    func startApp(_ expression: String) throws {
        guard let runtime else { throw RuntimeError.missingResource("core 运行时尚未启动") }
        guard try runtime.evaluate(expression) != nil else {
            throw RuntimeError.scriptFailed("\(expression) 没有返回 Promise")
        }
    }

    /// 一次性异步调用：JS 的 Promise 结算后由 __nativeAsyncResult 回推，全程不阻塞主线程。
    /// 阻塞版（appJSONOr）只适合走同步宿主能力（SQLite / 文件）的调用；带网络的调用一律走这里。
    func callAsync(_ expression: String, timeout: TimeInterval = 120, onResult: @escaping (String) -> Void) {
        guard runtime != nil else {
            onResult(#"{"error":"core 运行时尚未启动"}"#)
            return
        }
        let token = UUID().uuidString
        let wrapped = """
        Promise.resolve(\(expression)).then(
          (value) => __nativeAsyncResult('\(token)', typeof value === 'string' ? value : JSON.stringify(value)),
          (error) => __nativeAsyncResult('\(token)', JSON.stringify({ error: String((error && error.message) || error) }))
        )
        """
        let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            Task { @MainActor in
                guard let pending = self.pendingAsyncResults.removeValue(forKey: token) else { return }
                pending(#"{"error":"JS 异步调用超时"}"#)
            }
        }
        pendingAsyncResults[token] = { json in
            timer.invalidate()
            onResult(json)
        }
        do {
            try startApp(wrapped)
        } catch {
            timer.invalidate()
            pendingAsyncResults.removeValue(forKey: token)
            onResult(#"{"error":"\#(String(describing: error).replacingOccurrences(of: "\"", with: "'"))"}"#)
        }
    }

    /// App 数据目录，和 HostEnvironment 的沙箱根目录一致（Documents：沿用旧版 ReadAny 的数据）。
    var rootDirectory: URL { runtime?.host.rootDirectory ?? Self.defaultRootDirectory }

    static var defaultRootDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
