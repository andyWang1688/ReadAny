// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// 增量 UTF-8 解码：SSE 分片可能劈开多字节字符。
final class UTF8Splitter {
    private var pending = Data()

    func append(_ data: Data) -> String {
        pending.append(data)
        let bytes = [UInt8](pending)
        var cut = bytes.count
        var back = 0
        while back < 3, cut - back - 1 >= 0 {
            let byte = bytes[cut - back - 1]
            if byte & 0x80 == 0 { break }
            if byte & 0xC0 == 0xC0 {
                let needed = byte >= 0xF0 ? 4 : (byte >= 0xE0 ? 3 : 2)
                if back + 1 < needed { cut -= back + 1 }
                break
            }
            back += 1
        }
        let head = bytes[0..<cut]
        pending = Data(bytes[cut...])
        return String(decoding: head, as: UTF8.self)
    }

    func flush() -> String {
        let rest = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return rest
    }
}

/// 把一个 URLSession 请求的响应头 / 数据块 / 结束事件回调出去。
/// 回调发生在 URLSession 的队列上，调用方负责切回 JS 所在线程。
final class StreamBridge: NSObject, URLSessionDataDelegate {
    typealias HeadHandler = (Int, [String: String]) -> Void
    typealias ChunkHandler = (String) -> Void
    typealias FinishHandler = (Error?) -> Void

    private let onHead: HeadHandler
    private let onChunk: ChunkHandler
    private let onFinish: FinishHandler
    private let splitter = UTF8Splitter()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    init(onHead: @escaping HeadHandler, onChunk: @escaping ChunkHandler, onFinish: @escaping FinishHandler) {
        self.onHead = onHead
        self.onChunk = onChunk
        self.onFinish = onFinish
    }

    @discardableResult
    func start(_ request: URLRequest) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        task.resume()
        return task
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        var headers: [String: String] = [:]
        if let http = response as? HTTPURLResponse {
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
        }
        onHead((response as? HTTPURLResponse)?.statusCode ?? 0, headers)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let text = splitter.append(data)
        if !text.isEmpty { onChunk(text) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let rest = splitter.flush()
        if !rest.isEmpty { onChunk(rest) }
        // URLSession 会强引用 delegate：不失效的话每发一条 AI 消息就漏一个 session。
        session.finishTasksAndInvalidate()
        onFinish(error)
    }
}
