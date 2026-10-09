// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine

struct LibraryStore { struct Book { let id: String } }
@MainActor final class RuntimeHost {
    enum State { case ready, starting }
    var state = State.ready
    var failRecords = false
    var failProgress = false
    let rootDirectory: URL
    var afterRecord: (() -> Void)?
    var afterProgress: (() -> Void)?
    var recordAttempts: [String] = []
    var records: [[String: Any]] = []
    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("reading-test-\(UUID().uuidString)")
    }
    var queueFile: URL { rootDirectory.appendingPathComponent("ReadingSession/pending-flushes.json") }
    var progresses: [[String: Any]] = []
    func appJSON(_ expression: String, timeout: TimeInterval = 30) throws -> String? {
        let start = expression.index(after: expression.firstIndex(of: "(")!)
        let raw = expression[start..<expression.index(before: expression.endIndex)]
        let payload = try! JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
        if expression.contains("recordSession") {
            let id = payload["id"] as! String
            recordAttempts.append(id)
            if failRecords { throw NSError(domain: "SQLITE_BUSY", code: 5) }
            if !records.contains(where: { $0["id"] as? String == id }) { records.append(payload) }
            afterRecord?()
        } else {
            if failProgress { throw NSError(domain: "SQLITE_BUSY", code: 5) }
            progresses.append(payload)
            afterProgress?()
        }
        return "ok"
    }
}

@main struct ReadingSessionStateTests {
    @MainActor static func main() throws {
        var failures = 0
        func expect(_ result: Bool, _ message: String) {
            if !result { failures += 1; print("FAIL: " + message) }
        }
        func start(_ reader: ReadingSession, _ id: String) {
            reader.book = LibraryStore.Book(id: id)
            reader.beginSession()
            reader.updateProgress(fraction: 0.5, cfi: "cfi-" + id, chapter: id, page: 1)
        }

        // A and B both fail, then the user opens C: neither snapshot may be lost.
        let runtime = RuntimeHost(), reader = ReadingSession()
        reader.attach(to: runtime)
        runtime.failRecords = true
        start(reader, "A")
        reader.flush(using: runtime)
        start(reader, "B")
        reader.book = LibraryStore.Book(id: "C")
        runtime.failRecords = false
        reader.flush(using: runtime)
        expect(runtime.records.compactMap { $0["bookId"] as? String } == ["A", "B"], "failed A must not discard B on book change")
        expect(runtime.progresses.compactMap { $0["cfi"] as? String } == ["cfi-A", "cfi-B"], "progress must retain original book context")
        reader.flush(using: runtime)
        expect(runtime.records.count == 2, "repeated flush must not duplicate records")

        // Runtime is unavailable during multiple book changes.
        let offline = RuntimeHost(), offlineReader = ReadingSession()
        offlineReader.attach(to: offline)
        offline.state = .starting
        start(offlineReader, "A")
        start(offlineReader, "B")
        offlineReader.book = LibraryStore.Book(id: "C")
        offline.state = .ready
        offlineReader.flush(using: offline)
        expect(offline.records.compactMap { $0["bookId"] as? String } == ["A", "B"], "offline snapshots must not overwrite each other")

        // Successful record + failed progress must only retry the latter.
        let partial = RuntimeHost(), partialReader = ReadingSession()
        partialReader.attach(to: partial)
        start(partialReader, "A")
        partial.failProgress = true
        partialReader.flush(using: partial)
        partial.failProgress = false
        partialReader.flush(using: partial)
        expect(partial.records.count == 1 && partial.progresses.count == 1, "partial success must not duplicate reading time")

        // End timing while offline; retries must not include background time.
        let background = RuntimeHost(), backgroundReader = ReadingSession()
        backgroundReader.attach(to: background)
        start(backgroundReader, "A")
        background.state = .starting
        backgroundReader.flush(using: background)
        expect(backgroundReader.sessionStartedAt == nil, "background flush must stop timing even when runtime is unavailable")
        background.state = .ready
        backgroundReader.flush(using: background)
        expect(background.records.count == 1, "retry after runtime recovery must save snapshot")
        // Recreate the entire instance with an unavailable database, then retry the disk queue.
        let restartHost = RuntimeHost()
        restartHost.failRecords = true
        var original: ReadingSession? = ReadingSession()
        original!.attach(to: restartHost)
        start(original!, "restart")
        Thread.sleep(forTimeInterval: 1.01)
        original!.flush(using: restartHost)
        let originalID = restartHost.recordAttempts[0]
        expect(original!.persistenceError != nil, "failed database write must be visible")
        let snapshot = try Data(contentsOf: restartHost.queueFile)
        expect(!String(decoding: snapshot, as: UTF8.self).contains("ShudengApp"), "disk queue must contain data, not executable expressions")
        original = nil
        restartHost.failRecords = false
        let recovered = ReadingSession()
        recovered.attach(to: restartHost)
        expect(restartHost.records.count == 1 && restartHost.progresses.count == 1 && restartHost.records[0]["id"] as? String == originalID, "instance recreation must recover the same session UUID and progress")
        expect(recovered.persistenceError == nil, "successful recovery clears error")
        start(recovered, "active")
        recovered.retryPersistence(using: restartHost)
        expect(recovered.sessionStartedAt != nil, "retry button must not stop current reading timer")

        // Record acknowledgement survives recreation when only progress failed.
        let partialRestart = RuntimeHost()
        partialRestart.failProgress = true
        var partialOriginal: ReadingSession? = ReadingSession()
        partialOriginal!.attach(to: partialRestart)
        start(partialOriginal!, "partial")
        partialOriginal!.flush(using: partialRestart)
        partialOriginal = nil
        partialRestart.failProgress = false
        let partialRecovered = ReadingSession()
        partialRecovered.attach(to: partialRestart)
        expect(partialRestart.recordAttempts.count == 1 && partialRestart.records.count == 1 && partialRestart.progresses.count == 1, "durable record acknowledgement avoids replaying reading time")

        // A filesystem obstacle makes queue writes fail without relying on process permissions.
        let blocked = RuntimeHost(), blockedReader = ReadingSession()
        blockedReader.attach(to: blocked)
        try FileManager.default.createDirectory(at: blocked.rootDirectory, withIntermediateDirectories: true)
        let blockedParent = blocked.queueFile.deletingLastPathComponent()
        try Data("obstacle".utf8).write(to: blockedParent)
        start(blockedReader, "blocked")
        blockedReader.flush(using: blocked)
        expect(blocked.recordAttempts.isEmpty && blockedReader.persistenceError != nil, "queue must be durable before any database write")
        try FileManager.default.removeItem(at: blockedParent)
        blockedReader.flush(using: blocked)
        expect(blocked.records.count == 1 && blockedReader.persistenceError == nil, "file write recovery replays retained memory snapshot")

        // Corrupt/unreadable queue files are never replaced with an empty queue.
        let corrupt = RuntimeHost(), corruptReader = ReadingSession()
        try FileManager.default.createDirectory(at: corrupt.queueFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let badData = Data("broken-json".utf8)
        try badData.write(to: corrupt.queueFile)
        corruptReader.attach(to: corrupt)
        start(corruptReader, "waiting")
        corruptReader.flush(using: corrupt)
        expect(try Data(contentsOf: corrupt.queueFile) == badData && corrupt.records.isEmpty && corruptReader.persistenceError != nil, "corrupt file must remain untouched with a visible error")
        try FileManager.default.removeItem(at: corrupt.queueFile)
        try FileManager.default.createDirectory(at: corrupt.queueFile, withIntermediateDirectories: false)
        corruptReader.flush(using: corrupt)
        expect(corrupt.records.isEmpty && corruptReader.persistenceError != nil, "unreadable queue blocks writes")
        try FileManager.default.removeItem(at: corrupt.queueFile)
        try Data("[]".utf8).write(to: corrupt.queueFile)
        corruptReader.flush(using: corrupt)
        expect(corrupt.records.count == 1 && corruptReader.persistenceError == nil, "repair then retry preserves snapshots captured while reading failed")

        // Fail an atomic ack/dequeue write after DB success. The original disk file is retained
        // beside a deliberate directory obstacle, then restored to simulate storage recovery.
        for failAcknowledgement in [true, false] {
            let host = RuntimeHost()
            host.state = .starting
            var queue: ReadingSession? = ReadingSession()
            queue!.attach(to: host)
            start(queue!, "A")
            Thread.sleep(forTimeInterval: 1.01)
            queue!.flush(using: host)
            start(queue!, "B")
            Thread.sleep(forTimeInterval: 1.01)
            queue!.flush(using: host)
            host.state = .ready
            let backup = host.rootDirectory.appendingPathComponent("queue-backup.json")
            let blockWrite = {
                try! FileManager.default.moveItem(at: host.queueFile, to: backup)
                try! FileManager.default.createDirectory(at: host.queueFile, withIntermediateDirectories: false)
            }
            if failAcknowledgement { host.afterRecord = blockWrite } else { host.afterProgress = blockWrite }
            queue!.flush(using: host)
            expect(host.records.count == 1 && queue!.persistenceError != nil, "ack/dequeue disk failure stops before next queued session")
            expect(host.progresses.count == (failAcknowledgement ? 0 : 1), "ack failure stops progress; dequeue failure stops next session")
            let firstID = host.recordAttempts[0]
            let firstDuration = host.records[0]["totalActiveTime"] as! Int
            queue = nil
            host.afterRecord = nil; host.afterProgress = nil
            try FileManager.default.removeItem(at: host.queueFile)
            try FileManager.default.moveItem(at: backup, to: host.queueFile)
            let retry = ReadingSession()
            retry.attach(to: host)
            expect(host.records.compactMap { $0["bookId"] as? String } == ["A", "B"], "recovery must replay FIFO without duplicate reading time")
            expect(host.records.first?["id"] as? String == firstID && Set(host.recordAttempts).count == 2, "ack replay must reuse stable session IDs")
            expect(host.records.filter { $0["id"] as? String == firstID }.reduce(0) { $0 + ($1["totalActiveTime"] as! Int) } == firstDuration && firstDuration >= 1000, "replayed session must not increase recorded duration")
            expect(retry.persistenceError == nil && (try? Data(contentsOf: host.queueFile)) == Data("[]".utf8), "complete recovery empties durable queue")
            try FileManager.default.removeItem(at: host.rootDirectory)
        }
        for host in [runtime, offline, partial, background, restartHost, partialRestart, blocked, corrupt] {
            try? FileManager.default.removeItem(at: host.rootDirectory)
        }
        let contextRuntime = RuntimeHost()
        defer { try? FileManager.default.removeItem(at: contextRuntime.rootDirectory) }
        let contextReader = ReadingSession()
        contextReader.attach(to: contextRuntime)
        contextReader.book = LibraryStore.Book(id: "A")
        contextReader.setRecentHighlights(["A-only passage"])
        contextReader.book = LibraryStore.Book(id: "B")
        expect(!contextReader.promptContext.contains("A-only passage"), "changing books must clear the previous book's AI highlights")

        let repeated = RuntimeHost(), repeatedReader = ReadingSession()
        defer { try? FileManager.default.removeItem(at: repeated.rootDirectory) }
        repeatedReader.attach(to: repeated)
        start(repeatedReader, "A")
        repeatedReader.setVisibleText("same page text")
        repeatedReader.flush(using: repeated)
        repeatedReader.book = nil
        repeatedReader.book = LibraryStore.Book(id: "A")
        repeatedReader.beginSession()
        repeatedReader.updateProgress(fraction: 0.5, cfi: "cfi-A", chapter: "A", page: 1)
        repeatedReader.setVisibleText("same page text")
        repeatedReader.flush(using: repeated)
        expect(repeated.records.map { $0["charactersRead"] as? Int } == [14, 14], "same text on a reopened session must count again")
        guard failures == 0 else { exit(1) }
        print("ReadingSession persistence regressions passed (13 scenarios)")
    }
}
