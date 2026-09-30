// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import JavaScriptCore
import Security

public enum HostError: Error, CustomStringConvertible {
    case invalidPath(String)
    case forbidden(String)
    case fileSystem(String)
    case database(String)

    public var description: String {
        switch self {
        case .invalidPath(let path): "非法路径: \(path)"
        case .forbidden(let path): "路径不在 App 沙箱内: \(path)"
        case .fileSystem(let message): "文件操作失败: \(message)"
        case .database(let message): "数据库操作失败: \(message)"
        }
    }
}

/// 宿主能力集合：把 JSContext 缺失的东西（定时器、网络、数据库）补上。
/// JS 回调必须在同一个线程上执行，默认是主线程。
public final class HostEnvironment {
    public let database: SQLiteDatabase
    /// JS 侧相对路径的根目录（iOS: Documents，与旧版 ReadAny 一致）。
    public let rootDirectory: URL
    public let callbackQueue: DispatchQueue
    public var log: (String) -> Void
    /// 流式聊天事件：(requestId, eventJSON)，由 JS 侧 __nativeChatEvent 触发。
    public var onChatEvent: ((String, String) -> Void)?
    /// 一次性异步结果回调：(token, json)。
    public var onAsyncResult: ((String, String) -> Void)?

    private var timers: [String: DispatchWorkItem] = [:]
    private var runningTasks: [String: URLSessionTask] = [:]
    private var streamBridges: [String: StreamBridge] = [:]
    private var databases: [String: SQLiteDatabase] = [:]

    /// 还挂在表里的定时器数量（测试用）：执行完的 setTimeout 必须被摘掉。
    var liveTimerCount: Int { timers.count }

    public init(
        databasePath: String = ":memory:",
        rootDirectory: URL? = nil,
        callbackQueue: DispatchQueue = .main,
        log: @escaping (String) -> Void = { print($0) }
    ) throws {
        self.database = try SQLiteDatabase(path: databasePath)
        self.rootDirectory = try Self.prepareRootDirectory(rootDirectory)
        self.callbackQueue = callbackQueue
        self.log = log
    }

    /// 在求值任何 JS 之前调用；之后 context 里就有了 fetch / 定时器 / 文件系统 / 数据库。
    public func attach(to context: JSContext) {
        registerLogging(in: context)
        registerPaths(in: context)
        registerRandomBytes(in: context)
        registerTimers(in: context)
        registerFileSystem(in: context)
        registerKeyValueStore(in: context)
        registerDatabase(in: context)
        registerNetworking(in: context)
        registerChatEvents(in: context)
        registerEmbeddings(in: context)
    }

    // MARK: - 端侧向量（语义索引用）

    /// `__nativeEmbed(["文本", ...])` 或 `__nativeEmbed({ texts: [...], modelId })`
    /// → `{ modelId, dimensions, vectors: [[Double]], missed }`；出不来就是 `{ error, diagnostics }`。
    ///
    /// 传了 modelId 就只认这个模型（查询必须和建索引同一档）；
    /// 没传就自动挑一个能用的。一次调用别塞太多：NLEmbedding 是同步算的。
    private func registerEmbeddings(in context: JSContext) {
        let embed: @convention(block) (String) -> String = { payloadJSON in
            guard let data = payloadJSON.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data)
            else {
                return Self.jsonString(["error": "参数不是 JSON"])
            }
            let texts: [String]
            let modelId: String
            if let array = payload as? [String] {
                texts = array
                modelId = ""
            } else if let object = payload as? [String: Any] {
                texts = (object["texts"] as? [String]) ?? []
                modelId = (object["modelId"] as? String) ?? ""
            } else {
                return Self.jsonString(["error": "参数不是文本数组"])
            }
            guard !texts.isEmpty else { return Self.jsonString(["error": "参数不是文本数组"]) }

            let batch = Array(texts.prefix(64))
            let output = modelId.isEmpty
                ? LocalEmbedding.embed(batch)
                : LocalEmbedding.embed(batch, usingModelId: modelId)
            guard let output else {
                let reason = modelId.isEmpty
                    ? "这台设备上没有可用的端侧向量模型"
                    : "端侧向量模型 \(modelId) 现在取不到向量"
                return Self.jsonString([
                    "error": "\(reason)（\(LocalEmbedding.diagnostics())）",
                    "diagnostics": LocalEmbedding.diagnostics(),
                ])
            }
            return Self.jsonString([
                "modelId": output.modelId,
                "dimensions": output.dimensions,
                "vectors": output.vectors,
                "missed": output.missed,
            ])
        }
        context.setObject(embed, forKeyedSubscript: "__nativeEmbed" as NSString)

        let diagnostics: @convention(block) () -> String = { LocalEmbedding.diagnostics() }
        context.setObject(diagnostics, forKeyedSubscript: "__nativeEmbedDiagnostics" as NSString)

        // 后台先把系统向量资源要下来（缺资源的机型第一次跑就卡在这里）。
        let prepare: @convention(block) () -> Void = { LocalEmbedding.prepareInBackground() }
        context.setObject(prepare, forKeyedSubscript: "__nativeEmbedPrepare" as NSString)
    }

    private static func prepareRootDirectory(_ override: URL?) throws -> URL {
        // 旧版 ReadAny（React Native）的数据就在 Documents 下（books / covers /
        // readany-store / SQLite），沿用同一目录，升级后书库和阅读统计不会丢。
        let base = override ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.standardizedFileURL
    }

    // MARK: - console / print

    private func registerLogging(in context: JSContext) {
        let handler: @convention(block) (String) -> Void = { [log] message in log(message) }
        context.setObject(handler, forKeyedSubscript: "print" as NSString)
    }

    // MARK: - timers

    private func registerTimers(in context: JSContext) {
        let setTimeout: @convention(block) (JSValue?, Double) -> String = { [weak self] callback, milliseconds in
            let id = UUID().uuidString
            guard let self else { return id }
            // 执行前把自己从表里摘掉：否则每调一次 setTimeout 就永久留一份
            // DispatchWorkItem（还抓着 JS 回调），长会话里只涨不降。
            let item = DispatchWorkItem { [weak self] in
                self?.timers[id] = nil
                callback?.call(withArguments: [])
            }
            timers[id] = item
            callbackQueue.asyncAfter(deadline: .now() + max(0, milliseconds) / 1000, execute: item)
            return id
        }
        context.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)

        let clearTimeout: @convention(block) (String) -> Void = { [weak self] id in
            self?.timers[id]?.cancel()
            self?.timers[id] = nil
        }
        context.setObject(clearTimeout, forKeyedSubscript: "clearTimeout" as NSString)
    }

    // MARK: - database（IDatabase 宿主实现）

    private func registerDatabase(in context: JSContext) {
        let query: @convention(block) (String, String, String) -> String = { [weak self] path, sql, params in
            guard let self else { return #"{"error":"host released"}"# }
            do {
                return try self.database(at: path).jsonQuery(sql, paramsJSON: params)
            } catch {
                return Self.jsonString(["error": String(describing: error)])
            }
        }
        context.setObject(query, forKeyedSubscript: "__nativeDbQuery" as NSString)

        let close: @convention(block) (String) -> Void = { [weak self] path in
            self?.closeDatabase(at: path)
        }
        context.setObject(close, forKeyedSubscript: "__nativeDbClose" as NSString)
    }

    // MARK: - streaming fetch

    private func registerNetworking(in context: JSContext) {
        let fetchStream: @convention(block) (String, String, String, String, String, JSValue?, JSValue?, JSValue?) -> Void = {
            [weak self] urlString, method, headersJSON, body, taskID, headCallback, chunkCallback, finishCallback in
            guard let self else { return }
            guard let url = URL(string: urlString) else {
                callbackQueue.async { finishCallback?.call(withArguments: ["Invalid URL: \(urlString)"]) }
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 120
            if let headers = (try? JSONSerialization.jsonObject(with: Data(headersJSON.utf8))) as? [String: String] {
                for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            }
            if method != "GET", !body.isEmpty { request.httpBody = Data(body.utf8) }

            let bridge = StreamBridge(
                onHead: { [weak self] status, headers in
                    let data = (try? JSONSerialization.data(withJSONObject: headers)) ?? Data("{}".utf8)
                    let json = String(decoding: data, as: UTF8.self)
                    self?.callbackQueue.async { headCallback?.call(withArguments: [status, json]) }
                },
                onChunk: { [weak self] text in
                    self?.callbackQueue.async { chunkCallback?.call(withArguments: [text]) }
                },
                onFinish: { [weak self] error in
                    self?.callbackQueue.async {
                        finishCallback?.call(withArguments: [error.map { String(describing: $0) }])
                        self?.streamBridges[taskID] = nil
                        self?.runningTasks[taskID] = nil
                    }
                }
            )
            streamBridges[taskID] = bridge
            runningTasks[taskID] = bridge.start(request)
        }
        context.setObject(fetchStream, forKeyedSubscript: "__nativeFetchStream" as NSString)

        let abort: @convention(block) (String) -> Void = { [weak self] taskID in
            self?.runningTasks[taskID]?.cancel()
        }
        context.setObject(abort, forKeyedSubscript: "__nativeAbort" as NSString)
    }

    // MARK: - 沙箱目录

    private func registerChatEvents(in context: JSContext) {
        let emit: @convention(block) (String, String) -> Void = { [weak self] requestID, eventJSON in
            self?.onChatEvent?(requestID, eventJSON)
        }
        context.setObject(emit, forKeyedSubscript: "__nativeChatEvent" as NSString)

        // 一次性异步结果（翻译 / 端点测试…）：JS 侧 resolve 之后回推，Swift 不用阻塞主线程等 Promise。
        let asyncResult: @convention(block) (String, String) -> Void = { [weak self] token, json in
            self?.onAsyncResult?(token, json)
        }
        context.setObject(asyncResult, forKeyedSubscript: "__nativeAsyncResult" as NSString)
    }

    private func registerPaths(in context: JSContext) {
        let paths: @convention(block) () -> String = { [rootDirectory] in
            let fileManager = FileManager.default
            let payload: [String: Any] = [
                "appData": rootDirectory.path,
                "documents": fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].path,
                "caches": fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0].path,
                "tmp": NSTemporaryDirectory(),
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
                "locale": Self.deviceLocaleIdentifier(),
            ]
            return Self.jsonString(payload)
        }
        context.setObject(paths, forKeyedSubscript: "__nativePaths" as NSString)
    }

    /// 设备语言偏好（System Settings 里那一条），拿不到才退回 Locale.current。
    /// 书灯没有 .lproj，中文机器上 Locale.current 会被系统判成开发语言（en），
    /// 徽章名这类 core 文案就跟着变英文了。
    static func deviceLocaleIdentifier() -> String {
        if let preferred = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first,
           !preferred.isEmpty {
            return preferred
        }
        return Locale.current.identifier
    }

    /// 加密安全随机数（core 的 generateId / randomUUID 用）。
    private func registerRandomBytes(in context: JSContext) {
        let random: @convention(block) (Int) -> String = { count in
            let length = max(0, min(count, 4096))
            var bytes = [UInt8](repeating: 0, count: length)
            if SecRandomCopyBytes(kSecRandomDefault, length, &bytes) != errSecSuccess {
                for index in 0..<length { bytes[index] = UInt8.random(in: 0...255) }
            }
            return Self.jsonString(["bytes": bytes.map(Int.init)])
        }
        context.setObject(random, forKeyedSubscript: "__nativeRandomBytes" as NSString)
    }

    /// JS 传来的路径：相对路径落到 rootDirectory，绝对路径必须在 App 沙箱目录内。
    func resolve(_ path: String) throws -> URL {
        let cleaned = path.hasPrefix("sqlite:") ? String(path.dropFirst("sqlite:".count)) : path
        guard !cleaned.isEmpty else { throw HostError.invalidPath(path) }

        // 相对路径同样要校验（"../../.." 会被 standardizedFileURL 解析到沙箱外）。
        let url = cleaned.hasPrefix("/")
            ? URL(fileURLWithPath: cleaned).standardizedFileURL
            : rootDirectory.appendingPathComponent(cleaned).standardizedFileURL
        let fileManager = FileManager.default
        let allowedRoots = [
            rootDirectory,
            fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0],
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0],
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        ].map(\.standardizedFileURL.path)

        let isAllowed = allowedRoots.contains { root in
            url.path == root || url.path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        guard isAllowed else { throw HostError.forbidden(path) }
        return url
    }

    private func registerFileSystem(in context: JSContext) {
        let fileSystem: @convention(block) (String, String, String) -> String = { [weak self] op, path, payload in
            guard let self else { return #"{"error":"host released"}"# }
            do {
                return try self.performFileSystem(op: op, path: path, payload: payload)
            } catch {
                return Self.jsonString(["error": String(describing: error)])
            }
        }
        context.setObject(fileSystem, forKeyedSubscript: "__nativeFs" as NSString)

        // 文件内容指纹（导入去重用）：几十兆的 EPUB 在 Swift 里算比在 JSC 里算省得多。
        let digest: @convention(block) (String) -> String = { [weak self] path in
            guard let self else { return #"{"error":"host released"}"# }
            do {
                let url = try self.resolve(path)
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                return Self.jsonString(["size": data.count, "sha256": hex])
            } catch {
                return Self.jsonString(["error": String(describing: error)])
            }
        }
        context.setObject(digest, forKeyedSubscript: "__nativeFileDigest" as NSString)
    }

    private func performFileSystem(op: String, path: String, payload: String) throws -> String {
        let url = try resolve(path)
        let fileManager = FileManager.default

        switch op {
        case "exists":
            return Self.jsonString(["exists": fileManager.fileExists(atPath: url.path)])
        case "read", "readText":
            guard fileManager.fileExists(atPath: url.path) else {
                throw HostError.fileSystem("文件不存在: \(url.path)")
            }
            let data = try Data(contentsOf: url)
            if op == "read" {
                return Self.jsonString(["base64": data.base64EncodedString()])
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw HostError.fileSystem("不是 UTF-8 文本: \(url.path)")
            }
            return Self.jsonString(["text": text])
        case "write", "writeText":
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data: Data
            if op == "writeText" {
                data = Data(payload.utf8)
            } else {
                guard let decoded = Data(base64Encoded: payload) else {
                    throw HostError.fileSystem("base64 解码失败: \(path)")
                }
                data = decoded
            }
            try data.write(to: url, options: .atomic)
            return Self.jsonString(["bytes": data.count])
        case "mkdir":
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return "{}"
        case "delete":
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            return "{}"
        case "list":
            let entries = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
            let items: [[String: Any]] = try entries.map { entry in
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                return [
                    "name": entry.lastPathComponent,
                    "isDirectory": values.isDirectory ?? false,
                    "size": values.fileSize ?? 0,
                ]
            }
            return Self.jsonString(["items": items])
        default:
            throw HostError.fileSystem("未知操作: \(op)")
        }
    }

    // MARK: - 键值存储（UserDefaults）

    private func registerKeyValueStore(in context: JSContext) {
        let store: @convention(block) (String, String, String) -> String = { op, key, value in
            let defaults = UserDefaults.standard
            let storageKey = "shudeng.kv." + key
            switch op {
            case "get":
                return Self.jsonString(["value": defaults.string(forKey: storageKey) as Any])
            case "set":
                defaults.set(value, forKey: storageKey)
                return "{}"
            case "remove":
                defaults.removeObject(forKey: storageKey)
                return "{}"
            case "keys":
                let keys = defaults.dictionaryRepresentation().keys
                    .filter { $0.hasPrefix("shudeng.kv.") }
                    .map { String($0.dropFirst("shudeng.kv.".count)) }
                return Self.jsonString(["keys": keys])
            default:
                return Self.jsonString(["error": "未知操作: \(op)"])
            }
        }
        context.setObject(store, forKeyedSubscript: "__nativeKv" as NSString)
    }

    // MARK: - 数据库注册表

    /// 同一个文件路径复用同一个连接；":memory:" 走初始化时建好的默认库。
    func database(at path: String) throws -> SQLiteDatabase {
        if path.isEmpty || path == ":memory:" { return database }

        let url = try resolve(path)
        if let existing = databases[url.path] { return existing }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let opened = try SQLiteDatabase(path: url.path)
        databases[url.path] = opened
        return opened
    }

    private func closeDatabase(at path: String) {
        guard let url = try? resolve(path) else { return }
        databases[url.path] = nil
    }

    static func jsonString(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
