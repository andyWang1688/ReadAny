// 临时验证：沿用旧版 ReadAny（RN）的数据目录后，书库 / 阅读统计能直接读出来。
import XCTest
@testable import ShudengCoreBridge

final class LegacyDataTests: XCTestCase {
    func testLegacyLibraryAndStatsLoad() throws {
        let source = ProcessInfo.processInfo.environment["SHUDENG_LEGACY_ROOT"]
            ?? "/private/tmp/legacy-docs"
        guard FileManager.default.fileExists(atPath: source) else {
            throw XCTSkip("缺少旧数据: \(source)")
        }
        let corePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Generated/core.js")

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shudeng-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: root)

        let runtime = try ReadAnyRuntime(
            coreScript: try String(contentsOf: corePath, encoding: .utf8),
            appScript: try ReadAnyRuntime.bundledAppBootstrap(),
            host: HostEnvironment(rootDirectory: root, log: { _ in })
        )

        let books = try XCTUnwrap(
            try runtime.wait(for: try XCTUnwrap(runtime.evaluate("ShudengApp.listBooks()")), timeout: 60).toString()
        )
        print("LEGACY_BOOKS=\(books.prefix(500))")
        XCTAssertTrue(books.contains("大道"), "旧书库没读到: \(books)")
        XCTAssertTrue(books.contains("books/855b7873"), "旧书路径不对: \(books)")

        let stats = try XCTUnwrap(
            try runtime.wait(
                for: try XCTUnwrap(runtime.evaluate("ShudengApp.stats({ days: 14 })")),
                timeout: 60
            ).toString()
        )
        print("LEGACY_STATS=\(stats.prefix(600))")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(stats.utf8)) as? [String: Any])
        let overall = json["overall"] as? [String: Any] ?? [:]
        XCTAssertEqual(overall["totalSessions"] as? Double, 5)
        XCTAssertGreaterThan(overall["totalReadingTime"] as? Double ?? 0, 0)

        // 旧书文件与封面必须在新的根目录下能被解析到。
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("books/855b7873-3b38-47a2-95a3-69508e5bbfd0.epub").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("SQLite/readany.db").path))
    }
}
