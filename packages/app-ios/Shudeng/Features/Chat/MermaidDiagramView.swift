// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import WebKit

/// Mermaid 图表：core 用 beautiful-mermaid 把 ```mermaid 渲染成 SVG 字符串，
/// SwiftUI 画不了 SVG，这里找一层 WKWebView 显示；点一下可以放大看全。
struct MermaidDiagramView: View {
    let svg: String

    @State private var showFullScreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SVGWebView(svg: svg, allowsZoom: false)
                .aspectRatio(Self.aspect(of: svg), contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 460)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
                )
                // WKWebView 自带一套无障碍子树，外层挂的标识会被它吃掉：
                // 这里盖一层透明的无障碍元素，读屏和 UI 测试才找得到「图表」。
                .overlay(
                    Color.clear
                        .allowsHitTesting(false)
                        .accessibilityElement()
                        .accessibilityLabel("图表")
                        .accessibilityIdentifier("chat.mermaid")
                )
                .contentShape(Rectangle())
                .onTapGesture { showFullScreen = true }
            Text("点一下放大看")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showFullScreen) {
            NavigationStack {
                SVGWebView(svg: svg, allowsZoom: true)
                    .background(Color(.systemBackground))
                    .navigationTitle("图表")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showFullScreen = false }
                        }
                    }
            }
        }
    }

    /// 宽高比直接算在布局约束里，不去读 GeometryReader 的宽度：
    /// 读了宽度再回写高度，会和 WKWebView 的尺寸互相触发，主线程直接 100% 空转。
    static func aspect(of svg: String) -> CGFloat {
        let size = Self.canvasSize(of: svg)
        guard size.width > 0, size.height > 0 else { return 1.8 }
        return size.width / size.height
    }

    /// SVG 根节点上的 width / height（beautiful-mermaid 按图算好，直接拿来算宽高比）。
    static func canvasSize(of svg: String) -> CGSize {
        func value(_ name: String) -> Double? {
            guard let range = svg.range(of: "\(name)=\"") else { return nil }
            let rest = svg[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return Double(rest[..<end])
        }
        guard let width = value("width"), let height = value("height") else { return .zero }
        return CGSize(width: width, height: height)
    }
}

/// 只负责把一段 SVG 塞进 WKWebView（SVG 走 base64 data URL，免得被 HTML 里的内容干扰）。
struct SVGWebView: UIViewRepresentable {
    let svg: String
    var allowsZoom = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let web = NoIntrinsicWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = allowsZoom
        web.scrollView.bouncesZoom = allowsZoom
        web.scrollView.maximumZoomScale = allowsZoom ? 6 : 1
        if allowsZoom { web.scrollView.delegate = context.coordinator }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.rendered != svg else { return }
        context.coordinator.rendered = svg
        web.loadHTMLString(Self.html(svg: svg), baseURL: nil)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var rendered: String?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.subviews.first
        }
    }

    static func html(svg: String) -> String {
        let base64 = Data(stripRemoteFonts(svg).utf8).base64EncodedString()
        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=6">
        <style>
          html, body { margin: 0; padding: 0; background: transparent; }
          img { width: 100%; height: auto; display: block; }
        </style></head>
        <body><img src="data:image/svg+xml;base64,\(base64)" alt="diagram"></body></html>
        """
    }

    /// SVG 里带的 Google Fonts @import 在 App 内没有意义（国内网络拉不到，白等一次请求），去掉。
    static func stripRemoteFonts(_ svg: String) -> String {
        guard svg.contains("@import") else { return svg }
        return svg
            .components(separatedBy: "\n")
            .filter { !$0.contains("@import") }
            .joined(separator: "\n")
    }
}

/// WKWebView 会把自己的网页内容尺寸当成 intrinsicContentSize 报给 SwiftUI：
/// 在「气泡宽度跟着内容走」的聊天列表里，这会和外层布局来回触发，主线程卡死
/// （UI 测试里就是 “process main thread busy for 30.0s”）。尺寸交给外面的 frame 决定。
final class NoIntrinsicWebView: WKWebView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }
}

/// 对话里的 ```mermaid 代码块：交给 core 画成 SVG，再给上面的视图显示。
struct MermaidBlockView: View {
    let source: String
    /// 这条回答还在流式输出时，``` 里的源码是半截的：先不画，等写完再画一次。
    var streaming = false

    @EnvironmentObject private var runtime: RuntimeHost
    @Environment(\.colorScheme) private var colorScheme
    @State private var svg: String?
    @State private var failed = false
    @State private var renderGeneration = 0

    var body: some View {
        Group {
            if streaming {
                placeholder
            } else if let svg {
                MermaidDiagramView(svg: svg)
            } else if failed {
                VStack(alignment: .leading, spacing: 6) {
                    Text("图表没画出来，原文如下")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(source)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.tertiarySystemBackground))
                )
            } else {
                placeholder
            }
        }
        .task(id: cacheKey) { render() }
        .onDisappear { renderGeneration += 1 }
    }

    private var placeholder: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(streaming ? "图表等回答写完再画…" : "正在画图表…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var cacheKey: String {
        "\(colorScheme == .dark ? "dark" : "light")|\(streaming)|\(source)"
    }

    private func render() {
        renderGeneration += 1
        let generation = renderGeneration
        let key = cacheKey
        guard !streaming else { return }
        if let cached = MermaidSVGCache.shared.value(for: key) {
            failed = false
            svg = cached
            return
        }
        svg = nil
        failed = false

        let payload: [String: Any] = ["text": source, "dark": colorScheme == .dark]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else {
            failed = true
            return
        }

        runtime.callAsync("ShudengApp.renderMermaid(\(json))", timeout: 30) { raw in
            guard generation == renderGeneration else { return }
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = object["svg"] as? String,
                  !value.isEmpty
            else {
                failed = true
                return
            }
            MermaidSVGCache.shared.store(value, for: key)
            svg = value
        }
    }
}

/// 同一段图表别每滚一次就重画一遍。
@MainActor
final class MermaidSVGCache {
    static let shared = MermaidSVGCache()
    private var items: [String: String] = [:]

    func value(for key: String) -> String? { items[key] }

    func store(_ svg: String, for key: String) {
        if items.count >= 60 { items.removeAll() }
        items[key] = svg
    }
}
