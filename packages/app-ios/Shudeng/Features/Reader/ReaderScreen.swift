// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import SwiftUI
import WebKit

struct ReaderTOCItem: Identifiable, Decodable, Hashable {
    let id: String
    let title: String
    let level: Int
    let href: String?
    let subitems: [ReaderTOCItem]?

    var children: [ReaderTOCItem] { subitems ?? [] }
}

struct ReaderSelection: Equatable {
    let text: String
    let cfi: String
}

/// Swift → WebView 的命令通道。
final class ReaderController: ObservableObject {
    fileprivate weak var webView: WKWebView?

    func send(_ payload: [String: Any]) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        DispatchQueue.main.async {
            webView.evaluateJavaScript("window.handleCommand && window.handleCommand(\(json))")
        }
    }

    /// 直接调 reader.html 暴露的全局函数（handleCommand 里没有的那些，比如取朗读分段）。
    func evaluate(_ script: String) {
        guard let webView else { return }
        DispatchQueue.main.async {
            webView.evaluateJavaScript(script)
        }
    }
}

struct ReaderScreen: View {
    @EnvironmentObject private var runtime: RuntimeHost
    @EnvironmentObject private var reading: ReadingSession
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var aiSettings: AISettings
    @EnvironmentObject private var chat: ChatService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var toolbarIconSize = 17

    @StateObject private var controller = ReaderController()
    @StateObject private var tts = ReaderSpeech()
    @StateObject private var ttsRequester = TTSSegmentRequester()

    @State private var isLoading = true
    @State private var showControls = true
    @State private var showTOC = false
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showChat = false
    @State private var toc: [ReaderTOCItem] = []
    @State private var selection: ReaderSelection?
    @State private var sliderFraction: Double = 0
    @State private var pageIndex = 0
    @State private var sectionIndex = 0
    @State private var sectionTotal = 0
    /// 已经取过正文的章节号：换章才重新抽，翻页不重复抽。
    @State private var chapterTextSection = -1
    @State private var chapterTextTask: Task<Void, Never>?
    @State private var speechTask: Task<Void, Never>?
    @State private var speechGeneration = 0
    @State private var pageTotal = 0
    /// foliate 的剩余阅读时间（分钟），来自 relocate 的 time.total。
    @State private var remainingMinutes: Double = 0
    @State private var searchQuery = ""
    @State private var searchCount = 0
    @State private var searchIndex = 0
    @State private var bookmarks: [BookmarkItem] = []
    @State private var pushedBookmarkState: Bool?
    @State private var noteDraft = ""
    @FocusState private var noteFocused: Bool
    @State private var noteOriginal = ""
    @State private var noteDraftRestored = false
    @State private var noteDraftError: String?
    /// 打开「写笔记」弹窗时先把选中的那一段存下来：
    /// 弹窗/键盘一起出现时 WebView 会重新排版，页面里的选中可能被系统收掉，届时再用 selection 就晚了。
    @State private var noteTarget: ReaderSelection?
    @State private var editingAnnotation: HighlightItem?
    @State private var showNoteEditor = false
    @State private var noteError: String?
    @State private var toast: String?
    @State private var showTranslation = false
    @State private var isTranslating = false
    @State private var translationSource = ""
    @State private var translationGeneration = 0
    @State private var translatedText: String?
    /// 朗读睡眠定时器：0 = 不限时，其余是还剩多少秒。
    @State private var sleepMinutes = 0
    @State private var sleepRemaining = 0
    @State private var sleepTicker: Timer?

    private let highlightColors: [(name: String, hex: String)] = [
        ("yellow", "#facc15"),
        ("green", "#4ade80"),
        ("blue", "#60a5fa"),
        ("pink", "#f472b6"),
        ("purple", "#c084fc"),
    ]
    /// 跟读高亮的颜色（reader.html 会压到 35% 透明度，衬得住黑字）。
    private static let ttsHighlightHex = "#60a5fa"

    var body: some View {
        ZStack {
            settings.readerTheme.background.ignoresSafeArea()

            if let book = reading.book {
                // 工具条保留布局占位；显隐不改变正文尺寸，也不会遮住首末行。
                VStack(spacing: 0) {
                    topBar(book)
                        .offset(y: showControls ? 0 : -140)
                        .opacity(showControls ? 1 : 0)
                        .allowsHitTesting(showControls)
                    FoliateWebView(
                        rootDirectory: runtime.rootDirectory,
                        book: book,
                        pageMargin: settings.pageMargin,
                        initialSettingsJSON: json(settings.readerPayload),
                        initialLocation: reading.pendingLocation ?? book.currentCfi,
                        isLoading: $isLoading,
                        controller: controller,
                        onEvent: handle(event:)
                    )
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 8) {
                            if tts.isSpeaking {
                                speechBar
                            }
                            if let selection {
                                selectionBar(selection)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 72)
                    }
                    bottomBar
                        .offset(y: showControls ? 0 : 140)
                        .opacity(showControls ? 1 : 0)
                        .allowsHitTesting(showControls)
                }

                if isLoading {
                    ProgressView().tint(.secondary)
                }

                if let toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.footnote)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color(.label).opacity(0.85)))
                            .foregroundStyle(Color(.systemBackground))
                            .padding(.bottom, 120)
                    }
                    .allowsHitTesting(false)
                }
            } else {
                EmptyHint(icon: "book", title: "还没有打开的书", message: "回书库点一本开始读")
            }
        }
        // 弹层键盘不改变底下正文的分页；各弹层独立处理输入区避让。
        .ignoresSafeArea(.keyboard)
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: showControls)
        .onAppear { reading.beginSession() }
        .onDisappear {
            translationGeneration += 1
            stopSpeech()
            reading.flush(using: runtime)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                stopSpeech()
                reading.flush(using: runtime)
            } else {
                reading.resumeSession()
            }
        }
        .onChange(of: tts.isSpeaking) { _, speaking in
            if !speaking { cancelSleepTimer() }
        }
        .onChange(of: runtime.state) { _, state in
            guard state == .ready else { return }
            loadAnnotations()
            loadBookmarks()
        }
        .sheet(isPresented: $showTOC) { tocSheet }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showSearch) { searchSheet }
        .sheet(isPresented: $showChat) { ChatView.ChatSheet() }
        .sheet(isPresented: $showTranslation, onDismiss: {
            translationGeneration += 1
            isTranslating = false
        }) { translationSheet }
        .sheet(isPresented: $showNoteEditor) {
            NavigationStack {
                Form {
                    if let target = noteTarget {
                        Text(target.text)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("reader.noteOriginal")
                    }
                    TextField("想法…", text: $noteDraft, axis: .vertical)
                        .lineLimit(3...12)
                        .accessibilityIdentifier("reader.noteEditor")
                        .focused($noteFocused)
                    if noteDraftRestored {
                        Text("已恢复未保存的内容")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("note.draftRestored")
                    }
                    if let noteDraftError {
                        Text(noteDraftError).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("note.draftError")
                    }
                    if let noteError {
                        Text(noteError).font(.footnote).foregroundStyle(.secondary)
                    }
                    if editingAnnotation != nil {
                        Button("删除标注", role: .destructive) { deleteAnnotation() }
                            .accessibilityIdentifier("reader.annotationDelete")
                    }
                }
                .navigationTitle("写笔记")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        NoteCancelButton(hasChanges: noteDraft != noteOriginal) {
                            guard discardNoteDraft() else { return }
                            noteTarget = nil
                            editingAnnotation = nil
                            noteDraft = ""
                            showNoteEditor = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { saveNote() }
                            .accessibilityIdentifier("reader.noteSave")
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .interactiveDismissDisabled(noteDraft != noteOriginal)
            .onAppear {
                restoreNoteDraft(original: editingAnnotation?.note ?? "")
                noteFocused = true
            }
            .onChange(of: noteDraft) { _, text in
                guard let book = reading.book, let target = noteTarget else { return }
                do {
                    try NoteDrafts.preserve(bookId: book.id, cfi: target.cfi, original: noteOriginal, text: text)
                    noteDraftError = nil
                } catch {
                    noteDraftError = "草稿暂时无法保留，离开前请保存笔记。"
                }
            }
        }
    }

    // MARK: - 控制层

    private func topBar(_ book: LibraryStore.Book) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    close()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: min(toolbarIconSize, 28), weight: .semibold))
                        .frame(width: dynamicTypeSize.isAccessibilitySize ? 44 : 30, height: dynamicTypeSize.isAccessibilitySize ? 44 : 30)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("reader.close")

                // 标题和右边的 ☰ 都能开目录：标题管顺手，图标管「找得到」。
                Button {
                    showTOC = true
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(book.title).font(.footnote.weight(.semibold)).lineLimit(1)
                        Text(chapterSubtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reader.toc")

                if !dynamicTypeSize.isAccessibilitySize { toolbarActions }
            }
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) { toolbarActions }
                }
            }
        }
        .font(.body)
        .foregroundStyle(Color(.label))
        .frame(minHeight: 30)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .bottom) {
            Theme.hairline.frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var toolbarActions: some View {
        iconButton("list.bullet", id: "reader.tocButton", label: "目录") { showTOC = true }
        iconButton("magnifyingglass", id: "reader.search", label: "查找正文") { showSearch = true }
        iconButton(isBookmarked ? "bookmark.fill" : "bookmark", id: "reader.bookmark", label: isBookmarked ? "移除书签" : "添加书签") { toggleBookmark() }
            .accessibilityValue(isBookmarked ? "已加书签" : "未加书签")
            .disabled(reading.cfi.isEmpty)
        iconButton(tts.isSpeaking ? "stop.circle" : "speaker.wave.2", id: "reader.speech", label: tts.isSpeaking ? "停止朗读" : "开始朗读") { toggleSpeech() }
            .accessibilityValue(tts.isSpeaking ? "speaking" : "idle")
            // 正文还没取回来之前先别让点：否则只会弹「没有可朗读的正文」。
            .disabled(reading.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !tts.isSpeaking)
        iconButton("sparkles", id: "reader.chat", label: "AI 助手") {
            chat.prepareForReading(reading.book)
            showChat = true
        }
        iconButton("slider.horizontal.3", id: "reader.settings", label: "阅读设置") { showSettings = true }
    }

    private func iconButton(_ systemName: String, id: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: min(toolbarIconSize, 28)))
                .frame(width: dynamicTypeSize.isAccessibilitySize ? 44 : 28, height: dynamicTypeSize.isAccessibilitySize ? 44 : 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
    }

    private var bottomBar: some View {
        // 只留三段信息：本章页码、全书百分比、剩余时间。轨道和图标都撤了。
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Text(chapterProgressLabel)
                .accessibilityIdentifier("reader.progress")

            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }

            Text("全书 \(Int(sliderFraction * 100))%")
                .accessibilityIdentifier("reader.percent")

            if let remainingLabel {
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                Text(remainingLabel)
                    .accessibilityIdentifier("reader.remaining")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Theme.hairline.frame(height: 0.5)
        }
    }

    private func selectionBar(_ selection: ReaderSelection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(selection.text)
                .font(.footnote)
                .lineLimit(3)
                .foregroundStyle(.primary)
            HStack(spacing: 10) {
                ForEach(highlightColors, id: \.name) { color in
                    Button {
                        saveHighlight(selection, color: color)
                    } label: {
                        Circle()
                            .fill(Color(hex: color.hex))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("reader.highlight.\(color.name)")
                }
                Spacer(minLength: 0)
                Button {
                    editingAnnotation = nil
                    if noteTarget != selection {
                        noteTarget = selection
                        restoreNoteDraft(original: "")
                    }
                    noteError = nil
                    showNoteEditor = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityIdentifier("reader.selectionNote")
                Button {
                    UIPasteboard.general.string = selection.text
                    flash("已复制")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityIdentifier("reader.selectionCopy")
                Button {
                    translate(selection)
                } label: {
                    Image(systemName: "character.book.closed")
                }
                .disabled(isTranslating)
                .accessibilityIdentifier("reader.selectionTranslate")
                ShareLink(item: selection.text) {
                    Image(systemName: "square.and.arrow.up")
                }
                Button {
                    // 选中一段再问 ＝ 这本书的一段新对话，不接在旧对话后面。
                    chat.prepareForSelection(reading.book)
                    showChat = true
                } label: {
                    Image(systemName: "sparkles")
                }
                Button {
                    self.selection = nil
                    reading.setSelection(text: "", cfi: "")
                    controller.send(["type": "clearSelection"])
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityIdentifier("reader.selectionClose")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        )
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.selectionBar")
    }

    /// 朗读中的迷你条：还剩多久、几点停、一键停。
    private var speechBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
            Text(sleepRemaining > 0 ? "朗读中 · 还有 \(sleepLabel)" : "朗读中")
                .font(.footnote)
                .monospacedDigit()
                .accessibilityIdentifier("reader.speechStatus")
            Spacer(minLength: 0)
            Menu {
                ForEach([0, 5, 15, 30, 60], id: \.self) { minutes in
                    Button {
                        startSleepTimer(minutes)
                    } label: {
                        if minutes == sleepMinutes, minutes > 0 {
                            Label("\(minutes) 分钟后停", systemImage: "checkmark")
                        } else {
                            Text(minutes == 0 ? "不限时" : "\(minutes) 分钟后停")
                        }
                    }
                }
            } label: {
                Image(systemName: sleepRemaining > 0 ? "moon.zzz.fill" : "moon.zzz")
            }
            .accessibilityIdentifier("reader.sleepTimer")
            Button {
                stopSpeech()
            } label: {
                Image(systemName: "stop.circle")
            }
            .accessibilityIdentifier("reader.stopSpeech")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        )
    }

    private var sleepLabel: String {
        String(format: "%d:%02d", sleepRemaining / 60, sleepRemaining % 60)
    }

    private func startSleepTimer(_ minutes: Int) {
        sleepTicker?.invalidate()
        sleepTicker = nil
        sleepMinutes = minutes
        sleepRemaining = minutes * 60
        guard minutes > 0 else { return }
        sleepTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                guard sleepRemaining > 0 else { return }
                sleepRemaining -= 1
                if sleepRemaining == 0 {
                    sleepTicker?.invalidate()
                    sleepTicker = nil
                    stopSpeech()
                    flash("睡眠定时到，朗读停了")
                }
            }
        }
    }

    private func cancelSleepTimer() {
        sleepTicker?.invalidate()
        sleepTicker = nil
        sleepMinutes = 0
        sleepRemaining = 0
    }

    private func stopSpeech() {
        speechGeneration += 1
        speechTask?.cancel()
        speechTask = nil
        tts.stop()
        cancelSleepTimer()
        controller.send(["type": "clearTTSHighlight"])
    }

    // MARK: - 面板

    private var tocSheet: some View {
        NavigationStack {
            List {
                ForEach(toc) { item in
                    Button {
                        if let href = item.href, !href.isEmpty {
                            controller.send(["type": "goToHref", "href": href])
                            showTOC = false
                        }
                    } label: {
                        Text(item.title)
                            .font(.subheadline)
                            .padding(.leading, CGFloat(item.level) * 14)
                            .foregroundStyle(Color(.label))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("reader.tocRow")
                }
            }
            .listStyle(.plain)
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showTOC = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var settingsSheet: some View {
        NavigationStack {
            // 这一页照 Apple Books 的「主题与设置」排：主题缩略图（Aa 预览）是主角，
            // 字号和排版用系统控件直接躺在分组底板上，不再是一张 Form。
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        settingsLabel("主题")
                        HStack(spacing: 12) {
                            ForEach(ReaderTheme.allCases) { theme in
                                themeSwatch(theme)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            settingsLabel("字号")
                            Spacer(minLength: 8)
                            Text("\(Int(settings.fontSize)) pt")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 14) {
                            Text("A").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            Slider(value: $settings.fontSize, in: 12...32, step: 1)
                                .tint(.primary)
                            Text("A").font(.system(size: 21, weight: .medium))
                        }
                        .padding(.horizontal, 18)
                        .frame(height: 52)
                        .background(settingsTile)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        settingsLabel("排版")
                        VStack(spacing: 0) {
                            settingsRow {
                                Text("翻页方式").font(.subheadline)
                                Spacer(minLength: 10)
                                Picker("翻页方式", selection: $settings.continuousScroll) {
                                    Text("分页").tag(false)
                                    Text("连续滚动").tag(true)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 176)
                            }
                            settingsRowDivider
                            settingsRow {
                                Stepper(value: $settings.lineHeight, in: 1.2...2.4, step: 0.1) {
                                    settingsValue("行距", String(format: "%.2f", settings.lineHeight))
                                }
                            }
                            settingsRowDivider
                            settingsRow {
                                Stepper(value: $settings.paragraphSpacing, in: 0...32, step: 4) {
                                    settingsValue("段间距", "\(Int(settings.paragraphSpacing)) pt")
                                }
                            }
                            settingsRowDivider
                            settingsRow {
                                Stepper(value: $settings.pageMargin, in: 8...64, step: 4) {
                                    settingsValue("页边距", "\(Int(settings.pageMargin)) pt")
                                }
                            }
                            settingsRowDivider
                            settingsRow {
                                Toggle(isOn: $settings.justify) {
                                    Text("两端对齐").font(.subheadline)
                                }
                            }
                            settingsRowDivider
                            settingsRow {
                                Toggle(isOn: $settings.serifFont) {
                                    Text("衬线字体").font(.subheadline)
                                }
                            }
                        }
                        .background(settingsTile)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        settingsLabel("朗读与高亮")
                        VStack(spacing: 0) {
                            settingsRow {
                                Stepper(value: $settings.ttsRate, in: 0.3...0.7, step: 0.05) {
                                    settingsValue("朗读语速", String(format: "%.2f", settings.ttsRate))
                                }
                            }
                            settingsRowDivider
                            settingsRow {
                                Text("默认高亮颜色").font(.subheadline)
                                Spacer(minLength: 10)
                                HStack(spacing: 12) {
                                    ForEach(highlightColors, id: \.name) { color in
                                        Button {
                                            settings.highlightColor = color.name
                                        } label: {
                                            Circle()
                                                .fill(Color(hex: color.hex))
                                                .frame(width: 22, height: 22)
                                                .overlay(
                                                    Circle().strokeBorder(
                                                        settings.highlightColor == color.name ? Color.primary : Theme.hairline,
                                                        lineWidth: settings.highlightColor == color.name ? 2 : 0.5
                                                    )
                                                )
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(color.name)
                                    }
                                }
                            }
                        }
                        .background(settingsTile)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showSettings = false }
                }
            }
            .onChange(of: settings.fontSize) { _, _ in pushSettings() }
            .onChange(of: settings.lineHeight) { _, _ in pushSettings() }
            .onChange(of: settings.paragraphSpacing) { _, _ in pushSettings() }
            .onChange(of: settings.pageMargin) { _, _ in pushSettings() }
            .onChange(of: settings.continuousScroll) { _, _ in pushSettings() }
            .onChange(of: settings.justify) { _, _ in pushSettings() }
            .onChange(of: settings.serifFont) { _, _ in pushSettings() }
            .onChange(of: settings.readerTheme) { _, _ in pushTheme() }
        }
        .presentationDetents([.medium, .large])
    }

    private func settingsLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var settingsTile: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(.secondarySystemBackground))
    }

    private var settingsRowDivider: some View {
        Divider().padding(.leading, 16)
    }

    private func settingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(content: content)
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
    }

    private func settingsValue(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// 主题缩略图：底色 + Aa 预览 + 名字，选中描一圈黑边。Apple Books 的做法。
    private func themeSwatch(_ theme: ReaderTheme) -> some View {
        let selected = settings.readerTheme == theme
        return Button {
            settings.readerTheme = theme
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.background)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Text("Aa")
                            .font(.system(.title3, design: .serif))
                            .foregroundStyle(theme.foreground)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                selected ? Color.primary : Theme.hairline,
                                lineWidth: selected ? 1.6 : 0.5
                            )
                    }
                Text(theme.label)
                    .font(.caption2)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.label)
        .accessibilityIdentifier("reader.theme.\(theme.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var searchSheet: some View {
        NavigationStack {
            List {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("书内搜索", text: $searchQuery)
                        .accessibilityIdentifier("reader.searchField")
                        .submitLabel(.search)
                        .onSubmit {
                            searchCount = 0
                            searchIndex = 0
                            controller.send(["type": "search", "query": searchQuery])
                        }
                }
                if searchCount > 0 {
                    LabeledContent("结果", value: "\(searchIndex + 1) / \(searchCount)")
                    HStack {
                        Button("上一个") {
                            controller.send(["type": "navigateSearch", "index": max(0, searchIndex - 1)])
                        }
                        Spacer()
                        Button("下一个") {
                            controller.send(["type": "navigateSearch", "index": min(searchCount - 1, searchIndex + 1)])
                        }
                    }
                } else {
                    Text("输入关键词后回车，会跳到第一处并高亮。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("清除") {
                        searchQuery = ""
                        searchCount = 0
                        controller.send(["type": "clearSearch"])
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showSearch = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// 选中文本翻译：走和对话同一个 AI 端点（core 的 aiTranslate）。
    private var translationSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(translationSource)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Divider()
                    if isTranslating {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在翻译…").font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        MarkdownText(text: translatedText ?? "")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("翻译")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("复制") {
                        UIPasteboard.general.string = translatedText ?? ""
                        flash("已复制译文")
                    }
                    .disabled(translatedText?.isEmpty != false)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showTranslation = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - 动作

    private var chapterSubtitle: String {
        if !reading.chapterTitle.isEmpty { return reading.chapterTitle }
        if sectionTotal > 0 { return "第 \(sectionIndex + 1) / \(sectionTotal) 节" }
        return "书灯"
    }

    /// 底栏左侧：reader.html 给的是「本节（章节）内第几页」，所以必须写明「本章」，
    /// 不然会被当成整本书的页码。
    private var chapterProgressLabel: String {
        if pageTotal > 1, pageIndex > 0 { return "本章 \(pageIndex) / \(pageTotal)" }
        if sectionTotal > 0 { return "第 \(sectionIndex + 1) / \(sectionTotal) 节" }
        return "—"
    }

    /// 底栏右侧：foliate 按书里字符数算出来的剩余阅读时间（分钟）。
    private var remainingLabel: String? {
        guard remainingMinutes >= 1 else { return nil }
        let minutes = Int(remainingMinutes.rounded())
        if minutes >= 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? "还剩 \(hours) 小时" : "还剩 \(hours) 小时 \(rest) 分"
        }
        return "还剩 \(minutes) 分钟"
    }

    private var isBookmarked: Bool {
        guard !reading.cfi.isEmpty else { return false }
        return bookmarks.contains { $0.cfi == reading.cfi }
    }

    private func close() {
        reading.flush(using: runtime)
        reading.isReaderPresented = false
    }

    private func pushSettings() {
        controller.send(["type": "applySettings", "settings": settings.readerPayload])
    }

    private func pushTheme() {
        controller.send([
            "type": "setThemeColors",
            "colors": settings.readerTheme.payload,
            "themeMode": settings.readerTheme.mode,
        ])
    }

    /// 朗读当前页；没拿到正文时给提示，而不是静默无反应。
    /// 有分段（reader.html 的句子级切分）时按段读，读到哪句高亮哪句；拿不到就退回整页朗读。
    private func toggleSpeech() {
        if tts.isSpeaking {
            stopSpeech()
            return
        }
        if speechTask != nil {
            stopSpeech()
            return
        }
        let text = reading.visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            flash("这一页没有可朗读的正文")
            return
        }
        let rate = settings.ttsRate
        let anchor = reading.cfi
        speechGeneration += 1
        let generation = speechGeneration
        speechTask = Task { @MainActor in
            defer {
                if speechGeneration == generation { speechTask = nil }
            }
            let segments = await ttsRequester.request { requestID in
                self.controller.evaluate(
                    "window.doGetVisibleTTSSegments && window.doGetVisibleTTSSegments("
                        + "\(Self.jsString(anchor)), \(Self.jsString(requestID)))"
                )
            }
            if Task.isCancelled || speechGeneration != generation || tts.isSpeaking { return }
            // 分段拿不到（PDF / 引擎还没就绪）时退回整页朗读，功能不能因此变哑巴。
            let ordered = segments.isEmpty
                ? ReaderSpeech.chunk(text).map { ReaderSpeech.Segment(text: $0, cfi: "") }
                : segments
            let speech = Self.slice(from: reading.visibleText, in: ordered)
            startSpeech(speech, rate: rate)
        }
    }

    /// reader.html 给的分段是整个 section 的：不过滤的话会从本章开头读起，高亮画在屏幕外。
    /// 这里按「当前页第一句话」裁一刀，从看得见的那句开始读。
    static func slice(from pageText: String, in segments: [ReaderSpeech.Segment]) -> [ReaderSpeech.Segment] {
        let page = compactText(pageText)
        guard page.count >= 8 else { return segments }
        let pageHead = String(page.prefix(12))
        for (index, segment) in segments.enumerated() {
            let text = compactText(segment.text)
            guard text.count >= 4 else { continue }
            if text.contains(pageHead) || page.contains(String(text.prefix(8))) {
                return Array(segments[index...])
            }
        }
        return segments
    }

    private static func compactText(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    private func startSpeech(_ segments: [ReaderSpeech.Segment], rate: Double) {
        guard !segments.isEmpty else { return }
        tts.speak(
            segments,
            rate: rate,
            onStart: { segment in
                guard !segment.cfi.isEmpty else { return }
                // 读到哪句就把页面跟到哪句（同页不动，换页才翻），否则高亮画在屏幕外。
                controller.evaluate(
                    "window.followTTSLocation && window.followTTSLocation(\(Self.jsString(segment.cfi)))"
                )
                controller.send([
                    "type": "setTTSHighlight",
                    "cfi": segment.cfi,
                    "color": Self.ttsHighlightHex,
                ])
            },
            onFinish: {
                controller.send(["type": "clearTTSHighlight"])
            }
        )
    }

    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8),
              json.count >= 2
        else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    private func saveHighlight(_ selection: ReaderSelection, color: (name: String, hex: String)) {
        guard let book = reading.book else { return }
        settings.highlightColor = color.name
        let payload: [String: Any] = [
            "bookId": book.id,
            "cfi": selection.cfi,
            "text": selection.text,
            "color": color.name,
            "chapterTitle": reading.chapterTitle,
        ]
        let saved = runtime.appJSONOr("ShudengApp.addHighlight(\(json(payload)))", fallback: "", timeout: 20)
        guard let data = saved.data(using: .utf8),
              let item = try? JSONDecoder().decode(HighlightItem.self, from: data),
              item.bookId == book.id, item.cfi == selection.cfi else {
            flash("高亮没保存上，再试一次")
            return
        }
        reading.markDirty()
        controller.send([
            "type": "addAnnotation",
            "annotation": ["value": selection.cfi, "type": "highlight", "color": color.hex],
        ])
        self.selection = nil
        controller.send(["type": "clearSelection"])
        flash("已高亮")
    }

    private func showAnnotation(cfi: String) {
        guard !showNoteEditor, !cfi.isEmpty, let book = reading.book else { return }
        let raw = runtime.appJSONOr("ShudengApp.listHighlights(\(json(["bookId": book.id])))", fallback: "", timeout: 20)
        guard let data = raw.data(using: .utf8),
              let items = try? JSONDecoder().decode([HighlightItem].self, from: data),
              let item = items.last(where: { $0.bookId == book.id && $0.cfi == cfi }) else {
            flash("标注读取失败，再试一次")
            return
        }
        editingAnnotation = item
        noteTarget = ReaderSelection(text: item.text, cfi: item.cfi)
        restoreNoteDraft(original: item.note ?? "")
        noteError = nil
        showNoteEditor = true
    }

    private func restoreNoteDraft(original: String) {
        noteOriginal = original
        noteDraft = original
        noteDraftRestored = false
        noteDraftError = nil
        guard let book = reading.book, let target = noteTarget else { return }
        do {
            if let restored = try NoteDrafts.restore(bookId: book.id, cfi: target.cfi, original: original) {
                noteDraft = restored
                noteDraftRestored = true
            }
        } catch {
            noteDraftError = "草稿读取失败，已保存的笔记不受影响。"
        }
    }

    private func discardNoteDraft() -> Bool {
        guard let book = reading.book, let target = noteTarget else { return true }
        do {
            try NoteDrafts.discard(bookId: book.id, cfi: target.cfi)
            noteDraftError = nil
            noteDraftRestored = false
            return true
        } catch {
            noteDraftError = "草稿暂时无法清理，请重试。"
            return false
        }
    }

    private func deleteAnnotation() {
        guard let item = editingAnnotation, item.bookId == reading.book?.id else { return }
        guard discardNoteDraft() else { return }
        let result = runtime.appJSONOr("ShudengApp.deleteHighlight(\(json(["id": item.id])))", fallback: "", timeout: 20)
        guard result == "ok" else {
            do {
                try NoteDrafts.preserve(bookId: item.bookId, cfi: item.cfi, original: noteOriginal, text: noteDraft)
            } catch {
                noteDraftError = "草稿暂时无法保留，离开前请保存笔记。"
            }
            noteError = "标注没能删除，请重试。"
            return
        }
        reading.markDirty()
        controller.send(["type": "removeAnnotation", "annotation": ["value": item.cfi, "type": "highlight"]])
        editingAnnotation = nil
        noteTarget = nil
        noteDraft = ""
        noteError = nil
        showNoteEditor = false
        loadAnnotations()
        flash("已删除标注")
    }

    private func saveNote() {
        // 用打开弹窗时存下来的那一段：弹窗和键盘一出现，页面里的选中十有八九已经被系统收掉了。
        guard let book = reading.book, let target = noteTarget ?? selection else { return }
        let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let color = editingAnnotation?.color ?? settings.highlightColor
        if let item = editingAnnotation {
            guard item.bookId == book.id, item.cfi == target.cfi else { return }
            let result = runtime.appJSONOr("ShudengApp.updateHighlight(\(json(["id": item.id, "note": text])))", fallback: "", timeout: 20)
            guard result == "ok" else {
                noteError = "笔记没能保存，请检查存储空间后重试。"
                return
            }
        } else {
            let payload: [String: Any] = [
                "bookId": book.id,
                "cfi": target.cfi,
                "text": target.text,
                "color": settings.highlightColor,
                "note": text,
                "chapterTitle": reading.chapterTitle,
            ]
            let saved = runtime.appJSONOr("ShudengApp.addHighlight(\(json(payload)))", fallback: "", timeout: 20)
            guard let data = saved.data(using: .utf8),
                  let item = try? JSONDecoder().decode(HighlightItem.self, from: data),
                  item.bookId == book.id, item.cfi == target.cfi else {
                noteError = "笔记没能保存，请检查存储空间后重试。"
                return
            }
            editingAnnotation = item
        }
        noteOriginal = text
        reading.markDirty()
        guard discardNoteDraft() else { return }
        controller.send([
            "type": "addAnnotation",
            "annotation": [
                "value": target.cfi,
                "type": "highlight",
                "color": highlightColors.first { $0.name == color }?.hex ?? "#facc15",
                "note": text,
            ],
        ])
        self.selection = nil
        editingAnnotation = nil
        noteTarget = nil
        noteDraft = ""
        noteError = nil
        showNoteEditor = false
        controller.send(["type": "clearSelection"])
        flash("笔记已保存")
    }

    /// 选中文本翻译：中文选段译成英文，其它语言译成中文。
    private func translate(_ selection: ReaderSelection) {
        guard aiSettings.isConfigured else {
            flash("先在设置里配 AI 端点")
            return
        }
        translationGeneration += 1
        let generation = translationGeneration
        translationSource = selection.text
        translatedText = nil
        isTranslating = true
        showTranslation = true

        let payload: [String: Any] = [
            "text": selection.text,
            "targetLang": Self.containsCJK(selection.text) ? "en" : "zh",
            "provider": aiSettings.provider.rawValue,
            "baseUrl": aiSettings.baseURL,
            "apiKey": aiSettings.apiKey,
            "model": aiSettings.model,
        ]
        let expression = "ShudengApp.translate(\(json(payload)))"
        // 翻译要打网络：走非阻塞的异步通道，不能在主队列 block 里等 Promise
        //（宿主把网络回调派回主队列，主队列被堵着的话结果永远回不来，界面会一直「正在翻译…」）。
        runtime.callAsync(expression) { raw in
            guard generation == translationGeneration else { return }
            isTranslating = false
            guard let data = raw.data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                translatedText = "翻译没成功，再试一次"
                return
            }
            if let error = result["error"] as? String, !error.isEmpty {
                translatedText = "翻译失败：\(error)"
                return
            }
            let text = result["translated"] as? String ?? ""
            translatedText = text.isEmpty ? "没有拿到译文，再试一次" : text
        }
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    /// 加 / 删当前页书签。阅读器里的下拉手势和底栏按钮都走这里。
    private func toggleBookmark() {
        guard let book = reading.book, !reading.cfi.isEmpty else { return }
        if let existing = bookmarks.first(where: { $0.cfi == reading.cfi }) {
            do {
                guard try runtime.appJSON("ShudengApp.deleteBookmark(\(json(["id": existing.id])))", timeout: 20) == "ok" else {
                    throw NSError(domain: "BookmarkPersistence", code: 1)
                }
            } catch {
                flash("书签没能删除，再试一次")
                return
            }
            bookmarks.removeAll { $0.id == existing.id }
            reading.markDirty()
            syncBookmarkPullState()
            flash("已删除书签")
            return
        }
        let payload: [String: Any] = [
            "bookId": book.id,
            "cfi": reading.cfi,
            "label": "\(Int(reading.fraction * 100))%",
            "chapterTitle": reading.chapterTitle,
        ]
        let saved = runtime.appJSONOr("ShudengApp.addBookmark(\(json(payload)))", fallback: "", timeout: 20)
        guard let item = decodeBookmark(saved),
              item.bookId == book.id, item.cfi == reading.cfi else {
            flash("书签没保存上，再试一次")
            return
        }
        bookmarks.append(item)
        reading.markDirty()
        syncBookmarkPullState()
        flash("已加书签")
    }

    /// 把「当前页是否已加书签」回传 reader.html，下拉手势的文案才会跟着变。
    private func syncBookmarkPullState(force: Bool = false) {
        let value = isBookmarked
        if !force, value == pushedBookmarkState { return }
        pushedBookmarkState = value
        controller.send(["type": "setBookmarkPullState", "bookmarked": value])
    }

    private func decodeBookmark(_ raw: String) -> BookmarkItem? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BookmarkItem.self, from: data)
    }

    private func flash(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if toast == text { toast = nil }
        }
    }

    /// 整章正文：reader.html 把当前 section 的段落回推过来（思维导图、技能、整章翻译要用）。
    /// 只在换章时抽一次；新章的排版比 relocate 事件晚一点，等一会儿再抽免得拿到上一章。
    private func requestChapterText(section: Int) {
        guard let book = reading.book, !book.filePath.lowercased().hasSuffix(".pdf") else { return }
        if section >= 0, section == chapterTextSection { return }
        chapterTextSection = section
        chapterTextTask?.cancel()
        chapterTextTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            controller.evaluate("window.doGetChapterParagraphs && window.doGetChapterParagraphs()")
        }
    }

    private func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - WebView 事件

    private func handle(event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "loaded":
            isLoading = false
            pushTheme()
            loadAnnotations()
            loadBookmarks(force: true)
            requestChapterText(section: -1)
            // 语义检索回跳：索引里没 cfi，让阅读器按原文片段自己搜。
            if let snippet = reading.pendingSnippet, !snippet.isEmpty {
                reading.pendingSnippet = nil
                reading.pendingLocation = nil
                controller.send(["type": "goToText", "text": snippet])
            } else {
                reading.pendingLocation = nil
            }
        case "error":
            isLoading = false
            flash(event["message"] as? String ?? "阅读器出错")
        case "toc":
            if let items = event["items"] as? [[String: Any]] {
                toc = ReaderTOCItem.parse(items).flatMap(\.flattened)
            }
        case "relocate":
            let fraction = event["fraction"] as? Double ?? 0
            let cfi = event["cfi"] as? String ?? ""
            // reader.html 的 page 是 { current, total }；早期版本才是裸数字。
            var page = event["page"] as? Int ?? 0
            var pages = 0
            if let info = event["page"] as? [String: Any] {
                page = info["current"] as? Int ?? 0
                pages = info["total"] as? Int ?? 0
            }
            var chapter = ""
            if let tocItem = event["tocItem"] as? [String: Any], let label = tocItem["label"] as? String {
                chapter = label
            }
            var section = 0
            var total = 0
            if let info = event["section"] as? [String: Any] {
                section = info["current"] as? Int ?? 0
                total = info["total"] as? Int ?? 0
            }
            sliderFraction = fraction
            pageIndex = page
            pageTotal = pages
            sectionIndex = section
            sectionTotal = total
            if let time = event["time"] as? [String: Any] {
                remainingMinutes = time["total"] as? Double ?? 0
            }
            reading.updateProgress(fraction: fraction, cfi: cfi, chapter: chapter, page: page, scrollResume: event["scrollResume"] as? String)
            requestChapterText(section: section)
            syncBookmarkPullState()
        case "chapterParagraphs":
            // 整章正文（思维导图 / 技能要用）：段落拼起来存进阅读会话。
            if let section = event["section"] as? Int, section != sectionIndex { return }
            let paragraphs = event["paragraphs"] as? [[String: Any]] ?? []
            let text = paragraphs
                .compactMap { $0["text"] as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            if !text.isEmpty { reading.setChapterText(text) }
        case "toggleBookmark":
            // reader.html 的下拉手势：拉到头松手就来这里加 / 删书签。
            toggleBookmark()
        case "show-annotation":
            showAnnotation(cfi: event["value"] as? String ?? "")
        case "note-tooltip":
            showAnnotation(cfi: event["cfi"] as? String ?? "")
        case "selection":
            let text = event["text"] as? String ?? ""
            let cfi = event["cfi"] as? String ?? ""
            reading.setSelection(text: text, cfi: cfi)
            selection = ReaderSelection(text: text, cfi: cfi)
            showControls = true
        case "selectionCleared":
            selection = nil
            reading.setSelection(text: "", cfi: "")
        case "tap":
            if selection == nil { showControls.toggle() }
        case "searchComplete":
            searchCount = event["count"] as? Int ?? 0
            searchIndex = 0
        case "searchResult":
            searchIndex = event["index"] as? Int ?? 0
            searchCount = event["count"] as? Int ?? searchCount
        case "visibleText":
            reading.setVisibleText(event["text"] as? String ?? "")
        case "visibleTTSSegments":
            // 朗读分段（句子级）回来了：只有当前那条「要开始读」的请求认领它。
            let segments = (event["segments"] as? [[String: Any]] ?? []).compactMap { row -> ReaderSpeech.Segment? in
                let text = (row["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return ReaderSpeech.Segment(text: text, cfi: row["cfi"] as? String ?? "")
            }
            ttsRequester.resume(requestID: event["requestId"] as? String ?? "", segments: segments)
        default:
            break
        }
    }

    private func loadAnnotations() {
        guard let book = reading.book, runtime.state == .ready else { return }
        let payload = ["bookId": book.id]
        let raw = runtime.appJSONOr("ShudengApp.listHighlights(\(json(payload)))", fallback: "[]", timeout: 30)
        guard let data = raw.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }

        reading.setRecentHighlights(rows.compactMap { $0["text"] as? String })

        for row in rows {
            guard let cfi = row["cfi"] as? String, !cfi.isEmpty else { continue }
            let colorName = row["color"] as? String ?? "yellow"
            let hex = highlightColors.first { $0.name == colorName }?.hex ?? "#facc15"
            var annotation: [String: Any] = ["value": cfi, "type": "highlight", "color": hex]
            if let note = row["note"] as? String, !note.isEmpty { annotation["note"] = note }
            controller.send(["type": "addAnnotation", "annotation": annotation])
        }
    }

    private func loadBookmarks(force: Bool = false) {
        guard let book = reading.book, runtime.state == .ready else { return }
        let payload = ["bookId": book.id]
        let raw = runtime.appJSONOr("ShudengApp.listBookmarks(\(json(payload)))", fallback: "[]", timeout: 30)
        guard let data = raw.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        bookmarks = rows.compactMap { row in
            guard let itemData = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            return try? JSONDecoder().decode(BookmarkItem.self, from: itemData)
        }
        syncBookmarkPullState(force: force)
    }
}

extension ReaderTOCItem {
    /// 展平成一维列表（目录面板按 level 缩进，避免 View 递归）。
    var flattened: [ReaderTOCItem] {
        var result = [self]
        for child in children {
            result.append(contentsOf: child.flattened)
        }
        return result
    }

    static func parse(_ items: [[String: Any]]) -> [ReaderTOCItem] {
        items.compactMap { item in
            guard let title = item["title"] as? String else { return nil }
            let id = item["id"] as? String ?? title
            let level = item["level"] as? Int ?? 0
            let href = item["href"] as? String
            let children = (item["subitems"] as? [[String: Any]]).map { parse($0) } ?? []
            return ReaderTOCItem(
                id: id,
                title: title,
                level: level,
                href: href,
                subitems: children.isEmpty ? nil : children
            )
        }
    }
}

/// 跟读用的朗读分段请求：reader.html 是异步回消息（visibleTTSSegments），
/// 这里用 requestId + continuation 把它包成 async；超时（PDF / 引擎没就绪）就当拿不到，
/// 交给调用方退回整页朗读。
@MainActor
final class TTSSegmentRequester: ObservableObject {
    private var waiters: [String: CheckedContinuation<[ReaderSpeech.Segment], Never>] = [:]

    func request(_ send: (String) -> Void, timeout: TimeInterval = 4) async -> [ReaderSpeech.Segment] {
        let requestID = UUID().uuidString
        let watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            resume(requestID: requestID, segments: [])
        }
        let segments = await withCheckedContinuation { continuation in
            waiters[requestID] = continuation
            send(requestID)
        }
        watchdog.cancel()
        return segments
    }

    /// reader.html 回消息时调用；requestId 对不上（已经超时）的那条丢掉。
    func resume(requestID: String, segments: [ReaderSpeech.Segment]) {
        guard let continuation = waiters.removeValue(forKey: requestID) else { return }
        continuation.resume(returning: segments)
    }
}

/// 系统 TTS：朗读当前页正文。
@MainActor
final class ReaderSpeech: ObservableObject {
    /// 一段可朗读的文字；cfi 为空表示这段定位不到原文（整页朗读兜底路径）。
    struct Segment: Equatable {
        let text: String
        let cfi: String
    }

    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private var delegate: SpeechDelegate?
    /// 还排着队没读完的段落数，读完最后一段才算结束。
    private var pending = 0
    private var segmentByUtterance: [ObjectIdentifier: Segment] = [:]
    private var onSegmentStart: ((Segment) -> Void)?
    private var onAllFinished: (() -> Void)?

    init() {
        let delegate = SpeechDelegate()
        delegate.onFinish = { [weak self] in self?.finishOne() }
        delegate.onCancel = { [weak self] in self?.finishAll() }
        delegate.onStart = { [weak self] utterance in self?.startUtterance(utterance) }
        self.delegate = delegate
        synthesizer.delegate = delegate
    }

    /// 按段排队朗读：每段开始时回调一次（用来把高亮移到"正在读的那句"）。
    func speak(
        _ segments: [Segment],
        rate: Double,
        onStart: @escaping (Segment) -> Void,
        onFinish: @escaping () -> Void
    ) {
        let usable = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return }
        stop()
        pending = usable.count
        onSegmentStart = onStart
        onAllFinished = onFinish
        segmentByUtterance = [:]
        for segment in usable {
            let utterance = AVSpeechUtterance(string: segment.text)
            utterance.rate = Float(max(0.3, min(0.7, rate)))
            segmentByUtterance[ObjectIdentifier(utterance)] = segment
            synthesizer.speak(utterance)
        }
        isSpeaking = true
    }

    func stop() {
        pending = 0
        segmentByUtterance = [:]
        onSegmentStart = nil
        onAllFinished = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    /// 试听一整段文本（设置页用）：切成句子排队，不需要跟读高亮。
    func speak(_ text: String, rate: Double) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speak(
            Self.chunk(trimmed).map { Segment(text: $0, cfi: "") },
            rate: rate,
            onStart: { _ in },
            onFinish: {}
        )
    }

    private func startUtterance(_ utterance: AVSpeechUtterance) {
        guard let segment = segmentByUtterance[ObjectIdentifier(utterance)] else { return }
        onSegmentStart?(segment)
    }

    private func finishOne() {
        pending = max(0, pending - 1)
        if pending == 0 {
            isSpeaking = false
            segmentByUtterance = [:]
            let done = onAllFinished
            onAllFinished = nil
            onSegmentStart = nil
            done?()
        }
    }

    private func finishAll() {
        // 上一次 stop 的 cancel 回调可能晚于新队列到达，队列还在时不能清状态。
        if synthesizer.isSpeaking { return }
        pending = 0
        segmentByUtterance = [:]
        onSegmentStart = nil
        onAllFinished = nil
        isSpeaking = false
    }

    /// 按句子边界切块，单块不超过 limit 字。
    static func chunk(_ text: String, limit: Int = 800) -> [String] {
        var chunks: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            let isSentenceEnd = "。！？!?；;\n".contains(character)
            if isSentenceEnd && current.count >= limit / 2 {
                chunks.append(current)
                current = ""
            } else if current.count >= limit {
                chunks.append(current)
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }
        return chunks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    var onStart: ((AVSpeechUtterance) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onStart?(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onCancel?()
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value & 0xFF0000) >> 16) / 255
        let green = Double((value & 0x00FF00) >> 8) / 255
        let blue = Double(value & 0x0000FF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

/// 选中文字后 iOS 会再弹一个系统编辑菜单（Copy / Translate / Learn / Share），跟书灯自己的选中工具栏重复。
/// reader.html 里的 `-webkit-touch-callout` 只压得掉长按 callout，压不掉编辑菜单，只能在 responder 链上拦。
final class ReaderWebView: WKWebView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }
}

/// WKWebView 承载 foliate-js。reader.html 来自 App Bundle，书的字节由 Swift 读出来注入。
struct FoliateWebView: UIViewRepresentable {
    let rootDirectory: URL
    let book: LibraryStore.Book
    var pageMargin: Double = 20
    let initialSettingsJSON: String
    let initialLocation: String?
    @Binding var isLoading: Bool
    let controller: ReaderController
    let onEvent: ([String: Any]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            rootDirectory: rootDirectory,
            pageMargin: pageMargin,
            initialSettingsJSON: initialSettingsJSON,
            initialLocation: initialLocation,
            isLoading: $isLoading,
            controller: controller,
            onEvent: onEvent
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "shudeng")
        userContent.addUserScript(
            WKUserScript(
                source: """
                window.ReactNativeWebView = {
                  postMessage: (payload) => window.webkit.messageHandlers.shudeng.postMessage(payload),
                };
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContent
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true

        let webView = ReaderWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        if let url = Bundle.main.url(forResource: "reader", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        context.coordinator.attach(webView)
        controller.webView = webView
        context.coordinator.setBook(book)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        controller.webView = webView
        context.coordinator.updateConfiguration(pageMargin: pageMargin, settingsJSON: initialSettingsJSON, location: initialLocation)
        context.coordinator.setBook(book)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private weak var webView: WKWebView?
        private let rootDirectory: URL
        private var pageMargin: Double
        private var initialSettingsJSON: String
        private var initialLocation: String?
        private let isLoading: Binding<Bool>
        private let controller: ReaderController
        private let onEvent: ([String: Any]) -> Void
        private var readerReady = false
        private var pendingBook: LibraryStore.Book?
        private var injectedBookID: String?
        private var loadingBookID: String?
        private var textTimer: Timer?
        private var visibleTextAttempts = 0
        private let ioQueue = DispatchQueue(label: "com.wangxinxin.readany.reader-io", qos: .userInitiated)

        init(
            rootDirectory: URL,
            pageMargin: Double,
            initialSettingsJSON: String,
            initialLocation: String?,
            isLoading: Binding<Bool>,
            controller: ReaderController,
            onEvent: @escaping ([String: Any]) -> Void
        ) {
            self.rootDirectory = rootDirectory
            self.pageMargin = pageMargin
            self.initialSettingsJSON = initialSettingsJSON
            self.initialLocation = initialLocation
            self.isLoading = isLoading
            self.controller = controller
            self.onEvent = onEvent
        }

        func updateConfiguration(pageMargin: Double, settingsJSON: String, location: String?) {
            self.pageMargin = pageMargin
            initialSettingsJSON = settingsJSON
            initialLocation = location
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func setBook(_ book: LibraryStore.Book?) {
            pendingBook = book
            openIfNeeded()
        }

        /// 读文件 + base64 放到后台线程：几十兆的书在主线程读会把界面冻住。
        private func openIfNeeded() {
            guard readerReady, let book = pendingBook, book.id != injectedBookID else { return }
            guard loadingBookID != book.id else { return }
            let url = rootDirectory.appendingPathComponent(book.filePath)
            let mimeType = book.filePath.lowercased().hasSuffix(".pdf") ? "application/pdf" : "application/epub+zip"
            let margin = pageMargin
            let openingSettings = initialSettingsJSON
            let resumeCFI = initialLocation ?? ""
            let scrollResume = book.scrollResume ?? ""
            loadingBookID = book.id

            ioQueue.async { [weak self] in
                let data = try? Data(contentsOf: url)
                let base64 = data?.base64EncodedString()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.loadingBookID = nil
                    // 等待期间书被换掉了，这次读出来的结果就作废。
                    guard self.pendingBook?.id == book.id else { return }
                    guard let base64 else {
                        self.isLoading.wrappedValue = false
                        self.onEvent(["type": "error", "message": "这本书的文件读不出来，重新导入试试"])
                        return
                    }
                    self.injectedBookID = book.id
                    self.textTimer?.invalidate()
                    // loaded 会在首个章节加载时提前回传；设置和位置随 openBook 一起传入，
                    // 避免初始化回到开头与宿主的续读跳转并发执行。
                    let script = """
                    window.handleCommand({
                      type: 'openBook',
                      base64: '\(base64)',
                      fileName: '\(Self.jsStringLiteral(book.filePath))',
                      mimeType: '\(mimeType)',
                      pageMargin: \(margin),
                      settings: \(openingSettings),
                      lastLocation: '\(Self.jsStringLiteral(resumeCFI))',
                      scrollResume: '\(Self.jsStringLiteral(scrollResume))',
                    });
                    """
                    self.webView?.evaluateJavaScript(script)
                }
            }
        }

        /// 拼进 JS 单引号字符串前转义：旧版 ReadAny 的书路径可能带引号 / 反斜杠。
        private static func jsStringLiteral(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
        }

        /// 页面对齐 / 翻页后把当前页正文交给 Swift，AI 提问时当上下文。
        private func scheduleVisibleTextPull() {
            textTimer?.invalidate()
            visibleTextAttempts = 0
            textTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.pullVisibleText()
            }
        }

        private func pullVisibleText() {
            guard readerReady, injectedBookID != nil else { return }
            // window.getVisibleText() 自己就返回 JSON 字符串，这里不能再套一层 JSON.stringify，
            // 否则拿到的是「JSON 字符串的字符串」，解析必然失败 → TTS / AI 上下文永远是空的。
            webView?.evaluateJavaScript("window.getVisibleText && window.getVisibleText()") { [weak self] result, _ in
                guard let self else { return }
                var text: String?
                if let json = result as? String,
                   let data = json.data(using: .utf8),
                   let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    text = payload["text"] as? String
                } else if let payload = result as? [String: Any] {
                    text = payload["text"] as? String
                }
                let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty {
                    visibleTextAttempts = 0
                    onEvent(["type": "visibleText", "text": String(trimmed.prefix(20_000))])
                    return
                }
                // 真机上分页渲染比桌面慢：正文还没就绪就重试，否则 TTS / AI 上下文会空一整页。
                guard visibleTextAttempts < 10 else { return }
                visibleTextAttempts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.pullVisibleText()
                }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let payload = message.body as? String,
                  let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            else { return }

            let type = event["type"] as? String ?? ""
            if type == "foliate-loaded" {
                readerReady = true
                openIfNeeded()
                return
            }
            if type == "loaded" || type == "error" {
                isLoading.wrappedValue = false
            }
            if type == "relocate" || type == "loaded" {
                scheduleVisibleTextPull()
            }
            onEvent(event)
        }
    }
}
