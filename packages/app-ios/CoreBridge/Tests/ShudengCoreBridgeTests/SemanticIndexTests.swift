// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ShudengCoreBridge

/// 语义索引：抽章节 → 端侧向量（Apple NLEmbedding）→ 落库 → 跨书检索 → 删索引。
final class SemanticIndexTests: XCTestCase {
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
        return try String(contentsOfFile: repoPath.path, encoding: .utf8)
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sample.epub")
    }

    private func makeRuntime() throws -> (runtime: ReadAnyRuntime, root: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shudeng-semantic-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runtime = try ReadAnyRuntime(
            coreScript: try coreScript(),
            appScript: try ReadAnyRuntime.bundledAppBootstrap(),
            host: HostEnvironment(rootDirectory: root, log: { _ in })
        )
        return (runtime, root)
    }

    private func call(
        _ runtime: ReadAnyRuntime,
        _ expression: String,
        timeout: TimeInterval = 120
    ) throws -> [String: Any] {
        let raw = try XCTUnwrap(
            try runtime.wait(for: try XCTUnwrap(runtime.evaluate(expression)), timeout: timeout).toString()
        )
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private func json(_ value: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func makeIndexRuntime(bookIDs: [String]) throws -> ReadAnyRuntime {
        let (runtime, root) = try makeRuntime()
        let books = root.appendingPathComponent("books")
        try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        for id in bookIDs {
            try FileManager.default.copyItem(at: fixtureURL(), to: books.appendingPathComponent("\(id).epub"))
        }
        _ = try call(runtime, """
        (async () => {
          await ShudengApp.bootstrap();
          for (const id of \(json(["ids": bookIDs])).ids) {
            await ReadAnyCore.db.insertBook({
              id, filePath: 'books/' + id + '.epub', format: 'epub',
              meta: { title: id, author: '' }, addedAt: Date.now(), updatedAt: Date.now(),
              progress: 0, isVectorized: false, vectorizeProgress: 0, tags: [], syncStatus: 'local',
            });
          }
          __nativeEmbed = raw => {
            const input = JSON.parse(raw);
            const texts = Array.isArray(input) ? input : input.texts;
            return JSON.stringify({ modelId: 'fixture', dimensions: 2, vectors: texts.map(() => [1, 0]) });
          };
          return JSON.stringify({ ok: true });
        })()
        """)
        return runtime
    }

    func testConcurrentIndexRequestsRejectSecondWithoutCancellingFirst() throws {
        let runtime = try makeIndexRuntime(bookIDs: ["A", "B"])
        let result = try call(runtime, """
        (async () => {
          const replies = (await Promise.all([
            ShudengApp.vectorizeBook({ bookId: 'A' }),
            ShudengApp.vectorizeBook({ bookId: 'B' }),
          ])).map(JSON.parse);
          return JSON.stringify({ replies, books: await ReadAnyCore.db.getBooks(),
            provenance: await ReadAnyCore.db.getVectorIndexProvenances() });
        })()
        """)
        let replies = try XCTUnwrap(result["replies"] as? [[String: Any]])
        XCTAssertEqual(replies.first?["ok"] as? Bool, true, "第二个请求不能取消已接受的第一个请求")
        XCTAssertNotNil(replies.last?["error"] as? String, "并发请求必须明确返回忙碌错误")
        let books = try XCTUnwrap(result["books"] as? [[String: Any]])
        XCTAssertEqual(books.first { $0["id"] as? String == "A" }?["isVectorized"] as? Bool, true)
        XCTAssertEqual(books.first { $0["id"] as? String == "B" }?["isVectorized"] as? Bool, false)
        let provenance = try XCTUnwrap(result["provenance"] as? [[String: Any]])
        XCTAssertEqual(provenance.compactMap { $0["bookId"] as? String }, ["A"])
    }

    func testDeleteBookCancelsInitializingAndWritingIndex() throws {
        for phase in ["initializing", "writing"] {
            let runtime = try makeIndexRuntime(bookIDs: ["A"])
            let result = try call(runtime, """
            (async () => {
              let deletion;
              const query = __nativeDbQuery;
              __nativeDbQuery = (path, sql, params) => {
                const result = query(path, sql, params);
                if ('\(phase)' === 'writing' && sql.includes('INTO chunks') && !deletion) {
                  deletion = ShudengApp.deleteBook({ id: 'A' });
                }
                return result;
              };
              const task = ShudengApp.vectorizeBook({ bookId: 'A' });
              if ('\(phase)' === 'initializing') deletion = ShudengApp.deleteBook({ id: 'A' });
              const reply = JSON.parse(await task);
              if (!deletion) throw new Error('index write checkpoint was not reached');
              const deleted = await deletion;
              __nativeDbQuery = query;
              return JSON.stringify({ reply, deleted, book: await ReadAnyCore.db.getBook('A'),
                chunks: (await ReadAnyCore.db.getChunks('A')).length,
                provenance: await ReadAnyCore.db.getVectorIndexProvenance('A'),
                status: JSON.parse(await ShudengApp.vectorizeStatus()),
                hits: (await ReadAnyCore.rag.search({ bookId: 'A', query: 'WKWebView', mode: 'bm25' })).length });
            })()
            """)
            XCTAssertEqual(result["deleted"] as? String, "ok", phase)
            XCTAssertEqual((result["reply"] as? [String: Any])?["cancelled"] as? Bool, true, phase)
            XCTAssertTrue(result["book"] is NSNull, phase)
            XCTAssertEqual(result["chunks"] as? Int, 0, phase)
            XCTAssertTrue(result["provenance"] is NSNull, phase)
            XCTAssertEqual(result["hits"] as? Int, 0, phase)
            XCTAssertEqual((result["status"] as? [String: Any])?["status"] as? String, "idle", phase)
        }
    }

    func testRebuildCannotStartDuringIndexDeletion() throws {
        let runtime = try makeIndexRuntime(bookIDs: ["A"])
        let result = try call(runtime, """
        (async () => {
          await ShudengApp.vectorizeBook({ bookId: 'A' });
          const removal = ShudengApp.deleteVectors({ bookId: 'A' });
          const rejected = JSON.parse(await ShudengApp.vectorizeBook({ bookId: 'A' }));
          await removal;
          const afterDelete = (await ReadAnyCore.db.getChunks('A')).length;
          const retry = JSON.parse(await ShudengApp.vectorizeBook({ bookId: 'A' }));
          return JSON.stringify({ rejected, afterDelete, retry,
            indexed: (await ReadAnyCore.db.getBook('A')).isVectorized });
        })()
        """)
        XCTAssertNotNil((result["rejected"] as? [String: Any])?["error"] as? String)
        XCTAssertEqual(result["afterDelete"] as? Int, 0)
        XCTAssertEqual((result["retry"] as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertEqual(result["indexed"] as? Bool, true)
    }

    func testVectorizedBooksUsesBatchedLocalFactsAndCompletedFlags() throws {
        let (runtime, _) = try makeRuntime()
        let result = try call(runtime, """
        (async () => {
          await ShudengApp.info();
          const now = Date.now();
          for (let i = 0; i < 12; i++) {
            await ReadAnyCore.db.insertBook({
              id: 'batch-' + i, filePath: i + '.epub', format: 'epub',
              meta: { title: 'Book ' + i, author: 'Author' }, addedAt: now, updatedAt: now,
              progress: 0, isVectorized: i < 3, vectorizeProgress: 0, tags: [], syncStatus: 'local',
            });
          }
          for (const id of ['batch-0', 'batch-3']) {
            await ReadAnyCore.db.setVectorIndexProvenance({
              bookId: id, kind: 'builtin', modelId: 'fixture', dimensions: 2, createdAt: now,
            });
            await ReadAnyCore.db.insertChunks([{
              id: id + '-chunk', bookId: id, chapterIndex: 0, chapterTitle: 'Chapter',
              content: 'fixture indexed passage', tokenCount: 4, startCfi: '', endCfi: '', embedding: [1, 0],
            }]);
          }
          const query = __nativeDbQuery;
          let provenanceQueries = 0;
          __nativeDbQuery = (path, sql, params) => {
            if (/^SELECT/i.test(sql) && sql.includes('vector_index_provenance')) provenanceQueries++;
            return query(path, sql, params);
          };
          const rows = JSON.parse(await ShudengApp.vectorizedBooks());
          return JSON.stringify({ rows, provenanceQueries });
        })()
        """)
        XCTAssertEqual(result["provenanceQueries"] as? Int, 2, "管理记录和有效本地索引各一次批量查询，不能逐本查询")
        let rows = try XCTUnwrap(result["rows"] as? [[String: Any]])
        XCTAssertEqual(Set(rows.compactMap { $0["bookId"] as? String }), Set(["batch-0", "batch-3"]))
        let indexed = try XCTUnwrap(rows.first { $0["bookId"] as? String == "batch-0" })
        XCTAssertEqual(indexed["modelId"] as? String, "fixture")
        XCTAssertEqual(indexed["dimensions"] as? Int, 2)
        XCTAssertEqual(indexed["isVectorized"] as? Bool, true)
        let incomplete = try XCTUnwrap(rows.first { $0["bookId"] as? String == "batch-3" })
        XCTAssertEqual(incomplete["modelId"] as? String, "fixture")
        XCTAssertEqual(incomplete["isVectorized"] as? Bool, false, "本地索引存在但主库未完成时保留管理记录，不能宣称可用")
    }

    func testDeleteIndexFailuresKeepLocalDataConsistentAndAllowRetry() throws {
        let (runtime, _) = try makeRuntime()
        let result = try call(runtime, """
        (async () => {
          await ShudengApp.info();
          const local = await ReadAnyCore.db.getLocalDB();
          const main = await ReadAnyCore.db.getDB();
          const scenarios = [];
          for (const point of ['chunks', 'provenance', 'book']) {
            const id = 'delete-failure-' + point;
            const now = Date.now();
            await ReadAnyCore.db.insertBook({
              id, filePath: id + '.epub', format: 'epub', meta: { title: id, author: 'Author' },
              addedAt: now, updatedAt: now, progress: 0, isVectorized: true,
              vectorizeProgress: 1, tags: [], syncStatus: 'local',
            });
            await ReadAnyCore.db.insertChunks([{
              id: id + '-chunk', bookId: id, chapterIndex: 0, chapterTitle: 'Chapter',
              content: 'fixture deletion cache evidence', tokenCount: 5, startCfi: '', endCfi: '', embedding: [1, 0],
            }]);
            await ReadAnyCore.db.setVectorIndexProvenance({
              bookId: id, kind: 'builtin', modelId: 'fixture', dimensions: 2, createdAt: now,
            });
            const search = () => ReadAnyCore.rag.search({ bookId: id, query: 'fixture', mode: 'bm25', topK: 5 });
            const before = (await search()).length;
            const target = point === 'book' ? main : local;
            const table = point === 'chunks' ? 'chunks' : point === 'provenance' ? 'vector_index_provenance' : 'books';
            const operation = point === 'book' ? 'UPDATE' : 'DELETE';
            await target.execute('CREATE TEMP TRIGGER reject_index_delete BEFORE ' + operation + ' ON ' + table +
              " BEGIN SELECT RAISE(ABORT, 'fixture delete failure'); END");
            let rejected = '';
            try { await ShudengApp.deleteVectors({ bookId: id }); }
            catch (error) { rejected = String(error.message || error); }
            await target.execute('DROP TRIGGER reject_index_delete');
            const chunks = (await ReadAnyCore.db.getChunks(id)).length;
            const provenance = !!(await ReadAnyCore.db.getVectorIndexProvenance(id));
            const indexed = (await ReadAnyCore.db.getBook(id)).isVectorized;
            const cachedHits = (await search()).length;
            const availableRows = JSON.parse(await ShudengApp.vectorizedBooks()).filter(row => row.bookId === id);
            const scanned = JSON.parse(await ShudengApp.semanticSearch({ query: 'fixture', bookIds: [id] })).scanned;
            const retried = JSON.parse(await ShudengApp.deleteVectors({ bookId: id }));
            const afterRetry = {
              chunks: (await ReadAnyCore.db.getChunks(id)).length,
              provenance: !!(await ReadAnyCore.db.getVectorIndexProvenance(id)),
              indexed: (await ReadAnyCore.db.getBook(id)).isVectorized,
              cachedHits: (await search()).length,
            };
            scenarios.push({ point, before, rejected, chunks, provenance, indexed, cachedHits, availableRows, scanned, retried, afterRetry });
          }
          return JSON.stringify({ scenarios });
        })()
        """)
        let scenarios = try XCTUnwrap(result["scenarios"] as? [[String: Any]])
        XCTAssertEqual(scenarios.count, 3)
        for scenario in scenarios {
            let point = try XCTUnwrap(scenario["point"] as? String)
            XCTAssertGreaterThan(scenario["before"] as? Int ?? 0, 0, point)
            XCTAssertTrue((scenario["rejected"] as? String ?? "").contains("fixture delete failure"), point)
            let localFailed = point != "book"
            XCTAssertEqual(scenario["chunks"] as? Int, localFailed ? 1 : 0, point)
            XCTAssertEqual(scenario["provenance"] as? Bool, localFailed, point)
            XCTAssertEqual(scenario["indexed"] as? Bool, true, point)
            XCTAssertEqual(scenario["cachedHits"] as? Int, localFailed ? 1 : 0, "缓存必须反映已提交的本地删除：\(point)")
            let availableRows = try XCTUnwrap(scenario["availableRows"] as? [[String: Any]])
            XCTAssertEqual(availableRows.count, localFailed ? 1 : 0, "主库标志滞留不能产生不存在的索引：\(point)")
            XCTAssertEqual(availableRows.first?["isVectorized"] as? Bool, localFailed ? true : nil, point)
            XCTAssertEqual(scenario["scanned"] as? Int, localFailed ? 1 : 0, "不扫描已提交删除的本地索引：\(point)")
            XCTAssertEqual((scenario["retried"] as? [String: Any])?["ok"] as? Bool, true, point)
            let afterRetry = try XCTUnwrap(scenario["afterRetry"] as? [String: Any])
            XCTAssertEqual(afterRetry["chunks"] as? Int, 0, point)
            XCTAssertEqual(afterRetry["provenance"] as? Bool, false, point)
            XCTAssertEqual(afterRetry["indexed"] as? Bool, false, point)
            XCTAssertEqual(afterRetry["cachedHits"] as? Int, 0, point)
        }
    }

    func testEpubChapterExtractionKeepsSegments() throws {
        let (runtime, _) = try makeRuntime()
        let raw = try XCTUnwrap(try runtime.evaluate("ReadAnyCore.epubText ? 'yes' : 'no'")?.toString())
        XCTAssertEqual(raw, "yes")

        // 直接把 fixture 的字节喂给抽取器（离线路径），顺带守住 container.xml 里
        // `<rootfiles>` 被当成 `<rootfile>` 的老坑。
        let bytes = try Data(contentsOf: fixtureURL())
        let base64 = bytes.base64EncodedString()
        let payload = try XCTUnwrap(
            try runtime.evaluate(
                """
                (() => {
                  const raw = atob('\(base64)');
                  const bytes = new Uint8Array(raw.length);
                  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
                  const chapters = ReadAnyCore.epubText.extractEpubChapters(bytes);
                  return JSON.stringify({
                    count: chapters.length,
                    titles: chapters.map((c) => c.title),
                    segments: chapters.map((c) => c.segments.length),
                    firstLine: chapters[0].content.split('\\n')[0],
                  });
                })()
                """
            )?.toString()
        )
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(json["count"] as? Int, 2)
        XCTAssertEqual((json["segments"] as? [Int])?.count, 2)
        XCTAssertTrue(((json["segments"] as? [Int]) ?? []).allSatisfy { $0 > 0 })
        XCTAssertTrue(((json["firstLine"] as? String) ?? "").contains("第一章"))
    }

    func testIndexCompletionRequiresPersistedBookState() throws {
        let (runtime, root) = try makeRuntime()
        let relative = "books/failure.epub"
        let destination = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL(), to: destination)
        _ = try call(runtime, "ShudengApp.importBook(\(json(["id": "failure", "path": relative, "fileName": "sample.epub", "format": "epub"])))")
        let result = try call(runtime, """
        (async () => {
          __nativeEmbed = raw => {
            const input = JSON.parse(raw);
            const texts = Array.isArray(input) ? input : input.texts;
            return JSON.stringify({ modelId: 'fixture', dimensions: 2, vectors: texts.map(() => [1, 0]) });
          };
          const query = __nativeDbQuery;
          let failures = 0;
          __nativeDbQuery = (path, sql, params) => {
            if (sql.startsWith('UPDATE books SET is_vectorized = ?') && JSON.parse(params)[0] === 1 && failures++ === 0) {
              return JSON.stringify({ error: 'SQLITE_BUSY completion' });
            }
            return query(path, sql, params);
          };
          const failed = JSON.parse(await ShudengApp.vectorizeBook({ bookId: 'failure' }));
          const status = JSON.parse(await ShudengApp.vectorizeStatus());
          const book = await ReadAnyCore.db.getBook('failure');
          const incomplete = JSON.parse(await ShudengApp.vectorizedBooks());
          const scanned = JSON.parse(await ShudengApp.semanticSearch({ query: 'WKWebView', bookIds: ['failure'] })).scanned;
          __nativeDbQuery = query;
          const retried = JSON.parse(await ShudengApp.vectorizeBook({ bookId: 'failure' }));
          const saved = await ReadAnyCore.db.getBook('failure');
          const completed = JSON.parse(await ShudengApp.vectorizedBooks());
          return JSON.stringify({ failed, status, book, incomplete, scanned, retried, saved, completed });
        })()
        """)
        let failed = try XCTUnwrap(result["failed"] as? [String: Any])
        XCTAssertNil(failed["ok"])
        XCTAssertEqual(failed["error"] as? String, "SQLITE_BUSY completion")
        XCTAssertEqual((result["status"] as? [String: Any])?["status"] as? String, "error")
        XCTAssertEqual((result["book"] as? [String: Any])?["isVectorized"] as? Bool, false)
        let incomplete = try XCTUnwrap(result["incomplete"] as? [[String: Any]])
        XCTAssertEqual(incomplete.count, 1, "本地索引保留在管理列表中以便删除或重试")
        XCTAssertEqual(incomplete.first?["isVectorized"] as? Bool, false)
        XCTAssertEqual(result["scanned"] as? Int, 0, "主库完成写失败时不能扫描未完成索引")
        XCTAssertEqual((result["retried"] as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertEqual((result["saved"] as? [String: Any])?["isVectorized"] as? Bool, true)
        XCTAssertEqual((result["completed"] as? [[String: Any]])?.first?["isVectorized"] as? Bool, true)
    }

    func testRecordSessionSkipsDeletedBookSoPendingQueueCannotBlock() throws {
        let (runtime, _) = try makeRuntime()
        let result = try call(runtime, """
        (async () => {
          await ShudengApp.info();
          return JSON.stringify({ value: await ShudengApp.recordSession({ id: 'deleted', bookId: 'gone', startedAt: 1000, totalActiveTime: 2000, pagesRead: 2 }) });
        })()
        """)
        XCTAssertEqual(result["value"] as? String, "skipped")
    }

    func testSaveProgressSkipsDeletedBook() throws {
        let (runtime, _) = try makeRuntime()
        let result = try call(runtime, """
        (async () => {
          await ShudengApp.info();
          return JSON.stringify({ value: await ShudengApp.saveProgress({ bookId: 'gone', progress: 0.5, cfi: 'cfi' }) });
        })()
        """)
        XCTAssertEqual(result["value"] as? String, "skipped")
    }

    func testReadingSessionRetryIsIdempotentAndRejectsInvalidData() throws {
        let (runtime, _) = try makeRuntime()
        let result = try call(runtime, """
        (async () => {
          await ShudengApp.info();
          await ReadAnyCore.db.insertBook({
            id: 'book', filePath: 'book.epub', format: 'epub', meta: { title: 'Book', author: 'Author' },
            addedAt: 1000, updatedAt: 1000, progress: 0, tags: [], syncStatus: 'local',
          });
          const payload = { id: 'retry', bookId: 'book', startedAt: 1000, totalActiveTime: 2000, pagesRead: 2 };
          await ShudengApp.recordSession(payload);
          await ShudengApp.recordSession(payload);
          const rows = await ReadAnyCore.db.getReadingSessions('book');
          let rejected = false;
          try {
            await ReadAnyCore.db.insertReadingSession({ id: 'invalid', bookId: null, startedAt: 1000, totalActiveTime: 2000, pagesRead: 2, state: 'STOPPED' });
          } catch (_) { rejected = true; }
          return JSON.stringify({ rows, rejected });
        })()
        """)
        let rows = try XCTUnwrap(result["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["totalActiveTime"] as? Int, 2000)
        XCTAssertEqual(result["rejected"] as? Bool, true, "只能忽略同一会话重试，不能吞掉非空约束错误")
    }

    func testVectorizeBookThenSearchAndDelete() throws {
        let (runtime, root) = try makeRuntime()

        let relative = "books/book-1.epub"
        let destination = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: fixtureURL(), to: destination)

        let imported = try call(
            runtime,
            "ShudengApp.importBook(\(json(["id": "book-1", "path": relative, "fileName": "sample.epub", "format": "epub"])))"
        )
        XCTAssertEqual(imported["duplicate"] as? Bool, false)

        let info = try call(runtime, "ShudengApp.embeddingInfo()")
        guard info["available"] as? Bool == true else {
            throw XCTSkip("这台机器上没有可用的端侧向量模型：\(info["error"] ?? "unknown")")
        }
        let modelId = try XCTUnwrap(info["modelId"] as? String)
        XCTAssertTrue(modelId.hasPrefix("apple-nl-"), "端侧向量模型出处不对：\(modelId)")
        XCTAssertGreaterThan(info["dimensions"] as? Int ?? 0, 0)

        let started = try call(runtime, "ShudengApp.vectorizeBook(\(json(["bookId": "book-1"])))")
        XCTAssertNil(started["error"], "建索引失败：\(started["error"] ?? "")")
        XCTAssertEqual(started["ok"] as? Bool, true)

        let status = try call(runtime, "ShudengApp.vectorizeStatus()")
        XCTAssertEqual(status["status"] as? String, "done")
        XCTAssertGreaterThan(status["chunks"] as? Int ?? 0, 0)

        let indexed = try runtime.wait(
            for: try XCTUnwrap(runtime.evaluate("ShudengApp.vectorizedBooks()")),
            timeout: 60
        ).toString()
        let rows = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(indexed).utf8)) as? [[String: Any]]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["bookId"] as? String, "book-1")
        XCTAssertEqual(rows.first?["isVectorized"] as? Bool, true)

        // 中文提问命中第一章（WKWebView 分页那段）。
        let hit = try call(runtime, "ShudengApp.semanticSearch(\(json(["query": "WKWebView 怎么分页显示中文", "topK": 5])))")
        let results = try XCTUnwrap(hit["results"] as? [[String: Any]])
        XCTAssertFalse(results.isEmpty, "语义检索没有命中任何段落")
        XCTAssertEqual(results.first?["bookId"] as? String, "book-1")
        XCTAssertFalse(((results.first?["content"] as? String) ?? "").isEmpty)
        XCTAssertEqual(hit["scanned"] as? Int, 1)

        // 只有书里有的词：证明是真检索，不是「有啥吐啥」。
        let bridge = try call(runtime, "ShudengApp.semanticSearch(\(json(["query": "宿主的网络和数据库由谁提供", "topK": 5])))")
        let bridgeResults = try XCTUnwrap(bridge["results"] as? [[String: Any]])
        XCTAssertEqual(bridgeResults.first?["chapterIndex"] as? Int, 1)

        _ = try call(runtime, "ShudengApp.deleteVectors(\(json(["bookId": "book-1"])))")
        let afterDelete = try runtime.wait(
            for: try XCTUnwrap(runtime.evaluate("ShudengApp.vectorizedBooks()")),
            timeout: 60
        ).toString()
        let remaining = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(afterDelete).utf8)) as? [Any]
        )
        XCTAssertTrue(remaining.isEmpty)
    }

    /// 书建过索引之后，问书里的事要能自动带上原文（事件 context），而不是只把书名丢给模型。
    func testChatInjectsRetrievedPassages() throws {
        guard let baseURL = ProcessInfo.processInfo.environment["SHUDENG_MOCK_LLM_URL"], !baseURL.isEmpty else {
            throw XCTSkip("未设置 SHUDENG_MOCK_LLM_URL，先启动 scripts/mock-llm-server.mjs")
        }
        let (runtime, root) = try makeRuntime()

        let relative = "books/book-1.epub"
        let destination = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: fixtureURL(), to: destination)
        _ = try call(
            runtime,
            "ShudengApp.importBook(\(json(["id": "book-1", "path": relative, "fileName": "sample.epub", "format": "epub"])))"
        )
        let info = try call(runtime, "ShudengApp.embeddingInfo()")
        guard info["available"] as? Bool == true else {
            throw XCTSkip("这台机器上没有可用的端侧向量模型")
        }
        let started = try call(runtime, "ShudengApp.vectorizeBook(\(json(["bookId": "book-1"])))")
        XCTAssertEqual(started["ok"] as? Bool, true)

        let events = EventLog()
        runtime.host.onChatEvent = { requestID, eventJSON in events.append(requestID, eventJSON) }

        let payload = json([
            "requestId": "r-rag",
            "provider": "openai",
            "apiKey": "mock-key",
            "model": "mock-model",
            "baseUrl": baseURL,
            "text": "书里怎么讲 WKWebView 分页？",
            "language": "zh",
            "book": ["id": "book-1", "meta": ["title": "样章", "author": ""]],
        ])
        let promise = try XCTUnwrap(runtime.evaluate("ShudengApp.chat(\(payload))"))
        XCTAssertEqual(try runtime.wait(for: promise, timeout: 60).toString(), "ok")

        let contextEvent = events.last(ofType: "context")
        let count = (contextEvent?["count"] as? Int) ?? 0
        XCTAssertGreaterThan(count, 0, "对话没有注入检索到的原文：\(events.types())")
    }
}

/// 事件回调发生在 JS 线程上，测试里只做追加。
private final class EventLog: @unchecked Sendable {
    private var entries: [(requestID: String, json: String)] = []

    func append(_ requestID: String, _ json: String) {
        entries.append((requestID, json))
    }

    func types() -> [String] {
        entries.compactMap { object(of: $0.json)?["type"] as? String }
    }

    func last(ofType type: String) -> [String: Any]? {
        for entry in entries.reversed() {
            guard let object = object(of: entry.json), object["type"] as? String == type else { continue }
            return object
        }
        return nil
    }

    private func object(of json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
