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
