// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ShudengCoreBridge

final class ResponseCloneTests: XCTestCase {
    private func runtime() throws -> ReadAnyRuntime {
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Generated/core.js")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("response-clone-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try ReadAnyRuntime(coreScript: String(contentsOf: core, encoding: .utf8),
            host: HostEnvironment(rootDirectory: root, log: { _ in }))
    }
    private func result(_ runtime: ReadAnyRuntime, _ script: String) throws -> [String: Any] {
        let raw = try XCTUnwrap(runtime.wait(for: XCTUnwrap(runtime.evaluate(script)), timeout: 10).toString())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }
    func testCloneKeepsIndependentBodiesHeadersAndUsage() throws {
        let output = try result(runtime(), """
        (async () => {
          const response = new Response('你好 clone', { status: 400, statusText: 'Bad Request', headers: { 'x-test': 'yes' }, url: 'https://fixture.invalid' });
          const clone = response.clone();
          clone.headers.set('x-test', 'changed');
          const usedBefore = response.bodyUsed;
          const clonedText = await clone.text();
          const originalText = await response.text();
          let readRejected = false, cloneRejected = false;
          try { await response.text(); } catch { readRejected = true; }
          try { response.clone(); } catch { cloneRejected = true; }
          const locked = new Response('locked');
          const reader = locked.body.getReader();
          let lockedRejected = false;
          try { locked.clone(); } catch { lockedRejected = true; }
          reader.releaseLock();
          return JSON.stringify({ clonedText, originalText, status: clone.status, statusText: clone.statusText,
            header: response.headers.get('x-test'), url: clone.url, usedBefore, usedAfter: response.bodyUsed,
            readRejected, cloneRejected, lockedRejected });
        })()
        """)
        XCTAssertEqual(output["clonedText"] as? String, "你好 clone")
        XCTAssertEqual(output["originalText"] as? String, "你好 clone")
        XCTAssertEqual(output["status"] as? Int, 400)
        XCTAssertEqual(output["statusText"] as? String, "Bad Request")
        XCTAssertEqual(output["header"] as? String, "yes")
        XCTAssertEqual(output["url"] as? String, "https://fixture.invalid")
        XCTAssertEqual(output["usedBefore"] as? Bool, false)
        for key in ["usedAfter", "readRejected", "cloneRejected", "lockedRejected"] { XCTAssertEqual(output[key] as? Bool, true, key) }
    }
    func testTeeSeparatesConsumptionCancellationAndErrors() throws {
        let output = try result(runtime(), """
        (async () => {
          let cancelled = 0, pulls = 0;
          const source = new ReadableStream({
            pull(controller) { if (++pulls <= 3) controller.enqueue(new Uint8Array([pulls])); else controller.close(); },
            cancel() { cancelled++; },
          });
          const [left, right] = source.tee();
          const leftReader = left.getReader(), rightReader = right.getReader();
          const first = await leftReader.read();
          first.value[0] = 99;
          const firstRight = await rightReader.read();
          const leftCancel = leftReader.cancel('left only');
          const remaining = [];
          for (;;) { const item = await rightReader.read(); if (item.done) break; remaining.push(item.value[0]); }
          await leftCancel;
          const firstCancelled = cancelled;
          let reasons;
          const both = new ReadableStream({ cancel(value) { reasons = value; } }).tee();
          await Promise.all([both[0].cancel('a'), both[1].cancel('b')]);
          const failing = new Response(new ReadableStream({ pull(controller) { controller.error(new Error('fixture error')); } }));
          const copy = failing.clone();
          const failures = await Promise.all([failing.text().catch(e => e.message), copy.text().catch(e => e.message)]);
          return JSON.stringify({ firstRight: firstRight.value[0], remaining, firstCancelled, reasons, failures });
        })()
        """)
        XCTAssertEqual(output["firstRight"] as? Int, 1, "Byte branches must not alias mutable buffers")
        XCTAssertEqual(output["remaining"] as? [Int], [2, 3])
        XCTAssertEqual(output["firstCancelled"] as? Int, 0, "Cancelling one branch must not abort the other")
        XCTAssertEqual(output["reasons"] as? [String], ["a", "b"])
        XCTAssertEqual(output["failures"] as? [String], ["fixture error", "fixture error"])
    }
    func testCancelClosedBranchDiscardsUnreadBytes() throws {
        let output = try result(runtime(), """
        (async () => {
          const original = new Response('queued branch');
          const copy = original.clone();
          await original.text();
          const reader = copy.body.getReader();
          await reader.cancel();
          const after = await reader.read();
          return JSON.stringify({ done: after.done, noValue: after.value === undefined });
        })()
        """)
        XCTAssertEqual(output["done"] as? Bool, true)
        XCTAssertEqual(output["noValue"] as? Bool, true)
    }

    func testEndpointRetriesTokenLimitUsingActualModel() throws {
        let output = try result(runtime(), """
        (async () => {
          const requests = [];
          ReadAnyCore.ai.setStreamingFetch(async (url, init) => {
            const payload = JSON.parse(init.body);
            requests.push(payload);
            const invalid = payload.max_tokens > 100;
            return new Response(JSON.stringify(invalid ? { error: { message: 'max_tokens must not exceed 100', type: 'invalid_request_error' } } : {
              id: 'fixture', object: 'chat.completion', model: 'fixture', choices: [{ index: 0, message: { role: 'assistant', content: 'success' }, finish_reason: 'stop' }],
              usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
            }), { status: invalid ? 400 : 200, headers: { 'content-type': 'application/json' } });
          });
          const model = await ReadAnyCore.ai.createChatModelFromEndpoint({ id: 'fixture', name: 'fixture', provider: 'custom', apiKey: 'fixture', baseUrl: 'https://fixture.invalid/v1', models: ['fixture'] }, 'fixture', { streaming: false, maxTokens: 2048, maxRetries: 0 });
          const reply = await model.invoke([new ReadAnyCore.messages.HumanMessage('fixture')]);
          return JSON.stringify({ count: requests.length, first: requests[0].max_tokens, secondHasMaxTokens: 'max_tokens' in requests[1], content: reply.content });
        })()
        """)
        XCTAssertEqual(output["count"] as? Int, 2)
        XCTAssertEqual(output["first"] as? Int, 2048)
        XCTAssertEqual(output["secondHasMaxTokens"] as? Bool, false)
        XCTAssertEqual(output["content"] as? String, "success")
    }
}
