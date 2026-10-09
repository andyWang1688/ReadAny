// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ShudengCoreBridge

/// 宿主 SQLite 桥：写失败必须报错，不能假装成功。
final class SQLiteDatabaseTests: XCTestCase {
    private func makeDatabase() throws -> (SQLiteDatabase, String) {
        let path = NSTemporaryDirectory() + "shudeng-sqlite-\(UUID().uuidString).db"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return (try SQLiteDatabase(path: path), path)
    }

    private func jsonQuery(_ database: SQLiteDatabase, _ sql: String, _ params: [Any] = []) throws -> [String: Any] {
        let raw = try database.jsonQuery(sql, paramsJSON: String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self))
        return (try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) ?? [:]
    }

    /// NOT NULL 约束 → 必须抛错（以前 sqlite3_step 的失败被吞掉，写库失败看起来是成功的）。
    func testInsertViolatingNotNullThrows() throws {
        let (database, _) = try makeDatabase()
        _ = try database.execute("CREATE TABLE t (id TEXT PRIMARY KEY, name TEXT NOT NULL)")

        XCTAssertThrowsError(try database.execute("INSERT INTO t (id, name) VALUES (?, ?)", ["a", NSNull()])) { error in
            XCTAssertTrue(
                String(describing: error).contains("NOT NULL"),
                "错误信息里应该带 SQLite 原因: \(error)"
            )
        }
        let rows = try jsonQuery(database, "SELECT id FROM t")["rows"] as? [[String: Any]]
        XCTAssertEqual(rows?.count, 0, "失败的写入不该留下数据")
    }

    /// 外键约束 → 必须抛错（书签挂在不存在的书上时要报错，而不是静默丢）。
    func testInsertViolatingForeignKeyThrows() throws {
        let (database, _) = try makeDatabase()
        _ = try database.execute("PRAGMA foreign_keys = ON")
        _ = try database.execute("CREATE TABLE books (id TEXT PRIMARY KEY)")
        _ = try database.execute(
            "CREATE TABLE bookmarks (id TEXT PRIMARY KEY, book_id TEXT NOT NULL, cfi TEXT NOT NULL, FOREIGN KEY (book_id) REFERENCES books(id))"
        )

        XCTAssertThrowsError(try database.execute(
            "INSERT INTO bookmarks (id, book_id, cfi) VALUES (?, ?, ?)",
            ["bm-1", "missing-book", "epubcfi(/6/2)"]
        ))
    }

    /// 一个字符串里的多条 SQL 要全部执行（core 的迁移里有这种写法）。
    func testMultipleStatementsInOneCall() throws {
        let (database, _) = try makeDatabase()
        _ = try database.execute("CREATE TABLE m1 (id INTEGER); CREATE TABLE m2 (id INTEGER);")

        let rows = try jsonQuery(
            database,
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'm%' ORDER BY name"
        )["rows"] as? [[String: Any]]
        XCTAssertEqual(rows?.compactMap { $0["name"] as? String }, ["m1", "m2"])
    }

    /// 成功写入仍然返回空 rows，不因为加了错误检查而变脸。
    func testSuccessfulWriteRoundTrip() throws {
        let (database, _) = try makeDatabase()
        _ = try database.execute("CREATE TABLE t (id TEXT PRIMARY KEY, value INTEGER)")
        _ = try database.execute("INSERT INTO t (id, value) VALUES (?, ?)", ["a", 7])
        let rows = try jsonQuery(database, "SELECT id, value FROM t")["rows"] as? [[String: Any]]
        XCTAssertEqual(rows?.count, 1)
        XCTAssertEqual(rows?.first?["value"] as? Int, 7)
    }

    /// 空语句 / 纯注释不该报错。
    func testEmptyStatementIsHarmless() throws {
        let (database, _) = try makeDatabase()
        XCTAssertNoThrow(try database.execute("-- 只是注释"))
        XCTAssertNoThrow(try database.execute(";"))
    }
}
