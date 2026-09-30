// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String)

    public var description: String {
        switch self {
        case .open(let message): "SQLite open failed: \(message)"
        case .prepare(let message): "SQLite statement failed: \(message)"
        }
    }
}

/// `IDatabase` 的宿主实现：打开一个 SQLite 文件（默认内存库），
/// 查询结果以 `{columns, rows}` 形状交给 JS。
public final class SQLiteDatabase {
    private var handle: OpaquePointer?

    public init(path: String = ":memory:") throws {
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError.open(message)
        }
    }

    deinit { sqlite3_close(handle) }

    public func execute(_ sql: String, _ params: [Any] = []) throws -> [[String: Any]] {
        try query(sql, params)
    }

    public func query(_ sql: String, _ params: [Any] = []) throws -> [[String: Any]] {
        var statement: OpaquePointer?
        var tail = ""
        let prepareCode = sql.withCString { cString -> Int32 in
            var tailPointer: UnsafePointer<CChar>?
            let code = sqlite3_prepare_v2(handle, cString, -1, &statement, &tailPointer)
            if let tailPointer { tail = String(cString: tailPointer) }
            return code
        }
        guard prepareCode == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            throw SQLiteError.prepare(failureMessage(handle, sql))
        }
        guard let statement else {
            // 空语句（只有注释或分号）时继续处理后面剩下的 SQL。
            return try runTail(tail, params: params)
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in params.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, position, text, -1, SQLITE_TRANSIENT)
            case let double as Double: sqlite3_bind_double(statement, position, double)
            case let int as Int: sqlite3_bind_int64(statement, position, Int64(int))
            case let bool as Bool: sqlite3_bind_int64(statement, position, bool ? 1 : 0)
            default: sqlite3_bind_null(statement, position)
            }
        }

        var columns: [String] = []
        for index in 0..<sqlite3_column_count(statement) {
            columns.append(String(cString: sqlite3_column_name(statement, index)))
        }

        var rows: [[Any]] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            var row: [Any] = []
            for index in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row.append(Int(sqlite3_column_int64(statement, index)))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(statement, index))
                case SQLITE_NULL: row.append(NSNull())
                default: row.append(String(cString: sqlite3_column_text(statement, index)))
                }
            }
            rows.append(row)
            step = sqlite3_step(statement)
        }
        // 写语句失败（NOT NULL / 外键 / 唯一约束…）也在这里报错：
        // 以前 step 的错误被吞掉，写库失败在 JS 侧看起来是成功的。
        guard step == SQLITE_DONE else {
            throw SQLiteError.prepare(failureMessage(handle, sql))
        }

        let records = rows.map { row in
            var record: [String: Any] = [:]
            for (index, name) in columns.enumerated() where index < row.count {
                record[name] = row[index]
            }
            return record
        }
        // 一个字符串里有多条 SQL（core 的迁移里有）时，把剩下的也执行掉。
        let rest = try runTail(tail, params: params)
        return rest.isEmpty ? records : records + rest
    }

    /// 执行 `sqlite3_prepare_v2` 留下的剩余 SQL（没有剩余就返回空）。
    private func runTail(_ tail: String, params: [Any]) throws -> [[String: Any]] {
        let rest = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return [] }
        return try query(rest, params)
    }

    private func failureMessage(_ handle: OpaquePointer?, _ sql: String) -> String {
        let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        let head = sql.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)
        return "\(reason) [\(head)]"
    }

    public func jsonQuery(_ sql: String, paramsJSON: String) throws -> String {
        let params = (try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8))) as? [Any] ?? []
        let rows = try query(sql, params)
        let payload: [String: Any] = ["rows": rows]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }
}
