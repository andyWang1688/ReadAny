// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ShudengCoreBridge

/// 流式对话的桥接回归：本地 mock 端点（scripts/mock-llm-server.mjs）回 SSE，
/// core 收到的 token 必须一个不落地变成 __nativeChatEvent。真机/模拟器只验 UI，这里验数据面。
final class ChatStreamingTests: XCTestCase {
    private func coreScript() throws -> String {
        if let path = ProcessInfo.processInfo.environment["SHUDENG_CORE_JS"], !path.isEmpty {
            return try String(contentsOfFile: path, encoding: .utf8)
        }
        let repoPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Generated/core.js")
        guard FileManager.default.fileExists(atPath: repoPath.path) else {
            throw XCTSkip("缺少 \(repoPath.path)，先运行 packages/app-ios/scripts/build-core-bundle.mjs")
        }
        return try String(contentsOf: repoPath, encoding: .utf8)
    }

    private func makeRuntime() throws -> ReadAnyRuntime {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shudeng-chat-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try ReadAnyRuntime(
            coreScript: try coreScript(),
            appScript: try ReadAnyRuntime.bundledAppBootstrap(),
            host: HostEnvironment(rootDirectory: root, log: { _ in })
        )
    }

    func testChatStreamsTokensAndDone() throws {
        for provider in ["openai", "deepseek", "custom"] {
            try assertStreams(provider: provider)
        }
    }

    /// 选中翻译走的是非流式 chat/completions：端点必须能一次把整段 JSON 读回来。
    func testTranslateReturnsWholeAnswer() throws {
        guard let baseURL = ProcessInfo.processInfo.environment["SHUDENG_MOCK_LLM_URL"], !baseURL.isEmpty else {
            throw XCTSkip("未设置 SHUDENG_MOCK_LLM_URL，先启动 scripts/mock-llm-server.mjs")
        }

        let runtime = try makeRuntime()
        let promise = try XCTUnwrap(
            runtime.evaluate(
                """
                ShudengApp.translate({
                  text: '信息差不是靠读得多', targetLang: 'en',
                  apiKey: 'mock-key', baseUrl: '\(baseURL)', model: 'mock-model',
                })
                """
            )
        )
        let result = try XCTUnwrap(runtime.wait(for: promise, timeout: 30).toString())
        XCTAssertTrue(result.contains("收到"), "translate() 没有拿到译文：\(result)")
    }

    private func assertStreams(provider: String) throws {
        guard let baseURL = ProcessInfo.processInfo.environment["SHUDENG_MOCK_LLM_URL"], !baseURL.isEmpty else {
            throw XCTSkip("未设置 SHUDENG_MOCK_LLM_URL，先启动 scripts/mock-llm-server.mjs")
        }

        let runtime = try makeRuntime()
        let events = EventSink()
        runtime.host.onChatEvent = { requestID, eventJSON in events.append(requestID, eventJSON) }

        let promise = try XCTUnwrap(
            runtime.evaluate(
                """
                ShudengApp.chat({
                  requestId: 'r1', provider: '\(provider)', apiKey: 'mock-key', model: 'mock-model',
                  baseUrl: '\(baseURL)', text: '你好', language: 'zh',
                })
                """
            )
        )
        let result = try runtime.wait(for: promise, timeout: 60).toString()
        XCTAssertEqual(result, "ok", "\(provider): chat() 没有正常结束")

        let chunks = events.text(for: "chunk")
        XCTAssertFalse(chunks.isEmpty, "\(provider): 一个 token 都没推给宿主：\(events.types())")
        XCTAssertTrue(chunks.contains("收到"), "\(provider): token 内容不对：\(chunks)")
        XCTAssertEqual(events.types().last, "done", "\(provider): 没有收到 done 事件：\(events.types())")
    }
}

/// 事件回调发生在 JS 线程上，测试里只做追加，读之前由 wait() 的 RunLoop 保证同步。
private final class EventSink: @unchecked Sendable {
    private var entries: [(requestID: String, json: String)] = []

    func append(_ requestID: String, _ json: String) {
        entries.append((requestID, json))
    }

    func types() -> [String] {
        entries.map { entry in
            guard let data = entry.json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String
            else { return "?" }
            return type
        }
    }

    func text(for type: String) -> String {
        entries.compactMap { entry in
            guard let data = entry.json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == type
            else { return nil }
            return object["text"] as? String
        }.joined()
    }
}
