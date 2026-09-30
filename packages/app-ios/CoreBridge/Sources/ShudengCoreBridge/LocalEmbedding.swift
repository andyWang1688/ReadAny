// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NaturalLanguage

/// 语义检索用的端侧向量模型：Apple NaturalLanguage 自带的那几个，不联网、不占 App 体积。
///
/// 按「语义质量」从高到低挑第一个真能出向量的：
/// 1. 句向量 `NLEmbedding.sentenceEmbedding`（中英都有，中文 640 维）
/// 2. 词向量 `NLEmbedding.wordEmbedding`（按空白分词后取均值，中文只认部分词）
/// 3. 上下文向量 `NLContextualEmbedding`（子词向量均值池化，512 维，资源可能要系统现下载）
///
/// 建索引用哪一档，查询就必须用同一档：`embed(_:usingModelId:)` 只认指定模型，
/// 认不出来就报错（宁可提示重建索引，也不拿另一个语义空间的结果糊弄）。
public enum LocalEmbedding {
    public struct Output {
        public let modelId: String
        public let dimensions: Int
        public let vectors: [[Double]]
        /// 这批文本里有多少条没出向量（调用方按空向量跳过即可）。
        public let missed: Int
    }

    private struct Model {
        let id: String
        let dimensions: Int
        /// 探测这个模型到底能不能出向量的最短文本（词向量只认真词）。
        let probe: String
        let vector: (String) -> [Double]?
    }

    /// `NLContextualEmbedding` 的加载状态：load() 会读系统资源，只做一次。
    private final class ContextualBox: @unchecked Sendable {
        private let lock = NSLock()
        private var loaded = false

        func load(_ embedding: NLContextualEmbedding) {
            lock.lock()
            defer { lock.unlock() }
            guard !loaded, embedding.hasAvailableAssets else { return }
            guard (try? embedding.load()) != nil else { return }
            loaded = true
        }

        var isLoaded: Bool {
            lock.lock()
            defer { lock.unlock() }
            return loaded
        }
    }

    private static let lock = NSLock()
    /// 语言 → 上次真的出过向量的模型（同语种下次先用它，省一遍探测）。
    private static var lastWorking: [String: Model] = [:]
    /// modelId → 模型（按向量索引里记的出处复现同一个模型）。
    private static var byId: [String: Model] = [:]
    private static var preparing = false

    // MARK: - 候选模型

    private static func sentenceModel(_ language: NLLanguage) -> Model? {
        guard let sentence = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        return Model(
            id: "apple-nl-sentence-\(language.rawValue)",
            dimensions: sentence.dimension,
            probe: probeText(language),
            vector: { sentence.vector(for: $0) }
        )
    }

    private static func wordModel(_ language: NLLanguage) -> Model? {
        guard let word = NLEmbedding.wordEmbedding(for: language) else { return nil }
        return Model(
            id: "apple-nl-word-\(language.rawValue)",
            dimensions: word.dimension,
            probe: language == .english ? "book" : "书",
            vector: { text in
                let tokens = text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
                var sum = [Double](repeating: 0, count: word.dimension)
                var count = 0.0
                for token in tokens {
                    guard let vector = word.vector(for: String(token)) else { continue }
                    for index in 0..<min(sum.count, vector.count) { sum[index] += vector[index] }
                    count += 1
                }
                guard count > 0 else { return nil }
                return sum.map { $0 / count }
            }
        )
    }

    private static func contextualModel(_ language: NLLanguage) -> Model? {
        guard #available(iOS 17.0, macOS 14.0, *) else { return nil }
        guard let embedding = NLContextualEmbedding(language: language) else { return nil }
        let dimensions = embedding.dimension
        guard dimensions > 0 else { return nil }
        let box = ContextualBox()
        return Model(
            id: "apple-nl-contextual-\(language.rawValue)",
            dimensions: dimensions,
            probe: probeText(language),
            vector: { text in
                box.load(embedding)
                guard box.isLoaded else { return nil }
                guard let result = try? embedding.embeddingResult(for: text, language: language) else { return nil }
                var sum = [Double](repeating: 0, count: dimensions)
                var count = 0
                result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                    for (index, value) in vector.enumerated() where index < sum.count { sum[index] += value }
                    count += 1
                    return true
                }
                guard count > 0 else { return nil }
                return sum.map { $0 / Double(count) }
            }
        )
    }

    /// 候选顺序：先用当前语种，再退中英两个语种兜底。
    private static func candidates(for language: NLLanguage) -> [Model] {
        var languages: [NLLanguage] = [language]
        for fallback in [NLLanguage.simplifiedChinese, .english] where !languages.contains(fallback) {
            languages.append(fallback)
        }
        return languages.flatMap { [sentenceModel($0), wordModel($0), contextualModel($0)].compactMap { $0 } }
    }

    /// 按向量索引记的出处找模型：`apple-nl-sentence-zh-Hans` / `apple-nl-word-en` / `apple-nl-contextual-zh-Hans`。
    private static func model(withId id: String) -> Model? {
        let prefix = "apple-nl-"
        guard id.hasPrefix(prefix) else { return nil }
        lock.lock()
        let cached = byId[id]
        lock.unlock()
        if let cached { return cached }

        let rest = id.dropFirst(prefix.count)
        var resolved: Model?
        if let separator = rest.firstIndex(of: "-") {
            let kind = String(rest[rest.startIndex..<separator])
            let language = NLLanguage(rawValue: String(rest[rest.index(after: separator)...]))
            switch kind {
            case "sentence": resolved = sentenceModel(language)
            case "word": resolved = wordModel(language)
            case "contextual": resolved = contextualModel(language)
            default: resolved = nil
            }
        }
        if let resolved {
            lock.lock()
            byId[id] = resolved
            lock.unlock()
        }
        return resolved
    }

    // MARK: - 出向量

    /// 文本走哪个语言：中文/日文/韩文一眼看出来，其余交给系统识别。
    static func language(for texts: [String]) -> NLLanguage {
        let sample = texts.joined(separator: " ").prefix(4000)
        if sample.range(of: "\\p{Han}", options: .regularExpression) != nil { return .simplifiedChinese }
        if sample.range(of: "[\\p{Hiragana}\\p{Katakana}]", options: .regularExpression) != nil {
            return .japanese
        }
        if sample.range(of: "\\p{Hangul}", options: .regularExpression) != nil { return .korean }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample))
        return recognizer.dominantLanguage ?? .english
    }

    private static func normalized(_ vector: [Double]) -> [Double] {
        var norm = 0.0
        for value in vector { norm += value * value }
        norm = norm.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// `allowEmpty`：锁定模型（建索引 / 查询）时，一批里一条向量都出不来也照样返回，
    /// 让调用方看到「这批没向量」而不是整本书建索引失败。
    private static func embed(_ texts: [String], with model: Model, allowEmpty: Bool = false) -> Output? {
        guard model.dimensions > 0 else { return nil }
        var vectors: [[Double]] = []
        var missed = 0
        vectors.reserveCapacity(texts.count)
        for text in texts {
            if let vector = model.vector(text), !vector.isEmpty {
                vectors.append(normalized(vector))
            } else {
                vectors.append([])
                missed += 1
            }
        }
        // 一条都没出向量，说明这个模型压根用不了：换下一个候选。
        guard allowEmpty || missed < texts.count else { return nil }
        return Output(modelId: model.id, dimensions: model.dimensions, vectors: vectors, missed: missed)
    }

    // MARK: - 对外

    /// 自动挑模型的批量出向量（建索引前的探测用）。
    public static func embed(_ texts: [String]) -> Output? {
        guard !texts.isEmpty else { return Output(modelId: "", dimensions: 0, vectors: [], missed: 0) }
        let language = language(for: texts)
        var order = candidates(for: language)
        lock.lock()
        let preferred = lastWorking[language.rawValue]
        lock.unlock()
        if let preferred {
            order = [preferred] + order.filter { $0.id != preferred.id }
        }
        for model in order {
            guard let output = embed(texts, with: model) else { continue }
            lock.lock()
            lastWorking[language.rawValue] = model
            lock.unlock()
            return output
        }
        prepareInBackground()
        return nil
    }

    /// 指定模型出向量：已建索引的书按自己的出处算查询向量。
    public static func embed(_ texts: [String], usingModelId modelId: String) -> Output? {
        guard !texts.isEmpty else { return Output(modelId: modelId, dimensions: 0, vectors: [], missed: 0) }
        guard let model = model(withId: modelId) else {
            prepareInBackground()
            return nil
        }
        // 模型自己连探测文本都出不来向量 = 资源没了（系统回收 / 还没下载完）。
        guard model.vector(model.probe)?.isEmpty == false else {
            prepareInBackground()
            return nil
        }
        return embed(texts, with: model, allowEmpty: true)
    }

    /// 缺资源时在后台找系统要一次（系统自己下载，App 不打包模型）。
    /// 已经有能用的模型就什么都不做。
    public static func prepareInBackground() {
        lock.lock()
        if preparing {
            lock.unlock()
            return
        }
        preparing = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            defer {
                lock.lock()
                preparing = false
                lastWorking.removeAll()
                byId.removeAll()
                lock.unlock()
            }
            guard #available(iOS 17.0, macOS 14.0, *) else { return }
            for language in [NLLanguage.simplifiedChinese, .english] {
                guard let embedding = NLContextualEmbedding(language: language),
                      !embedding.hasAvailableAssets
                else { continue }
                let semaphore = DispatchSemaphore(value: 0)
                embedding.requestAssets { _, _ in semaphore.signal() }
                _ = semaphore.wait(timeout: .now() + 600)
                return
            }
        }
    }

    /// 这台机器上到底有哪些端侧向量资源：模型不可用时写进错误里，免得只有一句「不可用」。
    public static func diagnostics() -> String {
        var parts: [String] = []
        for language in [NLLanguage.simplifiedChinese, .english] {
            let sentence = NLEmbedding.sentenceEmbedding(for: language)
            let word = NLEmbedding.wordEmbedding(for: language)
            let sentenceProbe = sentence.flatMap { $0.vector(for: probeText(language)) }?.isEmpty == false
            lock.lock()
            let working = lastWorking[language.rawValue]
            lock.unlock()
            let state = working.map { "用 \($0.id)" } ?? (sentenceProbe ? "句向量可用" : "取不到向量")
            parts.append(
                "\(language.rawValue)：句向量 \(sentence.map { "\($0.dimension) 维" } ?? "无")、"
                    + "词向量 \(word.map { "\($0.dimension) 维" } ?? "无") → \(state)"
            )
        }
        if #available(iOS 17.0, macOS 14.0, *) {
            let contextual = NLContextualEmbedding(language: .simplifiedChinese)
            let state = contextual == nil
                ? "无"
                : "\(contextual!.dimension) 维" + (contextual!.hasAvailableAssets ? "已就绪" : "未下载")
            parts.append("上下文向量 \(state)")
        }
        return parts.joined(separator: "；")
    }

    private static func probeText(_ language: NLLanguage) -> String {
        language == .english ? "The light shines on the book." : "书灯是一盏照书的灯。"
    }
}
