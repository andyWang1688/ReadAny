// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ShudengCoreBridge

final class ReadAnyRuntimeTests: XCTestCase {
    /// 默认读取 CoreBridge/Generated/core.js；不存在则跳过（先跑 scripts/build-core-bundle.mjs）。
    private func coreScript() throws -> String {
        if let path = ProcessInfo.processInfo.environment["SHUDENG_CORE_JS"], !path.isEmpty {
            return try String(contentsOfFile: path, encoding: .utf8)
        }
        let repoPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ShudengCoreBridgeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CoreBridge
            .appendingPathComponent("Generated/core.js")
        guard FileManager.default.fileExists(atPath: repoPath.path) else {
            throw XCTSkip("缺少 \(repoPath.path)，先运行 packages/app-ios/scripts/build-core-bundle.mjs")
        }
        return try String(contentsOf: repoPath, encoding: .utf8)
    }

    private func makeRuntime() throws -> ReadAnyRuntime {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shudeng-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try ReadAnyRuntime(
            coreScript: try coreScript(),
            host: HostEnvironment(rootDirectory: root, log: { _ in })
        )
    }

    func testCoreLoadsAndAIBoots() throws {
        let runtime = try makeRuntime()
        let raw = try runtime.evaluate(
            """
            (() => {
              const R = ReadAnyCore;
              return JSON.stringify({
                namespaces: Object.keys(R).sort(),
                promptLength: R.ai.buildSystemPrompt({
                  book: null, semanticContext: null, enabledSkills: [], isVectorized: false, userLanguage: 'zh',
                }).length,
                badges: R.stats.ALL_BADGE_DEFINITIONS.length,
              });
            })()
            """
        )?.toString()

        let payload = try XCTUnwrap(raw)
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            json["namespaces"] as? [String],
            [
                "ai", "badgeText", "bookImport", "db", "diagram", "epub", "epubText", "importDedupe", "messages",
                "rag", "services", "skills", "stats", "translation", "tts", "utils",
            ]
        )
        XCTAssertGreaterThan(json["promptLength"] as? Int ?? 0, 1000)
        XCTAssertGreaterThan(json["badges"] as? Int ?? 0, 0)
    }

    func testLangChainModelConstruction() throws {
        let runtime = try makeRuntime()
        let promise = try XCTUnwrap(
            runtime.evaluate(
                """
                ReadAnyCore.ai.createChatModelFromEndpoint({
                  id: 'test', name: 'test', provider: 'openai', apiKey: 'sk-test',
                  baseUrl: 'https://api.openai.com/v1', models: ['gpt-4o-mini'], modelsFetched: true,
                }, 'gpt-4o-mini').then((model) => JSON.stringify({
                  // 打包会 minify，constructor.name 会被压成短名，这里看行为不看类名。
                  invoke: typeof model.invoke === 'function',
                  stream: typeof model.stream === 'function',
                  name: String(model.model || model.modelName || ''),
                  namespace: JSON.stringify(model.lc_namespace || null),
                }))
                """
            )
        )
        let raw = try runtime.wait(for: promise, timeout: 30).toString()
        let data = try XCTUnwrap(raw?.data(using: .utf8))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["invoke"] as? Bool, true, "模型没有 invoke：\(raw ?? "nil")")
        XCTAssertEqual(json["stream"] as? Bool, true, "模型没有 stream：\(raw ?? "nil")")
        let name = json["name"] as? String ?? ""
        let namespace = json["namespace"] as? String ?? ""
        XCTAssertTrue(
            name == "gpt-4o-mini" || namespace.contains("openai"),
            "构造出来的不是 OpenAI 模型：\(raw ?? "nil")"
        )
    }

    /// Mermaid 渲染在 JSC 里也要秒回：渲染卡住会把 App 主线程整个堵死（UI 测试报
    /// “main thread busy for 30s”就是这么来的）。
    func testMermaidRenderIsFast() throws {
        let runtime = try makeRuntime()
        let raw = try runtime.evaluate(
            """
            (() => {
              const source = [
                'graph TD',
                '  A[翻开书] --> B{读得下去吗}',
                '  B -->|读得下去| C[继续读]',
                '  B -->|读不下去| D[合上书]',
              ].join('\\n');
              const t0 = Date.now();
              const svg = ReadAnyCore.diagram.renderMermaidSVG(source, { font: 'PingFang SC' });
              return JSON.stringify({ ms: Date.now() - t0, bytes: svg.length });
            })()
            """
        )?.toString()

        let data = try XCTUnwrap(raw?.data(using: .utf8))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let milliseconds = json["ms"] as? Int ?? -1
        XCTAssertGreaterThan(json["bytes"] as? Int ?? 0, 200, "SVG 没生成出来：\(raw ?? "nil")")
        XCTAssertLessThan(milliseconds, 3_000, "JSC 里画一张流程图用了 \(milliseconds)ms，太慢")
    }

    func testSQLiteBridgeRoundTrip() throws {
        let runtime = try makeRuntime()
        try runtime.evaluate("__hostDb.query('CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT)')")
        try runtime.evaluate("__hostDb.query('INSERT INTO books (title) VALUES (?)', ['书灯'])")
        let raw = try runtime.evaluate("JSON.stringify(__hostDb.query('SELECT id, title FROM books'))")?.toString()

        let payload = try XCTUnwrap(raw)
        XCTAssertTrue(payload.contains("书灯"), "unexpected payload: \(payload)")
    }

    /// 宿主平台层：建库 → core 写书 → Swift 侧读回。
    func testHostPlatformBootstrapAndBookRoundTrip() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shudeng-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = try ReadAnyRuntime(
            coreScript: try coreScript(),
            appScript: try ReadAnyRuntime.bundledAppBootstrap(),
            host: HostEnvironment(rootDirectory: root, log: { _ in })
        )

        let info = try XCTUnwrap(try runtime.wait(for: try XCTUnwrap(runtime.evaluate("ShudengApp.info()"))).toString())
        XCTAssertTrue(info.contains(root.path), "appData 不在测试目录: \(info)")

        let empty = try XCTUnwrap(try runtime.wait(for: try XCTUnwrap(runtime.evaluate("ShudengApp.listBooks()"))).toString())
        XCTAssertEqual(empty, "[]")

        let payload = try XCTUnwrap(
            try runtime.wait(
                for: try XCTUnwrap(
                    runtime.evaluate(
                        """
                        (async () => {
                          const now = Date.now();
                          await ReadAnyCore.db.insertBook({
                            id: 'book-1', filePath: 'book-1.epub', format: 'epub',
                            meta: { title: '书灯', author: '小灯' }, addedAt: now, updatedAt: now,
                            progress: 0, isVectorized: false, vectorizeProgress: 0, tags: [], syncStatus: 'local',
                          });
                          return await ShudengApp.listBooks();
                        })()
                        """
                    )
                ),
                timeout: 30
            ).toString()
        )

        XCTAssertTrue(payload.contains("书灯"), "unexpected payload: \(payload)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("readany.db").path))
    }

    /// 导入：EPUB 字节 → 元数据抽取（title/author）→ 落库 → 书库能查到。
    func testImportEpubExtractsMetadataAndStoresBook() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shudeng-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let booksDirectory = root.appendingPathComponent("books", isDirectory: true)
        try FileManager.default.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sample.epub")
        try FileManager.default.copyItem(at: fixture, to: booksDirectory.appendingPathComponent("book-1.epub"))

        let runtime = try ReadAnyRuntime(
            coreScript: try coreScript(),
            appScript: try ReadAnyRuntime.bundledAppBootstrap(),
            host: HostEnvironment(rootDirectory: root, log: { _ in })
        )

        let imported = try XCTUnwrap(
            try runtime.wait(
                for: try XCTUnwrap(
                    runtime.evaluate(
                        """
                        ShudengApp.importBook({
                          id: 'book-1', path: 'books/book-1.epub', fileName: 'sample.epub', format: 'epub',
                        })
                        """
                    )
                ),
                timeout: 30
            ).toString()
        )
        XCTAssertTrue(imported.contains("ReadAny 渲染验证"), "元数据没抽到标题: \(imported)")
        XCTAssertTrue(imported.contains("Spike"), "元数据没抽到作者: \(imported)")

        let listed = try XCTUnwrap(
            try runtime.wait(for: try XCTUnwrap(runtime.evaluate("ShudengApp.listBooks()"))).toString()
        )
        XCTAssertTrue(listed.contains("ReadAny 渲染验证"), "书库没查到导入的书: \(listed)")
        XCTAssertTrue(listed.contains("books/book-1.epub"), "filePath 没落库: \(listed)")
    }

    /// 真机同款流式对话：需要 SHUDENG_TEST_BASE_URL / SHUDENG_TEST_API_KEY / SHUDENG_TEST_MODEL。
    func testChatStreamsTokensFromEndpoint() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let baseURL = environment["SHUDENG_TEST_BASE_URL"],
              let apiKey = environment["SHUDENG_TEST_API_KEY"],
              let model = environment["SHUDENG_TEST_MODEL"]
        else {
            throw XCTSkip("未配置测试端点（SHUDENG_TEST_BASE_URL / API_KEY / MODEL）")
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shudeng-\(UUID().uuidString)", isDirectory: true)
        let host = try HostEnvironment(rootDirectory: root, log: { _ in })
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = try ReadAnyRuntime(
            coreScript: try coreScript(),
            appScript: try ReadAnyRuntime.bundledAppBootstrap(),
            host: host
        )

        let collector = ChunkCollector()
        host.onChatEvent = { _, eventJSON in collector.append(eventJSON) }

        let payload: [String: Any] = [
            "requestId": "test-1",
            "baseUrl": baseURL,
            "apiKey": apiKey,
            "model": model,
            "text": "只回复两个字：收到",
            "history": [],
        ]
        let payloadJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: payload),
            as: UTF8.self
        )

        let promise = try XCTUnwrap(runtime.evaluate("ShudengApp.chat(\(payloadJSON))"))
        let result = try runtime.wait(for: promise, timeout: 120).toString()

        XCTAssertEqual(result, "ok", "chat 返回异常: \(result ?? "nil") / \(collector.events.joined(separator: " | "))")
        XCTAssertFalse(collector.chunks.isEmpty, "没有收到任何 token")
        XCTAssertTrue(collector.events.contains { $0.contains("\"type\":\"done\"") }, "没有收到 done 事件")
    }

    /// 阅读器契约：Swift 侧靠这几个全局函数 / 事件拿「当前页正文」和「选区」，缺一个 AI 上下文就断了。
    /// 选中翻译：走和对话同一个端点（需要 SHUDENG_TEST_BASE_URL / API_KEY / MODEL）。
    func testTranslateUsesConfiguredEndpoint() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let baseURL = environment["SHUDENG_TEST_BASE_URL"],
              let apiKey = environment["SHUDENG_TEST_API_KEY"],
              let model = environment["SHUDENG_TEST_MODEL"]
        else {
            throw XCTSkip("未配置测试端点（SHUDENG_TEST_BASE_URL / API_KEY / MODEL）")
        }

        let runtime = try ReadAnyRuntime(
            coreScript: try coreScript(),
            appScript: try ReadAnyRuntime.bundledAppBootstrap(),
            host: HostEnvironment(rootDirectory: try makeTemporaryRoot(), log: { _ in })
        )
        let payload: [String: Any] = [
            "text": "The lamp lights the page.",
            "targetLang": "zh",
            "apiKey": apiKey,
            "baseUrl": baseURL,
            "model": model,
        ]
        let payloadJSON = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let raw = try XCTUnwrap(
            try runtime.wait(
                for: try XCTUnwrap(runtime.evaluate("ShudengApp.translate(\(payloadJSON))")),
                timeout: 120
            ).toString()
        )
        let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertNil(result["error"] as? String, "翻译报错: \(raw)")
        let translated = result["translated"] as? String ?? ""
        XCTAssertTrue(
            translated.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) },
            "译文不像中文: \(translated)"
        )
    }

    func testReaderExposesVisibleTextAndSelectionContract() throws {
        let reader = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ShudengCoreBridgeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CoreBridge
            .deletingLastPathComponent()   // app-ios
            .appendingPathComponent("Shudeng/Resources/reader.html")
        guard let html = try? String(contentsOf: reader, encoding: .utf8) else {
            throw XCTSkip("缺少 \(reader.path)，先运行 pnpm ios:assets")
        }

        for needle in [
            "window.getVisibleText = function",
            "function doGetVisibleText",
            "visibleCount: visibleCount",
            "postToRN('relocate'",
            "postToRN('pageSnippet'",
            "postToRN('selection'",
            "postToRN('toggleBookmark'",
            "window.setBookmarkPullState = function",
            "case 'setBookmarkPullState'",
            "type:\"foliate-loaded\"",
            "case 'openBook'",
        ] {
            XCTAssertTrue(html.contains(needle), "reader.html 缺少契约片段: \(needle)")
        }
    }

    /// core 的 i18n 用 platform.getLocale() 挑默认语言：以前宿主没给 locale，永远回落 zh-CN。
    func testPlatformLocaleComesFromDevice() throws {
        let runtime = try ReadAnyRuntime(
            coreScript: try coreScript(),
            appScript: try ReadAnyRuntime.bundledAppBootstrap(),
            host: HostEnvironment(rootDirectory: try makeTemporaryRoot(), log: { _ in })
        )

        let locale = try XCTUnwrap(
            try runtime.wait(
                for: try XCTUnwrap(
                    runtime.evaluate(
                        """
                        (async () => {
                          await ShudengApp.bootstrap();
                          return ReadAnyCore.services.getPlatformService().getLocale();
                        })()
                        """
                    )
                ),
                timeout: 30
            ).toString()
        )

        XCTAssertEqual(locale, HostEnvironment.deviceLocaleIdentifier())
        XCTAssertFalse(locale.isEmpty)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shudeng-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// 笔记页一次性拿全部书签（不带 bookId）：跨书聚合 + 按时间倒序。
    func testListBookmarksAcrossBooks() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shudeng-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = try ReadAnyRuntime(
            coreScript: try coreScript(),
            appScript: try ReadAnyRuntime.bundledAppBootstrap(),
            host: HostEnvironment(rootDirectory: root, log: { _ in })
        )

        let raw = try XCTUnwrap(
            try runtime.wait(
                for: try XCTUnwrap(
                    runtime.evaluate(
                        """
                        (async () => {
                          await ShudengApp.bootstrap();
                          const now = Date.now();
                          for (const [index, id] of ['book-1', 'book-2'].entries()) {
                            await ReadAnyCore.db.insertBook({
                              id, filePath: `books/${id}.epub`, format: 'epub',
                              meta: { title: `书灯 ${index + 1}`, author: '小灯' },
                              addedAt: now, updatedAt: now,
                              progress: 0, isVectorized: false, vectorizeProgress: 0,
                              tags: [], syncStatus: 'local',
                            });
                            await ShudengApp.addBookmark({
                              id: `bm-${id}`, bookId: id, cfi: `epubcfi(/6/${index + 2})`,
                              label: `标记 ${index + 1}`,
                            });
                          }
                          const all = JSON.parse(await ShudengApp.listBookmarks({}));
                          const onlyFirst = JSON.parse(await ShudengApp.listBookmarks({ bookId: 'book-1' }));
                          return JSON.stringify({
                            allIds: all.map((row) => row.id).sort(),
                            labels: all.map((row) => row.label).sort(),
                            onlyFirstIds: onlyFirst.map((row) => row.id),
                            noBooks: JSON.parse(await ShudengApp.listBookmarks({})).length,
                          });
                        })()
                        """
                    )
                ),
                timeout: 60
            ).toString()
        )

        struct Probe: Decodable {
            let allIds: [String]
            let labels: [String]
            let onlyFirstIds: [String]
            let noBooks: Int
        }

        let probe = try JSONDecoder().decode(Probe.self, from: Data(raw.utf8))
        XCTAssertEqual(probe.allIds, ["bm-book-1", "bm-book-2"], "不带 bookId 要回全部书的书签")
        XCTAssertEqual(probe.labels, ["标记 1", "标记 2"])
        XCTAssertEqual(probe.onlyFirstIds, ["bm-book-1"], "带 bookId 仍然只回这一本")
        XCTAssertEqual(probe.noBooks, 2)
    }

    /// 用户点「停止」是主动中断，不该在界面上弹报错。
    func testAbortChatEmitsDoneNotError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let baseURL = environment["SHUDENG_TEST_BASE_URL"],
              let apiKey = environment["SHUDENG_TEST_API_KEY"],
              let model = environment["SHUDENG_TEST_MODEL"]
        else {
            throw XCTSkip("未配置测试端点（SHUDENG_TEST_BASE_URL / API_KEY / MODEL）")
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shudeng-\(UUID().uuidString)", isDirectory: true)
        let host = try HostEnvironment(rootDirectory: root, log: { _ in })
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = try ReadAnyRuntime(
            coreScript: try coreScript(),
            appScript: try ReadAnyRuntime.bundledAppBootstrap(),
            host: host
        )

        let collector = ChunkCollector()
        host.onChatEvent = { _, eventJSON in collector.append(eventJSON) }

        let payload: [String: Any] = [
            "requestId": "abort-1",
            "baseUrl": baseURL,
            "apiKey": apiKey,
            "model": model,
            "text": "只回复两个字：收到",
            "history": [],
        ]
        let payloadJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: payload),
            as: UTF8.self
        )

        let result = try runtime.wait(
            for: try XCTUnwrap(
                runtime.evaluate(
                    """
                    (async () => {
                      const promise = ShudengApp.chat(\(payloadJSON));
                      // 立刻点停止：controller 还没建好时走 pending 中断，建好了就直接 abort。
                      const first = ShudengApp.abortChat('abort-1');
                      return JSON.stringify({ first, result: await promise });
                    })()
                    """
                )
            ),
            timeout: 120
        ).toString()

        struct AbortProbe: Decodable {
            let first: String
            let result: String
        }
        let probe = try JSONDecoder().decode(AbortProbe.self, from: Data((result ?? "{}").utf8))

        XCTAssertTrue(["aborted", "pending"].contains(probe.first), "abortChat 返回异常: \(probe.first)")
        XCTAssertEqual(probe.result, "aborted", "中断后 chat 应返回 aborted: \(probe.result)")
        XCTAssertFalse(
            collector.events.contains { $0.contains("\"type\":\"error\"") },
            "主动停止不该报错: \(collector.events.joined(separator: " | "))"
        )
        XCTAssertTrue(
            collector.events.contains { $0.contains("\"aborted\":true") },
            "没有收到 aborted 的 done 事件"
        )
    }

    /// 和 App 里 ChatService 发的 payload 同形：带书元数据 + 当前页正文，验证正文真的进了 prompt。
    func testChatInjectsReaderContext() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let baseURL = environment["SHUDENG_TEST_BASE_URL"],
              let apiKey = environment["SHUDENG_TEST_API_KEY"],
              let model = environment["SHUDENG_TEST_MODEL"]
        else {
            throw XCTSkip("未配置测试端点（SHUDENG_TEST_BASE_URL / API_KEY / MODEL）")
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shudeng-\(UUID().uuidString)", isDirectory: true)
        let host = try HostEnvironment(rootDirectory: root, log: { _ in })
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = try ReadAnyRuntime(
            coreScript: try coreScript(),
            appScript: try ReadAnyRuntime.bundledAppBootstrap(),
            host: host
        )

        let collector = ChunkCollector()
        host.onChatEvent = { _, eventJSON in collector.append(eventJSON) }

        let payload: [String: Any] = [
            "requestId": "test-context",
            "baseUrl": baseURL,
            "apiKey": apiKey,
            "model": model,
            "language": "zh",
            "text": "我当前在读哪一页？只回复正文里出现的那串暗号。",
            "contextText": "【读者当前看到的正文】暗号：蓝色雨伞 7788。",
            "book": [
                "id": "book-1", "filePath": "books/book-1.epub", "format": "epub",
                "meta": ["title": "书灯测试书", "author": "小灯"],
                "progress": 0, "isVectorized": false, "vectorizeProgress": 0,
                "tags": [String](), "addedAt": 0, "updatedAt": 0,
            ],
            "history": [],
        ]
        let payloadJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: payload),
            as: UTF8.self
        )

        let promise = try XCTUnwrap(runtime.evaluate("ShudengApp.chat(\(payloadJSON))"))
        let result = try runtime.wait(for: promise, timeout: 120).toString()
        let answer = collector.answer

        XCTAssertEqual(result, "ok", "chat 返回异常: \(result ?? "nil") / \(collector.events.joined(separator: " | "))")
        XCTAssertTrue(answer.contains("7788"), "当前页正文没进 prompt，回答是: \(answer)")
    }

    /// setTimeout 执行完必须从宿主表里摘掉：每条都抓着 JS 回调，只涨不降就是长会话内存泄漏。
    func testTimeoutCallbacksAreReleasedAfterFiring() throws {
        let runtime = try makeRuntime()
        let host = runtime.host

        _ = try runtime.evaluate(
            """
            globalThis.__fired = 0;
            for (let i = 0; i < 200; i++) setTimeout(() => { globalThis.__fired += 1; }, 0);
            """
        )

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, host.liveTimerCount > 0 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(try runtime.evaluate("globalThis.__fired")?.toInt32(), 200)
        XCTAssertEqual(host.liveTimerCount, 0, "跑完的定时器没被摘掉")
    }

    /// 向量（chunk embedding）走 Uint8Array 参数，宿主不认这个类型：不编码成
    /// 「JSON 字节数组字符串」就会 bind NULL，向量化白跑、语义搜索永远没结果。
    func testEmbeddingBlobParamRoundTrips() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shudeng-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = try ReadAnyRuntime(
            coreScript: try coreScript(),
            appScript: try ReadAnyRuntime.bundledAppBootstrap(),
            host: HostEnvironment(rootDirectory: root, log: { _ in })
        )

        let promise = try XCTUnwrap(
            runtime.evaluate(
                """
                (async () => {
                  await globalThis.ShudengApp.bootstrap();
                  const platform = ReadAnyCore.services.getPlatformService();
                  const db = await platform.loadDatabase("embed-probe.db");
                  await db.execute("CREATE TABLE IF NOT EXISTS probe (v)");
                  await db.execute("DELETE FROM probe");
                  const bytes = ReadAnyCore.db.serializeEmbedding([0.5, -1.25, 3]);
                  await db.execute("INSERT INTO probe (v) VALUES (?)", [bytes]);
                  const rows = await db.select("SELECT v FROM probe");
                  return JSON.stringify({
                    storedType: typeof rows[0].v,
                    decoded: ReadAnyCore.db.deserializeEmbedding(rows[0].v),
                  });
                })()
                """
            )
        )
        let raw = try XCTUnwrap(try runtime.wait(for: promise, timeout: 60).toString())
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        )
        let decoded = payload["decoded"] as? [Double] ?? []

        XCTAssertEqual(payload["storedType"] as? String, "string", "向量没按字节数组字符串存进去")
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(decoded[1], -1.25, accuracy: 1e-6)
        XCTAssertEqual(decoded[2], 3, accuracy: 1e-6)
    }

    /// 进度 / 会话 / 统计 / 高亮 / 书签：app-bootstrap 新增的宿主 API 能跑通 core + SQLite，
    /// 且返回的 JSON 形状能被 Swift 侧（StatsView / NotesView）解码。
    func testStatsAndAnnotationAPIs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shudeng-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = try ReadAnyRuntime(
            coreScript: try coreScript(),
            appScript: try ReadAnyRuntime.bundledAppBootstrap(),
            host: HostEnvironment(rootDirectory: root, log: { _ in })
        )

        let raw = try XCTUnwrap(
            try runtime.wait(
                for: try XCTUnwrap(
                    runtime.evaluate(
                        """
                        (async () => {
                          await ShudengApp.bootstrap();
                          const now = Date.now();
                          const todayStart = new Date();
                          todayStart.setHours(0, 0, 0, 0);
                          const startedAt = Math.max(todayStart.getTime() + 30000, now - 10 * 60000);

                          await ReadAnyCore.db.insertBook({
                            id: 'book-1', filePath: 'books/book-1.epub', format: 'epub',
                            meta: { title: '书灯', author: '小灯' }, addedAt: now, updatedAt: now,
                            progress: 0, isVectorized: false, vectorizeProgress: 0,
                            tags: [], syncStatus: 'local',
                          });
                          const progress = await ShudengApp.saveProgress({
                            bookId: 'book-1', progress: 0.42, cfi: 'epubcfi(/6/4)',
                          });
                          const session = await ShudengApp.recordSession({
                            id: 'sess-1', bookId: 'book-1', totalActiveTime: 600000,
                            pagesRead: 12, charactersRead: 3000, startedAt,
                          });
                          const tooShort = await ShudengApp.recordSession({
                            id: 'sess-2', bookId: 'book-1', totalActiveTime: 400,
                          });

                          const created = JSON.parse(await ShudengApp.addHighlight({
                            bookId: 'book-1', cfi: 'epubcfi(/6/4!/4/2)', text: '一盏照书的灯',
                            color: 'green', chapterTitle: '第一章',
                          }));
                          await ShudengApp.updateHighlight({ id: created.id, note: '记一笔' });
                          const highlightsOfBook = JSON.parse(await ShudengApp.listHighlights({ bookId: 'book-1' }));
                          const allHighlights = JSON.parse(await ShudengApp.listHighlights({}));

                          const bookmark = JSON.parse(await ShudengApp.addBookmark({
                            bookId: 'book-1', cfi: 'epubcfi(/6/8)', label: '标记一下',
                          }));
                          const bookmarks = JSON.parse(await ShudengApp.listBookmarks({ bookId: 'book-1' }));

                          const stats = JSON.parse(await ShudengApp.stats({ days: 14 }));
                          const books = JSON.parse(await ShudengApp.listBooks());

                          await ShudengApp.deleteHighlight({ id: created.id });
                          await ShudengApp.deleteBookmark({ id: bookmark.id });

                          return JSON.stringify({
                            progress, session, tooShort, stats, bookCount: books.length,
                            highlightCount: highlightsOfBook.length,
                            highlight: highlightsOfBook[0],
                            allHighlight: allHighlights[0],
                            bookmark: bookmarks[0],
                            bookmarksLeft: JSON.parse(await ShudengApp.listBookmarks({ bookId: 'book-1' })).length,
                            highlightsLeft: JSON.parse(await ShudengApp.listHighlights({})).length,
                          });
                        })()
                        """
                    )
                ),
                timeout: 60
            ).toString()
        )

        struct ProbePeriod: Decodable {
            let minutes: Double
            let pages: Double
        }
        struct ProbeOverall: Decodable {
            let totalBooks: Double
            let totalReadingTime: Double
            let totalSessions: Double
            let totalReadingDays: Double
            let avgDailyTime: Double
            let longestStreak: Double
            let currentStreak: Double
        }
        struct ProbeDaily: Decodable {
            let date: String
            let totalTime: Double
            let pagesRead: Double
            let sessionsCount: Double
        }
        struct ProbeTopBook: Decodable {
            let bookId: String
            let title: String
            let author: String?
            let coverUrl: String?
            let totalTime: Double
            let progress: Double
        }
        struct ProbeStats: Decodable {
            let days: Double
            let daily: [ProbeDaily]
            let today: ProbePeriod
            let week: ProbePeriod
            let overall: ProbeOverall
            let topBooks: [ProbeTopBook]
            let bookCount: Double
            let readingNow: Double
        }
        struct ProbeHighlight: Decodable {
            let id: String
            let bookId: String
            let text: String
            let color: String
            let note: String?
            let chapterTitle: String?
            let bookTitle: String?
        }
        struct ProbeBookmark: Decodable {
            let id: String
            let bookId: String
            let cfi: String
            let label: String?
        }
        struct Probe: Decodable {
            let progress: String
            let session: String
            let tooShort: String
            let stats: ProbeStats
            let bookCount: Int
            let highlightCount: Int
            let highlight: ProbeHighlight
            let allHighlight: ProbeHighlight
            let bookmark: ProbeBookmark
            let bookmarksLeft: Int
            let highlightsLeft: Int
        }

        let probe = try JSONDecoder().decode(Probe.self, from: Data(raw.utf8))

        XCTAssertEqual(probe.progress, "ok")
        XCTAssertEqual(probe.session, "ok")
        XCTAssertEqual(probe.tooShort, "skipped", "过短的会话不该落库")

        XCTAssertEqual(probe.stats.days, 14)
        XCTAssertEqual(probe.stats.daily.count, 14)
        XCTAssertEqual(probe.stats.today.minutes, 10, accuracy: 0.01)
        XCTAssertEqual(probe.stats.today.pages, 12, accuracy: 0.01)
        XCTAssertEqual(probe.stats.overall.totalSessions, 1)
        XCTAssertEqual(probe.stats.overall.totalBooks, 1)
        XCTAssertEqual(probe.stats.overall.totalReadingDays, 1)
        XCTAssertEqual(probe.stats.overall.totalReadingTime, 10, accuracy: 0.01)
        XCTAssertEqual(probe.stats.overall.currentStreak, 1)
        XCTAssertEqual(probe.stats.topBooks.first?.bookId, "book-1")
        XCTAssertEqual(probe.stats.topBooks.first?.title, "书灯")
        XCTAssertEqual(probe.stats.bookCount, 1)
        XCTAssertEqual(probe.stats.readingNow, 1, "0.42 进度应算在读")
        XCTAssertEqual(probe.bookCount, 1)

        XCTAssertEqual(probe.highlightCount, 1)
        XCTAssertEqual(probe.highlight.note, "记一笔")
        XCTAssertEqual(probe.highlight.color, "green")
        XCTAssertEqual(probe.highlight.text, "一盏照书的灯")
        XCTAssertEqual(probe.highlight.chapterTitle, "第一章")
        XCTAssertEqual(probe.allHighlight.bookTitle, "书灯", "跨书查询要带书名")
        XCTAssertEqual(probe.bookmark.label, "标记一下")
        XCTAssertEqual(probe.bookmarksLeft, 0)
        XCTAssertEqual(probe.highlightsLeft, 0)
    }

    /// 徽章：39 个定义要全给出来，带中文名（bootstrap 里 initI18nLanguage 跟系统语言走），
    /// 空书库时一枚都不该「已获得」。
    func testBadgesExposeAllDefinitionsWithNames() throws {
        let runtime = try ReadAnyRuntime(
            coreScript: try coreScript(),
            appScript: try ReadAnyRuntime.bundledAppBootstrap(),
            host: HostEnvironment(rootDirectory: try makeTemporaryRoot(), log: { _ in })
        )
        let raw = try XCTUnwrap(
            try runtime.wait(for: try XCTUnwrap(runtime.evaluate("ShudengApp.badges()")), timeout: 60)
                .toString()
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])

        let total = json["total"] as? Int ?? 0
        let earned = json["earned"] as? Int ?? -1
        let badges = try XCTUnwrap(json["badges"] as? [[String: Any]])
        let categories = try XCTUnwrap(json["categories"] as? [[String: Any]])

        XCTAssertEqual(total, 39, "core 的徽章定义数量变了：\(raw)")
        XCTAssertEqual(badges.count, total, "返回的徽章数量和 total 对不上")
        XCTAssertEqual(categories.count, 8, "八个分类：\(raw)")
        XCTAssertEqual(earned, 0, "空书库不该有已获得徽章")
        for badge in badges {
            let title = badge["title"] as? String ?? ""
            let id = badge["id"] as? String ?? ""
            XCTAssertFalse(title.isEmpty, "徽章 \(id) 没有标题")
            XCTAssertNotEqual(title, id, "徽章 \(id) 的标题没取到翻译，退回成 id 了")
            XCTAssertFalse((badge["desc"] as? String ?? "").isEmpty, "徽章 \(id) 没有描述")
        }
    }

    /// 阅读报告：周 / 月 / 全部三个区间都要能出摘要，字段名和 Swift 侧 Decodable 对齐。
    func testReportReturnsSummaryForEveryPeriod() throws {
        let runtime = try ReadAnyRuntime(
            coreScript: try coreScript(),
            appScript: try ReadAnyRuntime.bundledAppBootstrap(),
            host: HostEnvironment(rootDirectory: try makeTemporaryRoot(), log: { _ in })
        )

        for period in ["week", "month", "lifetime"] {
            let raw = try XCTUnwrap(
                try runtime.wait(
                    for: try XCTUnwrap(runtime.evaluate("ShudengApp.report({ period: \"\(period)\" })")),
                    timeout: 60
                ).toString()
            )
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            XCTAssertEqual(json["dimension"] as? String, period == "lifetime" ? "lifetime" : period, raw)
            let periodRef = try XCTUnwrap(json["period"] as? [String: Any], raw)
            XCTAssertFalse((periodRef["label"] as? String ?? "").isEmpty, "区间没有 label：\(raw)")
            XCTAssertFalse((periodRef["startDate"] as? String ?? "").isEmpty, "区间没有 startDate：\(raw)")
            let summary = try XCTUnwrap(json["summary"] as? [String: Any], raw)
            for key in ["totalReadingTime", "activeDays", "booksTouched", "completedBooks", "longestStreak"] {
                XCTAssertNotNil(summary[key], "摘要缺字段 \(key)：\(raw)")
            }
            XCTAssertNotNil(json["topBooks"] as? [[String: Any]], "topBooks 不是数组：\(raw)")
            XCTAssertNotNil(json["previous"] as? [[String: Any]], "previous 不是数组：\(raw)")
        }
    }

    /// AI 阅读报告：非流式，返回纯文本（需要 SHUDENG_TEST_BASE_URL / API_KEY / MODEL）。
    func testAIReportReturnsTextFromEndpoint() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let baseURL = environment["SHUDENG_TEST_BASE_URL"],
              let apiKey = environment["SHUDENG_TEST_API_KEY"],
              let model = environment["SHUDENG_TEST_MODEL"]
        else {
            throw XCTSkip("未配置测试端点（SHUDENG_TEST_BASE_URL / API_KEY / MODEL）")
        }

        let runtime = try ReadAnyRuntime(
            coreScript: try coreScript(),
            appScript: try ReadAnyRuntime.bundledAppBootstrap(),
            host: HostEnvironment(rootDirectory: try makeTemporaryRoot(), log: { _ in })
        )
        let payload: [String: Any] = [
            "system": "你是一位简洁的中文阅读教练。",
            "text": "阅读时长：2 小时。请写一句解读。",
            "apiKey": apiKey,
            "baseUrl": baseURL,
            "model": model,
        ]
        let payloadJSON = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let raw = try XCTUnwrap(
            try runtime.wait(
                for: try XCTUnwrap(runtime.evaluate("ShudengApp.aiReport(\(payloadJSON))")),
                timeout: 120
            ).toString()
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertNil(json["error"] as? String, "AI 解读报错：\(raw)")
        XCTAssertFalse((json["text"] as? String ?? "").isEmpty, "AI 解读没返回正文：\(raw)")
    }

    private final class ChunkCollector {
        private(set) var events: [String] = []
        var chunks: [String] { events.filter { $0.contains("\"type\":\"chunk\"") } }
        /// 把 chunk 事件里的 text 拼成完整回答。
        var answer: String {
            chunks
                .compactMap { event -> String? in
                    guard let data = event.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { return nil }
                    return object["text"] as? String
                }
                .joined()
        }

        func append(_ event: String) {
            events.append(event)
        }
    }
}
