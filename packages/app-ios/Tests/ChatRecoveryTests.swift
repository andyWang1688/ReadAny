// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

@MainActor final class RuntimeHost {
    enum State { case ready }
    let state = State.ready
    let core: ReadAnyRuntime
    var rootDirectory: URL { core.host.rootDirectory }
    var observer: ((String, String) -> Void)?
    var requestID = ""
    var failThreadReads = false
    var failThreadID: String?
    var loadOverride: String?
    var loseReplyReceipt = false
    var denyBackupCleanup = false

    init(_ core: ReadAnyRuntime) { self.core = core }
    func addChatObserver(owner: AnyObject, _ callback: @escaping (String, String) -> Void) -> UUID {
        observer = callback
        return UUID()
    }
    func appJSON(_ expression: String, timeout: TimeInterval = 30) throws -> String? {
        if expression.hasPrefix("ShudengApp.loadThread") {
            if failThreadReads || Self.payload(expression)["id"] as? String == failThreadID {
                throw NSError(domain: "fixture thread read", code: 1)
            }
            if let loadOverride { return loadOverride }
        }
        let result = try core.wait(for: core.evaluate(expression)!, timeout: timeout).toString()
        if expression.hasPrefix("ShudengApp.appendMessage"),
           Self.payload(expression)["role"] as? String == "assistant" {
            if denyBackupCleanup {
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: rootDirectory.path)
            }
            if loseReplyReceipt { throw NSError(domain: "fixture lost receipt", code: 1) }
        }
        return result
    }
    func appJSONOr(_ expression: String, fallback: String = "{}", timeout: TimeInterval = 30) -> String {
        (try? appJSON(expression, timeout: timeout)) ?? fallback
    }
    func startApp(_ expression: String) throws {
        requestID = Self.payload(expression)["requestId"] as! String
    }
    private static func payload(_ expression: String) -> [String: Any] {
        let start = expression.index(after: expression.firstIndex(of: "(")!)
        guard let value = try? JSONSerialization.jsonObject(with: Data(expression[start..<expression.index(before: expression.endIndex)].utf8)) as? [String: Any] else { return [:] }
        return value
    }
    func evaluate(_ expression: String) -> String? { try? core.evaluate(expression)?.toString() }
    func emit(_ type: String, text: String = "") {
        let data = try! JSONSerialization.data(withJSONObject: ["type": type, "text": text])
        observer?(requestID, String(decoding: data, as: UTF8.self))
    }
    func rejectReplies(_ enabled: Bool) throws {
        let script = enabled
            ? "ReadAnyCore.db.getDB().then(db=>db.execute(\"CREATE TEMP TRIGGER reject_reply BEFORE INSERT ON messages WHEN NEW.role='assistant' BEGIN SELECT RAISE(ABORT,'fixture reply write failure'); END\"))"
            : "ReadAnyCore.db.getDB().then(db=>db.execute('DROP TRIGGER reject_reply'))"
        _ = try appJSON(script)
    }
    func assistantRows() throws -> [[String: Any]] {
        let json = try appJSON("ReadAnyCore.db.getDB().then(db=>db.select(\"SELECT id, thread_id, content FROM messages WHERE role='assistant'\")).then(JSON.stringify)")!
        return try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
    }
}

struct LibraryStore { struct Book { let id: String; let filePath: String; let title: String; let author: String } }
struct AISettings {
    enum Provider: String { case openai }
    let provider = Provider.openai
    let baseURL = "http://fixture.invalid/v1", apiKey = "fixture", model = "fixture"
    let isConfigured = true
}
struct AISkill { let id: String; let inputParam: String? }

@main struct ChatRecoveryTests {
    @MainActor static func main() throws {
        var checks = 0, failures = 0
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: " + message) }
        }
        let app = CommandLine.arguments[1]
        let base = app + "/CoreBridge/"
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chat-recovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func runtime(_ directory: URL = root) throws -> RuntimeHost {
            let core = try ReadAnyRuntime(
                shim: String(contentsOfFile: base + "Sources/ShudengCoreBridge/Resources/bridge-shim.js", encoding: .utf8),
                coreScript: String(contentsOfFile: base + "Generated/core.js", encoding: .utf8),
                appScript: String(contentsOfFile: base + "Sources/ShudengCoreBridge/Resources/app-bootstrap.js", encoding: .utf8),
                host: HostEnvironment(rootDirectory: directory, log: { _ in }))
            let host = RuntimeHost(core)
            _ = try host.appJSON("ShudengApp.info()")
            return host
        }
        let backup = root.appendingPathComponent("pending-chat-reply.json")
        let firstHost = try runtime(), first = ChatService()
        first.attach(to: firstHost)
        first.send("提问", book: nil, contextText: nil, settings: AISettings())
        firstHost.emit("chunk", text: "可恢复回答")
        expect(!first.retryPendingReply() && first.isStreaming, "保存重试不得中断正在生成的回答")
        try firstHost.rejectReplies(true)
        firstHost.emit("done")
        expect(first.hasUnsavedReply && FileManager.default.fileExists(atPath: backup.path), "真实 SQLite 失败留下备份")
        let originalID = first.activeThreadId!, replyID = first.messages.last!.id
        let newerJSON = try firstHost.appJSON("ShudengApp.createThread({id:'newer',title:'其他对话'})")!
        expect(newerJSON.contains("newer"), "准备独立的较新会话")
        _ = try firstHost.appJSON("ShudengApp.appendMessage({id:'other-user',threadId:'newer',role:'user',content:'不相关的问题'})")
        _ = try firstHost.appJSON("ReadAnyCore.db.getDB().then(db=>db.execute(\"UPDATE threads SET updated_at=9999999999999 WHERE id='newer'\"))")

        let readFailureHost = try runtime()
        readFailureHost.failThreadID = originalID
        let readFailure = ChatService(); readFailure.attach(to: readFailureHost)
        expect(readFailure.hasUnsavedReply && readFailure.messages.last?.id == replyID, "读取原会话失败仍显示待恢复回答")
        expect(!readFailure.messages.contains(where: { $0.text == "不相关的问题" }), "恢复失败不得混入其他对话的历史")
        expect(FileManager.default.fileExists(atPath: backup.path), "原会话读取失败必须保留备份")

        let invalidHost = try runtime()
        invalidHost.loadOverride = #"{"id":"wrong","messages":[]}"#
        let invalid = ChatService(); invalid.attach(to: invalidHost)
        expect(invalid.hasUnsavedReply && invalid.error != nil && FileManager.default.fileExists(atPath: backup.path), "错误会话 ID 响应不得当作删除并清理备份")
        let incompleteJSON = String(decoding: try JSONSerialization.data(withJSONObject: ["id": originalID, "messages": []]), as: UTF8.self)
        invalidHost.loadOverride = incompleteJSON
        invalid.retryPendingReply()
        expect(invalid.hasUnsavedReply && FileManager.default.fileExists(atPath: backup.path), "缺少会话元数据的响应不等于已删除")

        let restoredHost = try runtime()
        try restoredHost.rejectReplies(true)
        let restored = ChatService()
        restored.attach(to: restoredHost)
        expect(restored.messages.last?.text == "可恢复回答" && restored.hasUnsavedReply, "重启恢复原回答并保留失败状态")
        expect(restored.activeThreadId == originalID && restored.messages.first?.text == "提问" && restored.messages.last?.id == replyID, "较新会话不能替代备份所属会话，消息 ID 稳定")
        restoredHost.failThreadReads = true
        restored.attach(to: restoredHost)
        expect(restored.messages.map(\.text) == ["提问", "可恢复回答"], "重复 attach 不重新加载或替换已恢复的待存对话")
        restoredHost.failThreadReads = false
        expect(!restored.startNewThread() && !restored.send("下一轮", book: nil, contextText: nil, settings: AISettings()), "持续失败时禁止切换和覆盖旧回答")
        try restoredHost.rejectReplies(false)
        restored.retryPendingReply()
        expect(!restored.hasUnsavedReply && !FileManager.default.fileExists(atPath: backup.path), "恢复存储后重试写入并清理备份")
        let rows = try restoredHost.assistantRows()
        expect(rows.count == 1 && rows.first?["id"] as? String == replyID && rows.first?["thread_id"] as? String == originalID, "恢复实际 SQLite 后仅插入原 ID 的一条回答")

        let corruptRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chat-corrupt-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: corruptRoot) }
        let corruptURL = corruptRoot.appendingPathComponent("pending-chat-reply.json")
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: corruptURL)
        let corruptHost = try runtime(corruptRoot)
        let corrupt = ChatService(); corrupt.attach(to: corruptHost)
        expect(corrupt.hasUnsavedReply && corrupt.error != nil, "损坏备份显示错误")
        expect(!corrupt.send("不能覆盖", book: nil, contextText: nil, settings: AISettings()) && !corrupt.startNewThread(), "损坏备份阻止新回复覆盖")
        expect(!corrupt.retryPendingReply() && corrupt.hasUnsavedReply && corrupt.error != nil, "故障未修复时重试保留错误和入口")
        expect(try Data(contentsOf: corruptURL) == Data("{broken".utf8), "损坏文件字节保持不变")
        try FileManager.default.removeItem(at: corruptURL)
        corrupt.retryPendingReply()
        expect(!corrupt.hasUnsavedReply && corrupt.startNewThread(), "移走损坏文件后重试能解除阻塞")

        var fixtureRoots: [URL] = []
        defer {
            for directory in fixtureRoots {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                try? FileManager.default.removeItem(at: directory)
            }
        }
        func fixture(_ name: String) throws -> (RuntimeHost, ChatService, URL) {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chat-" + name + "-" + UUID().uuidString)
            fixtureRoots.append(directory)
            let host = try runtime(directory), chat = ChatService()
            chat.attach(to: host)
            chat.send("提问", book: nil, contextText: nil, settings: AISettings())
            host.emit("chunk", text: "完整回答")
            return (host, chat, directory.appendingPathComponent("pending-chat-reply.json"))
        }

        let (ackHost, ack, ackURL) = try fixture("ack")
        ackHost.denyBackupCleanup = true
        ackHost.emit("done")
        expect(ack.hasUnsavedReply && FileManager.default.fileExists(atPath: ackURL.path), "DB ack 后清备份失败必须可重试")
        let ackID = ack.messages.last!.id
        let ackRestartHost = try runtime(ackHost.rootDirectory)
        let ackRestart = ChatService(); ackRestart.attach(to: ackRestartHost)
        expect(ackRestart.hasUnsavedReply && ackRestart.messages.last?.id == ackID, "重启已有 DB 回答且清理持续失败仍显示重试")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ackHost.rootDirectory.path)
        ackRestart.retryPendingReply()
        expect(!ackRestart.hasUnsavedReply && !FileManager.default.fileExists(atPath: ackURL.path), "修复目录权限后重试清理成功")
        expect(try ackRestartHost.assistantRows().count == 1, "ack 后重启重试不会重复插入")

        let (receiptHost, receipt, receiptURL) = try fixture("receipt")
        receiptHost.loseReplyReceipt = true
        receiptHost.emit("done")
        expect(receipt.hasUnsavedReply && FileManager.default.fileExists(atPath: receiptURL.path), "实际插入成功但回执失败保留备份")
        let receiptRestartHost = try runtime(receiptHost.rootDirectory)
        let receiptRestart = ChatService(); receiptRestart.attach(to: receiptRestartHost)
        expect(!receiptRestart.hasUnsavedReply && !FileManager.default.fileExists(atPath: receiptURL.path), "重启识别已保存回答并确认清理")
        expect(try receiptRestartHost.assistantRows().count == 1, "丢失回执的重启不会重复插入")

        let (diskHost, disk, diskURL) = try fixture("disk")
        try diskHost.rejectReplies(true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: diskHost.rootDirectory.path)
        diskHost.emit("done")
        expect(disk.hasUnsavedReply && disk.error?.contains("关闭应用会丢失") == true && !FileManager.default.fileExists(atPath: diskURL.path), "磁盘和 SQL 同时失败明确仅保留内存")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: diskHost.rootDirectory.path)
        try diskHost.rejectReplies(false)
        disk.retryPendingReply()
        let diskRows = try diskHost.assistantRows()
        expect(!disk.hasUnsavedReply && diskRows.count == 1, "恢复磁盘和 SQL 后可保存原回答")

        let (deleteHost, deleted, deleteURL) = try fixture("delete")
        try deleteHost.rejectReplies(true)
        deleteHost.emit("done")
        let deletedID = deleted.activeThreadId!
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: deleteHost.rootDirectory.path)
        deleted.delete(deleted.threads.first(where: { $0.id == deletedID })!, using: deleteHost)
        expect(deleted.activeThreadId == nil && FileManager.default.fileExists(atPath: deleteURL.path), "明确删除成功，清理失败留下残留备份")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deleteHost.rootDirectory.path)
        let deleteRestartHost = try runtime(deleteHost.rootDirectory)
        let deleteRestart = ChatService(); deleteRestart.attach(to: deleteRestartHost)
        expect(deleteRestart.messages.isEmpty && !deleteRestart.hasUnsavedReply && !FileManager.default.fileExists(atPath: deleteURL.path), "重启清理已删会话备份，不能复活消息")
        expect(try deleteRestartHost.assistantRows().isEmpty, "已删会话不能重新插入备份回答")

        let semanticRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chat-invalid-" + UUID().uuidString)
        fixtureRoots.append(semanticRoot)
        let semanticHost = try runtime(semanticRoot)
        let semanticURL = semanticRoot.appendingPathComponent("pending-chat-reply.json")
        let invalidBytes = Data(#"{"threadId":"","messageId":"","text":"回答"}"#.utf8)
        try invalidBytes.write(to: semanticURL)
        let semantic = ChatService(); semantic.attach(to: semanticHost)
        let semanticBytes = try? Data(contentsOf: semanticURL)
        expect(semantic.hasUnsavedReply && semantic.error != nil && semanticBytes == invalidBytes, "语义无效但合法 JSON 的备份也保留")

        let (successHost, success, successURL) = try fixture("restart-success")
        try successHost.rejectReplies(true)
        successHost.emit("done")
        let successThreadID = success.activeThreadId!, successReplyID = success.messages.last!.id
        _ = try successHost.appJSON("ShudengApp.createThread({id:'latest',title:'较新会话'})")
        _ = try successHost.appJSON("ReadAnyCore.db.getDB().then(db=>db.execute(\"UPDATE threads SET updated_at=9999999999999 WHERE id='latest'\"))")
        let successRestartHost = try runtime(successHost.rootDirectory)
        let successRestart = ChatService(); successRestart.attach(to: successRestartHost)
        expect(successRestart.activeThreadId == successThreadID && successRestart.messages.last?.id == successReplyID && !successRestart.hasUnsavedReply, "重启存储恢复时自动保存并打开备份所属原会话")
        let successRows = try successRestartHost.assistantRows()
        expect(successRows.count == 1 && successRows.first?["id"] as? String == successReplyID && !FileManager.default.fileExists(atPath: successURL.path), "重启恢复成功：数据库一行且备份清理")

        let (cleanDeleteHost, cleanDeleted, cleanDeleteURL) = try fixture("delete-success")
        try cleanDeleteHost.rejectReplies(true)
        cleanDeleteHost.emit("done")
        cleanDeleted.delete(cleanDeleted.threads.first!, using: cleanDeleteHost)
        expect(cleanDeleted.messages.isEmpty && !cleanDeleted.hasUnsavedReply && !FileManager.default.fileExists(atPath: cleanDeleteURL.path), "显式删除正常清理匹配的备份和当前消息")

        let (changedHost, changed, changedURL) = try fixture("changed-backup")
        try changedHost.rejectReplies(true)
        changedHost.emit("done")
        let changedThread = changed.threads.first!
        let changedBytes = Data("{replaced-broken".utf8)
        try changedBytes.write(to: changedURL)
        changed.retryPendingReply()
        expect(changed.hasUnsavedReply && (try? Data(contentsOf: changedURL)) == changedBytes, "内存回答重试不能覆盖后来损坏的备份")
        changed.delete(changedThread, using: changedHost)
        expect(changed.hasUnsavedReply && (try? Data(contentsOf: changedURL)) == changedBytes, "删除会话不能误删不匹配或损坏的备份文件")

        let (collisionHost, collision, collisionURL) = try fixture("collision")
        try collisionHost.rejectReplies(true)
        collisionHost.emit("done")
        try collisionHost.rejectReplies(false)
        let conflicting = String(decoding: try JSONSerialization.data(withJSONObject: ["id": collision.messages.last!.id, "threadId": collision.activeThreadId!, "role": "assistant", "content": "另一个回答"]), as: UTF8.self)
        _ = try collisionHost.appJSON("ShudengApp.appendMessage(\(conflicting))")
        let collisionBytes = try Data(contentsOf: collisionURL)
        let collisionRestartHost = try runtime(collisionHost.rootDirectory)
        let collisionRestart = ChatService(); collisionRestart.attach(to: collisionRestartHost)
        let retainedCollisionBytes = try Data(contentsOf: collisionURL)
        expect(collisionRestart.hasUnsavedReply && collisionRestart.error?.contains("冲突") == true && retainedCollisionBytes == collisionBytes, "相同 ID 不同内容的数据库回答不会覆盖备份")
        expect(try collisionRestartHost.assistantRows().first?["content"] as? String == "另一个回答", "备份冲突不改写已保存原数据")
        guard failures == 0 else { print("\(failures)/\(checks) failed"); exit(1) }
        print("Chat recovery regression passed (\(checks) checks)")
    }
}
