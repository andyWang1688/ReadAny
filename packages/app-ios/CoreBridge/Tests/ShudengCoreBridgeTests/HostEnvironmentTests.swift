// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ShudengCoreBridge

final class HostEnvironmentTests: XCTestCase {
    private func makeHost() throws -> (host: HostEnvironment, root: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shudeng-host-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (try HostEnvironment(rootDirectory: root, log: { _ in }), root)
    }

    /// 相对路径也要落在沙箱里：core 传 "../../.." 时不能被 standardizedFileURL 带出去。
    func testResolveRejectsEscapingPaths() throws {
        let (host, root) = try makeHost()

        XCTAssertEqual(try host.resolve("books/one.epub").lastPathComponent, "one.epub")
        XCTAssertEqual(
            try host.resolve("SQLite/readany.db").path,
            root.standardizedFileURL.appendingPathComponent("SQLite/readany.db").path
        )

        XCTAssertThrowsError(try host.resolve("../../etc/passwd"))
        XCTAssertThrowsError(try host.resolve("books/../../../outside.txt"))
        XCTAssertThrowsError(try host.resolve("/etc/passwd"))
    }

    /// JS 侧读的路径表要带设备语言（core 的 i18n 靠它选默认语言）。
    func testPathsExposeDeviceLocale() throws {
        let (host, root) = try makeHost()
        let runtime = try ReadAnyRuntime(coreScript: "globalThis.__ready = true;", host: host)

        let raw = try XCTUnwrap(runtime.evaluate("__nativePaths()")?.toString())
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        )

        XCTAssertEqual(payload["locale"] as? String, HostEnvironment.deviceLocaleIdentifier())
        XCTAssertEqual(payload["appData"] as? String, root.standardizedFileURL.path)
        XCTAssertFalse((payload["appVersion"] as? String ?? "").isEmpty)
    }

    /// 脚本里的 crypto 必须走宿主的 Security 随机数：
    /// 走 Math.random 会让 id 可预测，而宿主原语被跳过时说明 shim 里有两个 crypto 定义。
    func testCryptoUsesHostRandomBytes() throws {
        let (host, _) = try makeHost()
        let runtime = try ReadAnyRuntime(coreScript: "globalThis.__ready = true;", host: host)
        let raw = try XCTUnwrap(
            runtime.evaluate(
                """
                (() => {
                  const original = __nativeRandomBytes;
                  let calls = 0;
                  __nativeRandomBytes = (n) => { calls += 1; return original(n); };
                  const bytes = new Uint8Array(16);
                  crypto.getRandomValues(bytes);
                  const first = crypto.randomUUID();
                  const second = crypto.randomUUID();
                  __nativeRandomBytes = original;
                  return JSON.stringify({
                    calls,
                    nonZero: Array.from(bytes).some((value) => value !== 0),
                    first,
                    second,
                  });
                })()
                """
            )?.toString()
        )
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        )

        XCTAssertGreaterThan(payload["calls"] as? Int ?? 0, 0, "crypto 没有走宿主随机数")
        XCTAssertEqual(payload["nonZero"] as? Bool, true, "随机字节全是 0，宿主返回值没解析对")
        let first = payload["first"] as? String ?? ""
        XCTAssertEqual(first.count, 36)
        XCTAssertEqual(first, first.lowercased())
        XCTAssertNotEqual(first, payload["second"] as? String, "两次 randomUUID 不能一样")
    }

    /// shim 里的 setInterval 用「表大小 + 1」当 id 时会撞号：清掉一个再新建就顶掉
    /// 还在跑的那个（既停不掉也清不干净）。id 必须单调递增。
    func testIntervalIdsDoNotCollideAfterClear() throws {
        let (host, _) = try makeHost()
        let runtime = try ReadAnyRuntime(coreScript: "globalThis.__ready = true;", host: host)
        let raw = try XCTUnwrap(
            runtime.evaluate(
                """
                (() => {
                  const first = setInterval(() => {}, 60000);
                  const second = setInterval(() => {}, 60000);
                  clearInterval(first);
                  const third = setInterval(() => {}, 60000);
                  const ids = [first, second, third];
                  ids.forEach(clearInterval);
                  return JSON.stringify(ids);
                })()
                """
            )?.toString()
        )
        let ids = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Int]
        )

        XCTAssertEqual(Set(ids).count, 3, "清掉一个 interval 之后新建的 id 撞上了: \(ids)")
    }
}
