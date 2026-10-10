// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var runtime: RuntimeHost
    @EnvironmentObject private var reading: ReadingSession
    @EnvironmentObject private var settings: AISettings
    @EnvironmentObject private var chat: ChatService
    @StateObject private var library = LibraryStore()

    @State private var draft = ""
    @State private var showSettings = false
    @State private var showBookPicker = false
    @State private var skills: [AISkill] = []
    /// 点了「需要输入」的技能后，先挂在这里，等用户在输入框里补上对象再发。
    @State private var pendingSkill: AISkill?
    @State private var showMindMap = false
    /// 折起来 / 展开的思考过程（按消息 id 记）。
    @State private var expandedThinking: Set<String> = []
    /// 输入框的焦点：键盘上的「收起」和点正文都要能把它放掉。
    @FocusState private var inputFocused: Bool

    var body: some View {
        transcript
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let error = chat.error {
                    errorBanner(error)
                }
                composer
            }
        }
        // AI 栏里是 push 进来的（标题＝这段对话），阅读器里是 sheet。
        .navigationTitle(chat.activeThreadTitle ?? "AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                skillMenu
                Menu {
                    Button("清空对话", systemImage: "trash") { chat.clear() }
                        .disabled(chat.messages.isEmpty)
                        .accessibilityIdentifier("chat.clear")
                    Button("AI 设置", systemImage: "gearshape", action: openSettings)
                        .accessibilityIdentifier("chat.settings")
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("chat.more")
            }
        }
        .sheet(isPresented: $showSettings) {
            AISettingsView().environmentObject(settings)
        }
        .sheet(isPresented: $showBookPicker) {
            BookPickerSheet(
                books: library.books,
                selectedBookId: chat.activeBookId
            ) { bookId in
                chat.setBook(bookId, using: runtime)
            }
        }
        .sheet(isPresented: $showMindMap) { MindMapSheet(bookId: activeBook?.id) }
        .task {
            chat.attach(to: runtime)
            library.refresh(using: runtime)
            loadSkills()
        }
        .onChange(of: runtime.state) { _, _ in
            chat.attach(to: runtime)
            library.refresh(using: runtime)
            loadSkills()
        }
    }

/// 阅读器里弹出的对话：sheet 里没有导航栏，给它一层导航栈。
struct ChatSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChatView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { dismiss() }
                            .accessibilityIdentifier("reader.chat.close")
                    }
                }
        }
    }
}

    private func loadSkills() {
        guard runtime.state == .ready, skills.isEmpty else { return }
        skills = AISkill.load(
            using: runtime,
            // 书灯没有 .lproj，中文机器上 Locale.current 会被判成 en，技能名会变英文。
            language: HostEnvironment.deviceLocaleIdentifier()
        )
    }

    /// 点技能：要输入对象的先挂上等用户补，其余的直接按当前阅读位置开问。
    private func run(_ skill: AISkill) {
        guard settings.isConfigured else { openSettings(); return }
        if skill.requiresInput {
            pendingSkill = skill
            return
        }
        pendingSkill = nil
        let prompt = skill.desc.isEmpty ? skill.name : skill.desc
        let book = activeBook ?? reading.book
        chat.send(
            prompt,
            book: book,
            contextText: book?.id == reading.book?.id ? reading.promptContext : nil,
            settings: settings,
            skill: skill
        )
    }

    /// 「技能」菜单：core 的 8 个内置技能 + 思维导图。
    private var skillMenu: some View {
        Menu {
            Button {
                showMindMap = true
            } label: {
                Label("思维导图", systemImage: "flowchart")
            }
            .accessibilityIdentifier("chat.skill.mindmap")
            if !skills.isEmpty {
                Divider()
                ForEach(skills) { skill in
                    Button {
                        run(skill)
                    } label: {
                        Label(skill.name, systemImage: pendingSkill?.id == skill.id ? "checkmark" : "sparkles")
                    }
                    // 菜单项默认拿 SF Symbol 名当无障碍标识，显式覆盖成技能 id，UI 测试才找得到。
                    .accessibilityIdentifier("chat.skill.\(skill.id)")
                }
            }
        } label: {
            Label("技能", systemImage: "wand.and.stars")
        }
        .disabled(skills.isEmpty)
        .accessibilityIdentifier("chat.skills")
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if chat.messages.isEmpty {
                        hint
                    }
                    ForEach(chat.messages) { message in
                        bubble(message).id(message.id)
                    }
                    if chat.isStreaming {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在生成…").font(.caption).foregroundStyle(.secondary)
                        }
                        .id("streaming")
                        .accessibilityIdentifier("chat.streaming")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: chat.messages.last?.text) { _, _ in
                // 流式更新时直接定位；逐 token 动画会与懒列表的高度更新反复触发布局。
                if chat.isStreaming {
                    proxy.scrollTo("streaming", anchor: .bottom)
                } else if let last = chat.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            // 键盘收不回去是最招人烦的：往下拖正文收、点正文也收。
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { inputFocused = false })
        }
    }

    /// 新对话就是一张白纸：上下文由输入框上方的 chip 交代，这里只说必须说的事。
    private var hint: some View {
        VStack(alignment: .leading, spacing: 10) {
            if runtime.state != .ready {
                Text("AI 内核未就绪：\(stateText)").font(.footnote).foregroundStyle(.secondary)
            } else if !settings.isConfigured {
                Text("先连接你的 AI 服务").font(.headline)
                Text("填好服务地址和模型后，就能讨论书中的内容。你写的提问会保留在这里。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let issue = settings.configurationIssue {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                    Text(issue).font(.footnote)
                    Spacer(minLength: 0)
                    Button("去设置", action: openSettings)
                        .accessibilityIdentifier("chat.configureAI")
                }
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            }
            if let note = chat.contextNote {
                HStack(spacing: 6) {
                    Image(systemName: "text.magnifyingglass").font(.caption2)
                    Text(note)
                        .font(.caption2)
                        .lineLimit(1)
                        .accessibilityIdentifier("chat.contextNote")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if reading.book != nil, !reading.contextPreview.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "text.viewfinder").font(.caption2)
                    Text(reading.contextPreview)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let skill = pendingSkill {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars").font(.caption2)
                    Text("\(skill.name)：\(skill.needsInput ?? "补一句要处理的内容")")
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        pendingSkill = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption)
                    }
                    .accessibilityIdentifier("chat.skillCancel")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("chat.skillChip")
            }
            HStack {
                bookChip
                if inputFocused {
                    Button { inputFocused = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .frame(width: 44, height: 36)
                            .contentShape(Rectangle())
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("收起键盘")
                    .accessibilityIdentifier("chat.dismissKeyboard")
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(pendingSkill?.needsInput ?? (activeBook == nil ? "随便问点什么…" : "问这本书…"), text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .accessibilityIdentifier("chat.input")

                if chat.isStreaming {
                    Button {
                        chat.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.title)
                    }
                    .tint(.secondary)
                    .accessibilityIdentifier("chat.stop")
                } else {
                    Button {
                        guard settings.isConfigured else { openSettings(); return }
                        let text = draft
                        if chat.send(
                            text,
                            book: activeBook,
                            contextText: contextForSend,
                            settings: settings,
                            skill: pendingSkill
                        ) {
                            draft = ""
                            pendingSkill = nil
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                            .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiaryLabel)))
                    }
                    .accessibilityIdentifier("chat.send")
                    .disabled(!canSend)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }

    private func openSettings() {
        inputFocused = false
        showSettings = true
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 这段对话挂在哪本书上；没挂书就是「临时对话」。
    private var activeBook: LibraryStore.Book? {
        guard let id = chat.activeBookId else { return nil }
        return library.books.first { $0.id == id }
    }

    /// 只有绑定的就是正在翻的这本书，才把当前页正文和选中的原文带上。
    private var contextForSend: String? {
        guard let activeBook, activeBook.id == reading.book?.id else { return nil }
        return reading.promptContext
    }

    /// 输入框上方的上下文 chip：点开换书，或者退回临时对话。
    private var bookChip: some View {
        Button {
            showBookPicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: activeBook == nil ? "bubble.left" : "book")
                    .font(.caption2)
                Text(activeBook?.title ?? "临时对话")
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.bookChip")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).font(.footnote).lineLimit(4)
            Spacer(minLength: 0)
            if chat.hasUnsavedReply {
                Button("重试保存") { chat.retryPendingReply() }
                    .accessibilityIdentifier("chat.retrySave")
            } else if !settings.isConfigured {
                Button("去设置", action: openSettings)
            } else if chat.canRetryResponse {
                Button("重试") { chat.retryResponse(settings: settings) }
                    .accessibilityIdentifier("chat.retryResponse")
                    .fixedSize()
            } else {
                Button("知道了") { chat.error = nil }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.15))
    }

    private func bubble(_ message: ChatService.Message) -> some View {
        Group {
            if message.role == .user {
                HStack {
                    Spacer(minLength: 56)
                    Group {
                        if message.text.isEmpty {
                            Text("…").foregroundStyle(Color(.systemBackground).opacity(0.7))
                        } else {
                            MarkdownText(text: message.text, streaming: isLastAndStreaming(message))
                        }
                    }
                    .font(.body)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(Color(.label), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(Color(.systemBackground))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("chat.userBubble")
                }
            } else {
                // 助手的回答不套气泡：正文直接排在页面上，像系统自己的智能回复。
                VStack(alignment: .leading, spacing: 10) {
                    if !message.reasoning.isEmpty {
                        thinkingRow(message)
                    }
                    Group {
                        if message.text.isEmpty {
                            Text("…").foregroundStyle(.secondary)
                        } else {
                            MarkdownText(text: message.text, streaming: isLastAndStreaming(message))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("chat.assistantBubble")
                }
                .padding(.trailing, 24)
            }
        }
    }

    /// 思考过程默认折起来，只留一条「已思考 N 秒」；点开才看推理正文。
    private func thinkingRow(_ message: ChatService.Message) -> some View {
        let expanded = expandedThinking.contains(message.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if expanded {
                        expandedThinking.remove(message.id)
                    } else {
                        expandedThinking.insert(message.id)
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(thinkingLabel(message))
                        .font(.caption)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.thinking")

            if expanded {
                Text(message.reasoning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.hairline).frame(width: 2)
                    }
                    .accessibilityIdentifier("chat.thinkingText")
            }
        }
    }

    private func thinkingLabel(_ message: ChatService.Message) -> String {
        if chat.isStreaming, isLastAndStreaming(message) {
            return "正在思考…"
        }
        if let seconds = message.thinkingSeconds {
            return "已思考 \(max(1, Int(seconds.rounded()))) 秒"
        }
        return "思考过程"
    }

    private var stateText: String {
        switch runtime.state {
        case .failed(let message): message
        case .idle, .loading: "加载中"
        case .ready: "已就绪"
        }
    }

    /// 正在流式输出的那条（只有它会一直变形）。
    private func isLastAndStreaming(_ message: ChatService.Message) -> Bool {
        chat.isStreaming && message.id == chat.messages.last?.id
    }
}
