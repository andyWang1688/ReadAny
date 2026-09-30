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

    /// 模型偶尔会把工具调用标记当正文吐出来（DeepSeek 的 ｜DSML｜ 最常见，真机上就是「乱码」）：
    /// 书灯不执行工具，这类 markup 不能显示给读者；整段都是 markup 时要换成一句人话。
    func testChatHidesToolCallMarkup() throws {
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
                  requestId: 'r1', provider: 'openai', apiKey: 'mock-key', model: 'mock-model',
                  baseUrl: '\(baseURL)', text: '暗号：工具调用', language: 'zh',
                })
                """
            )
        )
        XCTAssertEqual(try runtime.wait(for: promise, timeout: 60).toString(), "ok")

        let body = events.text(for: "chunk")
        XCTAssertFalse(body.contains("DSML"), "工具调用标记漏进正文了：\(body)")
        XCTAssertFalse(body.contains("getSurroundingContext"), "工具参数漏进正文了：\(body)")
        XCTAssertTrue(body.contains("工具调用指令"), "整段都是标记时应当给读者一句说明：\(body)")
    }

    /// 以前存进历史里的工具调用标记：打开老对话时也要洗干净，不能一打开就是一片「乱码」。
    func testLoadThreadCleansStoredToolMarkup() throws {
        let runtime = try makeRuntime()
        let bar = "\u{FF5C}\u{FF5C}DSML\u{FF5C}\u{FF5C}"
        let raw = "<\(bar) calls>\\n<\(bar) invoke name=\"getCurrentChapter\">\\n</\(bar) invoke>"
        let promise = try XCTUnwrap(
            runtime.evaluate(
                """
                (async () => {
                  const created = JSON.parse(await ShudengApp.createThread({ title: '老对话' }));
                  await ShudengApp.appendMessage({
                    threadId: created.id, role: 'assistant', content: '\(raw)',
                  });
                  return await ShudengApp.loadThread({ id: created.id });
                })()
                """
            )
        )
        let json = try XCTUnwrap(runtime.wait(for: promise, timeout: 30).toString())
        XCTAssertFalse(json.contains("DSML"), "历史里的工具标记漏出来了：\(json)")
        XCTAssertTrue(json.contains("工具调用指令"), "整条都是标记时应当给读者一句说明：\(json)")
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

    /// 书灯没有工具执行器：系统提示一个工具都不许广播，否则 DeepSeek 会照着吐工具调用标记，
    /// 读者看到的就是「乱码」。
    func testSystemPromptDropsToolInstructionWhenNoTools() throws {
        let runtime = try makeRuntime()
        let json = try XCTUnwrap(
            runtime.evaluate(
                """
                JSON.stringify({
                  prompt: ReadAnyCore.ai.buildSystemPrompt({
                    book: null, semanticContext: null, enabledSkills: [],
                    isVectorized: false, userLanguage: 'zh', allowedToolNames: [],
                  }),
                })
                """
            )?.toString()
        )
        let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let prompt = root?["prompt"] as? String ?? ""
        XCTAssertFalse(prompt.isEmpty, "buildSystemPrompt 没返回内容：\(json)")
        XCTAssertFalse(prompt.contains("MUST use the provided tools"), prompt)
        XCTAssertTrue(prompt.contains("no tools this turn"), prompt)
    }

    /// 端点连不上时必须把失败回报给宿主。以前这条链会把 rejection 吞掉，
    /// 界面一直停在「正在生成…」，历史里也留不下任何东西。
    func testChatReportsUnreachableEndpoint() throws {
        let runtime = try makeRuntime()
        let events = EventSink()
        runtime.host.onChatEvent = { requestID, eventJSON in events.append(requestID, eventJSON) }

        // 127.0.0.1:9 是 discard 端口：本机不会有服务在听。
        let promise = try XCTUnwrap(
            runtime.evaluate(
                """
                ShudengApp.chat({
                  requestId: 'r1', provider: 'openai', apiKey: 'mock-key', model: 'mock-model',
                  baseUrl: 'http://127.0.0.1:9/v1', text: '你好', language: 'zh',
                })
                """
            )
        )
        XCTAssertEqual(try runtime.wait(for: promise, timeout: 60).toString(), "error")
        XCTAssertEqual(events.types().last, "error", "失败没有回报给宿主：\(events.types())")
        XCTAssertTrue(
            events.errorMessages().contains("连不上"),
            "连不上端点时不该把英文原样丢给读者：\(events.errorMessages())"
        )
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

    func errorMessages() -> String {
        entries.compactMap { entry in
            guard let data = entry.json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "error"
            else { return nil }
            return object["message"] as? String
        }.joined(separator: " | ")
    }
}
