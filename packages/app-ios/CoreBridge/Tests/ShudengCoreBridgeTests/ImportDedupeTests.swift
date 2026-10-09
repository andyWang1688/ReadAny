// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import XCTest
@testable import ShudengCoreBridge

/// 重复导入去重：书灯按文件内容哈希跳过同一本书，行为对齐旧版 ReadAny。
final class ImportDedupeTests: XCTestCase {
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

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sample.epub")
    }

    private func makeRuntime() throws -> (runtime: ReadAnyRuntime, root: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shudeng-dedupe-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runtime = try ReadAnyRuntime(
            coreScript: try coreScript(),
            appScript: try ReadAnyRuntime.bundledAppBootstrap(),
            host: HostEnvironment(rootDirectory: root, log: { _ in })
        )
        return (runtime, root)
    }

    private func copyFixture(named name: String, into root: URL) throws -> String {
        let relative = "books/\(name)"
        let destination = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: fixtureURL(), to: destination)
        return relative
    }

    private func importBook(_ runtime: ReadAnyRuntime, id: String, path: String) throws -> [String: Any] {
        let payload = """
        ShudengApp.importBook({ id: '\(id)', path: '\(path)', fileName: 'sample.epub', format: 'epub' })
        """
        let raw = try XCTUnwrap(
            try runtime.wait(for: try XCTUnwrap(runtime.evaluate(payload)), timeout: 60).toString()
        )
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    func testFailedImportCleansOnlyItsFilesAndCanRetry() throws {
        let (runtime, root) = try makeRuntime()
        let failedPath = try copyFixture(named: "failed.epub", into: root)
        let unrelated = try copyFixture(named: "unrelated.epub", into: root)
        let promise = try XCTUnwrap(runtime.evaluate("""
        (async () => {
          await ShudengApp.bootstrap();
          const query = __nativeDbQuery;
          __nativeDbQuery = (path, sql, params) => sql.startsWith('INSERT INTO books ')
            ? JSON.stringify({ error: 'SQLITE_BUSY fixture import' }) : query(path, sql, params);
          let error;
          try { await ShudengApp.importBook({ id: 'failed', path: '\(failedPath)', format: 'epub' }); } catch (e) { error = String(e); }
          __nativeDbQuery = query;
          return JSON.stringify({ error, count: JSON.parse(await ShudengApp.listBooks()).length });
        })()
        """))
        let raw = try XCTUnwrap(runtime.wait(for: promise, timeout: 30).toString())
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertTrue((output["error"] as? String)?.contains("SQLITE_BUSY") == true)
        XCTAssertEqual(output["count"] as? Int, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(failedPath).path))
        let covers = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("covers").path)) ?? []
        XCTAssertFalse(covers.contains { $0.hasPrefix("failed.") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(unrelated).path))
        let retryPath = try copyFixture(named: "retry.epub", into: root)
        let retry = try importBook(runtime, id: "retried", path: retryPath)
        XCTAssertEqual(retry["duplicate"] as? Bool, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(retryPath).path))
    }

    func testFailedMetadataReadDoesNotAccumulateBookCopies() throws {
        let (runtime, root) = try makeRuntime()
        for index in 1...2 {
            let relative = "books/invalid-\(index).epub"
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("invalid epub".utf8).write(to: file)
            let promise = try XCTUnwrap(runtime.evaluate("""
            (async () => {
              const nativeFs = __nativeFs;
              __nativeFs = (op, path, payload) => op === 'read' && path === '\(relative)'
                ? JSON.stringify({ error: 'fixture metadata read failure' })
                : nativeFs(op, path, payload);
              let error;
              try { await ShudengApp.importBook({ id: 'invalid-\(index)', path: '\(relative)', format: 'epub' }); }
              catch (e) { error = String(e); }
              __nativeFs = nativeFs;
              return error || '';
            })()
            """))
            let error = try XCTUnwrap(runtime.wait(for: promise, timeout: 30).toString())
            XCTAssertTrue(error.contains("fixture metadata read failure"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testPreflightFailureCleansCopyAndExistingBookConflictPreservesFile() throws {
        let (runtime, root) = try makeRuntime()
        let failedPath = try copyFixture(named: "preflight.epub", into: root)
        let promise = try XCTUnwrap(runtime.evaluate("""
        (async () => {
          await ShudengApp.bootstrap();
          const query = __nativeDbQuery;
          __nativeDbQuery = (path, sql, params) => sql.includes('FROM books WHERE id = ?')
            ? JSON.stringify({ error: 'SQLITE_BUSY preflight' }) : query(path, sql, params);
          let error;
          try { await ShudengApp.importBook({ id: 'preflight', path: '\(failedPath)', format: 'epub' }); } catch (e) { error = String(e); }
          __nativeDbQuery = query;
          return error || '';
        })()
        """))
        let error = try XCTUnwrap(runtime.wait(for: promise, timeout: 30).toString())
        XCTAssertTrue(error.contains("SQLITE_BUSY preflight"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(failedPath).path))
        let existingPath = try copyFixture(named: "existing.epub", into: root)
        _ = try importBook(runtime, id: "existing", path: existingPath)
        let conflict = try XCTUnwrap(runtime.evaluate("""
        (async () => {
          try { await ShudengApp.importBook({ id: 'existing', path: '\(existingPath)', format: 'epub' }); return ''; }
          catch (e) { return String(e); }
        })()
        """))
        let conflictError = try XCTUnwrap(runtime.wait(for: conflict, timeout: 30).toString())
        XCTAssertTrue(conflictError.contains("书籍 ID 已存在"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(existingPath).path))
    }

    func testWaitTimeoutDoesNotDeleteFilesBeforeDelayedCommit() throws {
        let (runtime, root) = try makeRuntime()
        let relative = try copyFixture(named: "delayed.epub", into: root)
        let promise = try XCTUnwrap(runtime.evaluate("""
        (async () => {
          await new Promise(resolve => setTimeout(resolve, 80));
          return ShudengApp.importBook({ id: 'delayed', path: '\(relative)', format: 'epub' });
        })()
        """))
        XCTAssertThrowsError(try runtime.wait(for: promise, timeout: 0.01))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path))
        let raw = try XCTUnwrap(runtime.wait(for: promise, timeout: 30).toString())
        XCTAssertTrue(raw.contains("delayed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path))
        let count = try XCTUnwrap(runtime.wait(for: XCTUnwrap(runtime.evaluate("ShudengApp.bookCount()")), timeout: 10).toString())
        XCTAssertEqual(count, "1")
    }

    /// 宿主指纹原语要和 CryptoKit 的 SHA-256 一致（导入去重全靠它）。
    func testFileDigestMatchesSHA256() throws {
        let (runtime, root) = try makeRuntime()
        let relative = try copyFixture(named: "digest.epub", into: root)

        let raw = try XCTUnwrap(runtime.evaluate("__nativeFileDigest('\(relative)')")?.toString())
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let expected = SHA256.hash(data: try Data(contentsOf: fixtureURL()))
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(payload["sha256"] as? String, expected)
        XCTAssertEqual(payload["size"] as? Int, try Data(contentsOf: fixtureURL()).count)
    }

    /// 同一份文件导入两次：第二次标重复，书库里只有一本。
    func testImportingSameFileTwiceIsSkipped() throws {
        let (runtime, root) = try makeRuntime()
        let firstPath = try copyFixture(named: "first.epub", into: root)
        let secondPath = try copyFixture(named: "second.epub", into: root)

        let first = try importBook(runtime, id: "book-1", path: firstPath)
        XCTAssertEqual(first["duplicate"] as? Bool, false)
        XCTAssertNotNil(first["book"] as? [String: Any])

        let second = try importBook(runtime, id: "book-2", path: secondPath)
        XCTAssertEqual(second["duplicate"] as? Bool, true, "第二份同样的文件没被识别成重复: \(second)")
        let duplicateBook = try XCTUnwrap(second["book"] as? [String: Any])
        XCTAssertEqual(duplicateBook["id"] as? String, "book-1", "重复导入应该指向已有那本")

        let listRaw = try XCTUnwrap(
            try runtime.wait(for: try XCTUnwrap(runtime.evaluate("ShudengApp.listBooks()")), timeout: 30).toString()
        )
        let books = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(listRaw.utf8)) as? [[String: Any]]
        )
        XCTAssertEqual(books.count, 1, "书库里出现了重复书: \(listRaw)")
    }
}
