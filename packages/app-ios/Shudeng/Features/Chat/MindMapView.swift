// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// 思维导图节点。
struct MindNode: Identifiable, Equatable {
    let id: String
    var title: String
    var children: [MindNode]

    static func == (left: MindNode, right: MindNode) -> Bool { left.id == right.id }
}

/// 把模型吐回来的 Markdown 大纲（# / ## / ### / -）解析成树。
enum MindMapOutline {
    final class Raw {
        var title: String
        var children: [Raw] = []

        init(_ title: String) { self.title = title }
    }

    static func parse(_ markdown: String) -> MindNode? {
        let root = Raw("思维导图")
        var headingStack: [(level: Int, node: Raw)] = []

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("```") else { continue }

            if let heading = heading(line) {
                while let last = headingStack.last, last.level >= heading.level {
                    headingStack.removeLast()
                }
                let parent = headingStack.last?.node ?? root
                let node = Raw(heading.title)
                parent.children.append(node)
                headingStack.append((heading.level, node))
                continue
            }

            if let leaf = bullet(line) {
                (headingStack.last?.node ?? root).children.append(Raw(leaf))
            }
        }

        guard !root.children.isEmpty else { return nil }
        // 只有一个根节点时（模型通常给一个 # 标题）把它提上来当中心。
        if root.children.count == 1, let only = root.children.first, !only.children.isEmpty {
            return convert(only, path: "0")
        }
        return convert(root, path: "root")
    }

    private static func convert(_ raw: Raw, path: String) -> MindNode {
        MindNode(
            id: path,
            title: raw.title,
            children: raw.children.enumerated().map { index, child in
                convert(child, path: "\(path)-\(index)")
            }
        )
    }

    /// `## 标题` → (层级, 文本)；正文里的 # 号不认（要求 # 后面有空格）。
    private static func heading(_ line: String) -> (level: Int, title: String)? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }
        guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
        let title = clean(String(line[index...]))
        return title.isEmpty ? nil : (level, title)
    }

    /// `- 要点` / `1. 要点` → 文本。
    private static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let title = clean(String(line.dropFirst(marker.count)))
            return title.isEmpty ? nil : title
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            let title = clean(String(line.dropFirst(digits.count + 1)))
            return title.isEmpty ? nil : title
        }
        return nil
    }

    private static func clean(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        value = value.replacingOccurrences(of: "**", with: "")
        value = value.replacingOccurrences(of: "`", with: "")
        if value.hasPrefix("> ") { value = String(value.dropFirst(2)) }
        // 模型爱在标题后加「：」或句号，收掉更干净。
        while let last = value.last, last == ":" || last == "：" || last == "。" {
            value.removeLast()
        }
        return value.trimmingCharacters(in: .whitespaces)
    }
}

/// 思维导图排版：按「层级横排、叶子纵排」算坐标，连线用贝塞尔曲线。
enum MindMapLayout {
    struct Placed: Identifiable {
        let id: String
        let title: String
        let depth: Int
        let hasChildren: Bool
        let collapsed: Bool
        let center: CGPoint
        let size: CGSize
    }

    struct Result {
        var nodes: [Placed] = []
        var edges: [(from: CGPoint, to: CGPoint)] = []
        var size: CGSize = .zero
    }

    static let hGap: CGFloat = 46
    static let vGap: CGFloat = 12

    static func build(root: MindNode, collapsed: Set<String>) -> Result {
        var result = Result()
        var cursorY: CGFloat = 0
        var maxX: CGFloat = 0

        @discardableResult
        func walk(_ node: MindNode, depth: Int, left: CGFloat) -> (centerY: CGFloat, top: CGFloat, bottom: CGFloat) {
            let size = self.size(of: node.title, depth: depth)
            let hidden = collapsed.contains(node.id)
            let children = hidden ? [] : node.children

            var centers: [CGFloat] = []
            var childLeft = left + size.width + hGap
            var childBottom: CGFloat = 0

            for child in children {
                let placement = walk(child, depth: depth + 1, left: childLeft)
                centers.append(placement.centerY)
                childBottom = max(childBottom, placement.bottom)
                // 下一个兄弟从当前子树底部再往下排
                cursorY = max(cursorY, placement.bottom + vGap)
            }

            let centerY: CGFloat
            if centers.isEmpty {
                centerY = cursorY + size.height / 2
                cursorY += size.height + vGap
            } else {
                centerY = (centers.first! + centers.last!) / 2
            }

            let center = CGPoint(x: left + size.width / 2, y: centerY)
            maxX = max(maxX, left + size.width)
            let placed = Placed(
                id: node.id,
                title: node.title,
                depth: depth,
                hasChildren: !node.children.isEmpty,
                collapsed: hidden,
                center: center,
                size: size
            )
            result.nodes.append(placed)

            for child in children {
                if let childNode = result.nodes.first(where: { $0.id == child.id }) {
                    result.edges.append((from: CGPoint(x: center.x + size.width / 2, y: center.y),
                                         to: CGPoint(x: childNode.center.x - childNode.size.width / 2,
                                                     y: childNode.center.y)))
                }
            }

            return (centerY, centerY - size.height / 2, childBottom > centerY ? childBottom : centerY + size.height / 2)
        }

        _ = walk(root, depth: 0, left: 0)
        result.size = CGSize(width: maxX + 24, height: max(cursorY + 24, 120))
        return result
    }

    static func size(of title: String, depth: Int) -> CGSize {
        let font = font(depth: depth)
        let maxTextWidth: CGFloat = depth == 0 ? 190 : 170
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let measured = (title as NSString).size(withAttributes: attributes)
        let width = min(measured.width + 26, maxTextWidth + 26)
        let lines = max(1, Int(ceil(measured.width / maxTextWidth)))
        let height = CGFloat(lines) * (font.lineHeight + 1) + 14
        return CGSize(width: max(width, 64), height: max(height, 34))
    }

    static func font(depth: Int) -> UIFont {
        switch depth {
        case 0: UIFont.systemFont(ofSize: 15, weight: .semibold)
        case 1: UIFont.systemFont(ofSize: 14, weight: .medium)
        default: UIFont.systemFont(ofSize: 13, weight: .regular)
        }
    }
}

/// 导图画布：可拖动、双指缩放，点节点展开 / 收起。
struct MindMapCanvas: View {
    let root: MindNode

    @State private var collapsed: Set<String> = []
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private var layout: MindMapLayout.Result {
        MindMapLayout.build(root: root, collapsed: collapsed)
    }

    var body: some View {
        GeometryReader { geo in
            let result = layout
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for edge in result.edges {
                        var path = Path()
                        let midX = (edge.from.x + edge.to.x) / 2
                        path.move(to: edge.from)
                        path.addCurve(
                            to: edge.to,
                            control1: CGPoint(x: midX, y: edge.from.y),
                            control2: CGPoint(x: midX, y: edge.to.y)
                        )
                        context.stroke(path, with: .color(Color(.tertiaryLabel)), lineWidth: 1.4)
                    }
                }
                .frame(width: result.size.width, height: result.size.height)

                ForEach(result.nodes) { node in
                    nodeView(node)
                        .frame(width: node.size.width, height: node.size.height)
                        .position(node.center)
                }
            }
            .frame(width: result.size.width, height: result.size.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .offset(offset)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        offset = CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in lastOffset = offset }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        scale = min(max(lastScale * value.magnification, 0.4), 3)
                    }
                    .onEnded { _ in lastScale = scale }
            )
            .onAppear { scale = 1; lastScale = 1 }
        }
    }

    private func nodeView(_ node: MindMapLayout.Placed) -> some View {
        let isRoot = node.depth == 0
        return Button {
            guard node.hasChildren else { return }
            if collapsed.contains(node.id) {
                collapsed.remove(node.id)
            } else {
                collapsed.insert(node.id)
            }
        } label: {
            HStack(spacing: 6) {
                Text(node.title)
                    .font(.system(size: fontSize(node.depth), weight: weight(node.depth)))
                    .foregroundStyle(isRoot ? Color(.systemBackground) : Color.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if node.hasChildren {
                    Image(systemName: node.collapsed ? "plus.circle" : "minus.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(isRoot ? Color(.systemBackground).opacity(0.7) : Color.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isRoot ? Color.primary : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isRoot ? Color.clear : Theme.hairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mindmap.node")
        .accessibilityLabel(node.title)
    }

    private func fontSize(_ depth: Int) -> CGFloat {
        depth == 0 ? 15 : (depth == 1 ? 14 : 13)
    }

    private func weight(_ depth: Int) -> Font.Weight {
        depth == 0 ? .semibold : (depth == 1 ? .medium : .regular)
    }
}

/// 思维导图弹层：问一次模型拿 Markdown 大纲，画成导图，可换范围重新生成。
struct MindMapSheet: View {
    enum Scope: String, CaseIterable, Identifiable {
        case chapter
        case page

        var id: String { rawValue }

        var label: String {
            switch self {
            case .chapter: "本章"
            case .page: "当前页"
            }
        }
    }

    enum Phase {
        case loading
        case ready(MindNode)
        case failed(String)
    }

    @EnvironmentObject private var runtime: RuntimeHost
    @EnvironmentObject private var reading: ReadingSession
    @EnvironmentObject private var aiSettings: AISettings
    @Environment(\.dismiss) private var dismiss

    @State private var scope: Scope = .chapter
    @State private var phase: Phase = .loading
    @State private var outline = ""
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在读这一章…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") { generate() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready(let root):
                    MindMapCanvas(root: root)
                        .background(Color(.systemGroupedBackground))
                        // 标识不能挂在节点容器上：SwiftUI 会把容器的标识盖到里面的节点上，
                        // 每个节点都会变成 mindmap.canvas（UI 测试就找不到 mindmap.node 了）。
                        .overlay(
                            Color.clear
                                .allowsHitTesting(false)
                                .accessibilityElement()
                                .accessibilityLabel("思维导图画布")
                                .accessibilityIdentifier("mindmap.canvas")
                        )
                }
            }
            .navigationTitle("思维导图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("范围", selection: $scope) {
                        ForEach(Scope.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                    .accessibilityIdentifier("mindmap.scope")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = outline
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(outline.isEmpty)
                    .accessibilityIdentifier("mindmap.copy")
                    Button {
                        generate()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("mindmap.regenerate")
                    Button("完成") { dismiss() }
                }
            }
            .task { if case .loading = phase { generate() } }
            .onChange(of: scope) { _, _ in generate() }
        }
    }

    private func generate() {
        guard aiSettings.isConfigured else {
            phase = .failed("先在「我的 → AI 设置」里配好端点")
            return
        }
        let text = scope == .chapter ? reading.chapterText : reading.visibleText
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else {
            phase = .failed(scope == .chapter ? "这一章还没取到正文，先翻一页试试" : "当前页没取到正文")
            return
        }

        phase = .loading
        var payload: [String: Any] = [
            "provider": aiSettings.provider.rawValue,
            "baseUrl": aiSettings.baseURL,
            "apiKey": aiSettings.apiKey,
            "model": aiSettings.model,
            "text": String(trimmed.prefix(12000)),
        ]
        if let book = reading.book {
            payload["title"] = book.title
            payload["author"] = book.author
        }
        if !reading.chapterTitle.isEmpty { payload["chapterTitle"] = reading.chapterTitle }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else {
            phase = .failed("参数拼装失败")
            return
        }

        runtime.callAsync("ShudengApp.mindmap(\(json))", timeout: 180) { raw in
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                phase = .failed("导图没生成出来，再试一次")
                return
            }
            if let error = object["error"] as? String {
                phase = .failed("导图生成失败：\(error)")
                return
            }
            let markdown = object["text"] as? String ?? ""
            guard let root = MindMapOutline.parse(markdown) else {
                phase = .failed("模型没给出能用的大纲，再试一次")
                return
            }
            outline = markdown
            phase = .ready(root)
        }
    }
}
