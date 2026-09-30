// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ShudengCoreBridge

/// 语义索引：抽章节 → 端侧向量（Apple NLEmbedding）→ 落库 → 跨书检索 → 删索引。
final class SemanticIndexTests: XCTestCase {
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
        return try String(contentsOfFile: repoPath.path, encoding: .utf8)
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sample.epub")
    }

    private func makeRuntime() throws -> (runtime: ReadAnyRuntime, root: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shudeng-semantic-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runtime = try ReadAnyRuntime(
            coreScript: try coreScript(),
            appScript: try ReadAnyRuntime.bundledAppBootstrap(),
            host: HostEnvironment(rootDirectory: root, log: { _ in })
        )
        return (runtime, root)
    }

    private func call(
        _ runtime: ReadAnyRuntime,
        _ expression: String,
        timeout: TimeInterval = 120
    ) throws -> [String: Any] {
        let raw = try XCTUnwrap(
            try runtime.wait(for: try XCTUnwrap(runtime.evaluate(expression)), timeout: timeout).toString()
        )
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private func json(_ value: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    func testEpubChapterExtractionKeepsSegments() throws {
        let (runtime, _) = try makeRuntime()
        let raw = try XCTUnwrap(try runtime.evaluate("ReadAnyCore.epubText ? 'yes' : 'no'")?.toString())
        XCTAssertEqual(raw, "yes")

        // 直接把 fixture 的字节喂给抽取器（离线路径），顺带守住 container.xml 里
        // `<rootfiles>` 被当成 `<rootfile>` 的老坑。
        let bytes = try Data(contentsOf: fixtureURL())
        let base64 = bytes.base64EncodedString()
        let payload = try XCTUnwrap(
            try runtime.evaluate(
                """
                (() => {
                  const raw = atob('\(base64)');
                  const bytes = new Uint8Array(raw.length);
                  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
                  const chapters = ReadAnyCore.epubText.extractEpubChapters(bytes);
                  return JSON.stringify({
                    count: chapters.length,
                    titles: chapters.map((c) => c.title),
                    segments: chapters.map((c) => c.segments.length),
                    firstLine: chapters[0].content.split('\\n')[0],
                  });
                })()
                """
            )?.toString()
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(json["count"] as? Int, 2)
        XCTAssertEqual((json["segments"] as? [Int])?.count, 2)
        XCTAssertTrue(((json["segments"] as? [Int]) ?? []).allSatisfy { $0 > 0 })
        XCTAssertTrue(((json["firstLine"] as? String) ?? "").contains("第一章"))
    }

    func testVectorizeBookThenSearchAndDelete() throws {
        let (runtime, root) = try makeRuntime()

        let relative = "books/book-1.epub"
        let destination = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: fixtureURL(), to: destination)

        let imported = try call(
            runtime,
            "ShudengApp.importBook(\(json(["id": "book-1", "path": relative, "fileName": "sample.epub", "format": "epub"])))"
        )
        XCTAssertEqual(imported["duplicate"] as? Bool, false)

        let info = try call(runtime, "ShudengApp.embeddingInfo()")
        guard info["available"] as? Bool == true else {
            throw XCTSkip("这台机器上没有可用的端侧向量模型：\(info["error"] ?? "unknown")")
        }
        let modelId = try XCTUnwrap(info["modelId"] as? String)
        XCTAssertTrue(modelId.hasPrefix("apple-nl-"), "端侧向量模型出处不对：\(modelId)")
        XCTAssertGreaterThan(info["dimensions"] as? Int ?? 0, 0)

        let started = try call(runtime, "ShudengApp.vectorizeBook(\(json(["bookId": "book-1"])))")
        XCTAssertNil(started["error"], "建索引失败：\(started["error"] ?? "")")
        XCTAssertEqual(started["ok"] as? Bool, true)

        let status = try call(runtime, "ShudengApp.vectorizeStatus()")
        XCTAssertEqual(status["status"] as? String, "done")
        XCTAssertGreaterThan(status["chunks"] as? Int ?? 0, 0)

        let indexed = try runtime.wait(
            for: try XCTUnwrap(runtime.evaluate("ShudengApp.vectorizedBooks()")),
            timeout: 60
        ).toString()
        let rows = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(indexed).utf8)) as? [[String: Any]]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["bookId"] as? String, "book-1")
        XCTAssertEqual(rows.first?["isVectorized"] as? Bool, true)

        // 中文提问命中第一章（WKWebView 分页那段）。
        let hit = try call(runtime, "ShudengApp.semanticSearch(\(json(["query": "WKWebView 怎么分页显示中文", "topK": 5])))")
        let results = try XCTUnwrap(hit["results"] as? [[String: Any]])
        XCTAssertFalse(results.isEmpty, "语义检索没有命中任何段落")
        XCTAssertEqual(results.first?["bookId"] as? String, "book-1")
        XCTAssertFalse(((results.first?["content"] as? String) ?? "").isEmpty)
        XCTAssertEqual(hit["scanned"] as? Int, 1)

        // 只有书里有的词：证明是真检索，不是「有啥吐啥」。
        let bridge = try call(runtime, "ShudengApp.semanticSearch(\(json(["query": "宿主的网络和数据库由谁提供", "topK": 5])))")
        let bridgeResults = try XCTUnwrap(bridge["results"] as? [[String: Any]])
        XCTAssertEqual(bridgeResults.first?["chapterIndex"] as? Int, 1)

        _ = try call(runtime, "ShudengApp.deleteVectors(\(json(["bookId": "book-1"])))")
        let afterDelete = try runtime.wait(
            for: try XCTUnwrap(runtime.evaluate("ShudengApp.vectorizedBooks()")),
            timeout: 60
        ).toString()
        let remaining = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(afterDelete).utf8)) as? [Any]
        )
        XCTAssertTrue(remaining.isEmpty)
    }

    /// 书建过索引之后，问书里的事要能自动带上原文（事件 context），而不是只把书名丢给模型。
    func testChatInjectsRetrievedPassages() throws {
        guard let baseURL = ProcessInfo.processInfo.environment["SHUDENG_MOCK_LLM_URL"], !baseURL.isEmpty else {
            throw XCTSkip("未设置 SHUDENG_MOCK_LLM_URL，先启动 scripts/mock-llm-server.mjs")
        }
        let (runtime, root) = try makeRuntime()

        let relative = "books/book-1.epub"
        let destination = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: fixtureURL(), to: destination)
        _ = try call(
            runtime,
            "ShudengApp.importBook(\(json(["id": "book-1", "path": relative, "fileName": "sample.epub", "format": "epub"])))"
        )
        let info = try call(runtime, "ShudengApp.embeddingInfo()")
        guard info["available"] as? Bool == true else {
            throw XCTSkip("这台机器上没有可用的端侧向量模型")
        }
        let started = try call(runtime, "ShudengApp.vectorizeBook(\(json(["bookId": "book-1"])))")
        XCTAssertEqual(started["ok"] as? Bool, true)

        let events = EventLog()
        runtime.host.onChatEvent = { requestID, eventJSON in events.append(requestID, eventJSON) }

        let payload = json([
            "requestId": "r-rag",
            "provider": "openai",
            "apiKey": "mock-key",
            "model": "mock-model",
            "baseUrl": baseURL,
            "text": "书里怎么讲 WKWebView 分页？",
            "language": "zh",
            "book": ["id": "book-1", "meta": ["title": "样章", "author": ""]],
        ])
        let promise = try XCTUnwrap(runtime.evaluate("ShudengApp.chat(\(payload))"))
        XCTAssertEqual(try runtime.wait(for: promise, timeout: 60).toString(), "ok")

        let contextEvent = events.last(ofType: "context")
        let count = (contextEvent?["count"] as? Int) ?? 0
        XCTAssertGreaterThan(count, 0, "对话没有注入检索到的原文：\(events.types())")
    }
}

/// 事件回调发生在 JS 线程上，测试里只做追加。
private final class EventLog: @unchecked Sendable {
    private var entries: [(requestID: String, json: String)] = []

    func append(_ requestID: String, _ json: String) {
        entries.append((requestID, json))
    }

    func types() -> [String] {
        entries.compactMap { object(of: $0.json)?["type"] as? String }
    }

    func last(ofType type: String) -> [String: Any]? {
        for entry in entries.reversed() {
            guard let object = object(of: entry.json), object["type"] as? String == type else { continue }
            return object
        }
        return nil
    }

    private func object(of json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
