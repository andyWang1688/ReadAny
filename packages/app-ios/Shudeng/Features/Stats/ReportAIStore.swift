// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// 只保留周/月/全部各自最近一次解读；请求不随报告页面关闭而丢失。
@MainActor
final class ReportAIStore: ObservableObject {
    struct Period: Codable, Hashable {
        let dimension: String
        let key: String
        let startDate: String
        let endDate: String

        init(_ payload: ReportPayload) {
            dimension = payload.dimension
            key = payload.period.key
            startDate = payload.period.startDate
            endDate = payload.period.endDate
        }
    }

    struct Interpretation: Codable {
        let period: Period
        let source: String
        let text: String
    }

    @Published private(set) var results: [String: Interpretation] = [:]
    @Published private(set) var generatingPeriod: Period?
    @Published private(set) var persistenceError: String?
    @Published private var failures: [Period: String] = [:]
    private var storageURL: URL?
    private var loadFailed = false

    var isGenerating: Bool { generatingPeriod != nil }

    func isGenerating(for payload: ReportPayload) -> Bool {
        generatingPeriod == Period(payload)
    }

    func text(for payload: ReportPayload) -> String? {
        guard let result = results[payload.dimension], result.period == Period(payload) else { return nil }
        return result.text
    }

    func isOutdated(for payload: ReportPayload, source: String) -> Bool {
        text(for: payload) != nil && results[payload.dimension]?.source != source
    }

    func error(for payload: ReportPayload) -> String? {
        failures[Period(payload)]
    }

    func load(from directory: URL) {
        guard storageURL == nil else { return }
        storageURL = directory.appendingPathComponent("reading-report-ai.json")
        do {
            results = try readSavedResults()
        } catch {
            loadFailed = true
            persistenceError = "已有解读文件无法读取，原文件已保留，请重试保存。"
        }
    }

    private func readSavedResults() throws -> [String: Interpretation] {
        guard let url = storageURL, FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: Interpretation].self, from: Data(contentsOf: url))
    }

    func retrySave() {
        guard let url = storageURL else { return }
        if loadFailed {
            do {
                let saved = try readSavedResults()
                results = saved.merging(results) { _, current in current }
                loadFailed = false
            } catch {
                persistenceError = "已有解读文件无法读取，原文件已保留，请重试保存。"
                return
            }
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(results).write(to: url, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "解读暂存在当前应用，尚未保存到本地；关闭应用可能丢失，请重试保存。"
        }
    }

    func generate(_ payload: ReportPayload, prompt: String, using runtime: RuntimeHost, settings: AISettings) {
        load(from: runtime.rootDirectory)
        guard !isGenerating else { return }
        let period = Period(payload)
        guard settings.isConfigured else {
            failures[period] = "先在「我的 → AI 设置」里填端点和模型"
            return
        }
        generatingPeriod = period
        failures[period] = nil
        let body = [
            "system": "你是一位简洁、真诚的中文阅读教练。只输出解读正文，不要寒暄，不要复述我给的全部数字。",
            "text": prompt,
            "provider": settings.provider.rawValue,
            "apiKey": settings.apiKey,
            "baseUrl": settings.baseURL,
            "model": settings.model,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            generatingPeriod = nil
            failures[period] = "无法准备解读内容，请重试。"
            return
        }
        let json = String(decoding: data, as: UTF8.self)
        runtime.callAsync("ShudengApp.aiReport(\(json))", timeout: 120) { [self] response in
            generatingPeriod = nil
            guard let data = response.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                failures[period] = "没有收到有效解读，请重试。"
                return
            }
            if let error = object["error"] as? String, !error.isEmpty {
                failures[period] = AIServiceError.message(error)
                return
            }
            let text = (object["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                failures[period] = "没有收到有效解读，请重试。"
                return
            }
            results[payload.dimension] = Interpretation(period: period, source: prompt, text: text)
            retrySave()
        }
    }
}
