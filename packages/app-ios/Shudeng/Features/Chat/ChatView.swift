// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var runtime: RuntimeHost
    @EnvironmentObject private var reading: ReadingSession
    @EnvironmentObject private var settings: AISettings
    @EnvironmentObject private var chat: ChatService

    @State private var draft = ""
    @State private var showSettings = false
    @State private var showThreads = false
    @State private var skills: [AISkill] = []
    /// 点了「需要输入」的技能后，先挂在这里，等用户在输入框里补上对象再发。
    @State private var pendingSkill: AISkill?
    @State private var showMindMap = false
    /// 折起来 / 展开的思考过程（按消息 id 记）。
    @State private var expandedThinking: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if let error = chat.error {
                errorBanner(error)
            }
            composer
        }
        // AI 栏里是 push 进来的（标题＝这段对话），阅读器里是 sheet。
        .navigationTitle(chat.activeThreadTitle ?? "AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let book = reading.book {
                    Text(book.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("会话", systemImage: "bubble.left.and.bubble.right") { showThreads = true }
                    .accessibilityIdentifier("chat.threads")
                skillMenu
                Menu {
                    Button("清空对话", systemImage: "trash") { chat.clear() }
                        .disabled(chat.messages.isEmpty)
                        .accessibilityIdentifier("chat.clear")
                    Button("AI 设置", systemImage: "gearshape") { showSettings = true }
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
        .sheet(isPresented: $showThreads) { threadList }
        .sheet(isPresented: $showMindMap) { MindMapSheet() }
        .task {
            chat.attach(to: runtime)
            loadSkills()
        }
        .onChange(of: runtime.state) { _, _ in
            chat.attach(to: runtime)
            loadSkills()
        }
    }

/// 阅读器里弹出的对话：sheet 里没有导航栏，给它一层导航栈。
struct ChatSheet: View {
    var body: some View {
        NavigationStack { ChatView() }
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
        if skill.requiresInput {
            pendingSkill = skill
            return
        }
        pendingSkill = nil
        let prompt = skill.desc.isEmpty ? skill.name : skill.desc
        chat.send(
            prompt,
            book: reading.book,
            contextText: reading.promptContext,
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

    private var threadList: some View {
        NavigationStack {
            List {
                Button {
                    chat.startNewThread()
                    showThreads = false
                } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("chat.newThread")

                ForEach(chat.threads) { thread in
                    Button {
                        chat.open(thread, using: runtime)
                        showThreads = false
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(thread.title)
                                .font(.subheadline.weight(chat.activeThreadId == thread.id ? .semibold : .regular))
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)
                            Text(threadSubtitle(thread))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.threadRow")
                }
                .onDelete { offsets in
                    for index in offsets {
                        chat.delete(chat.threads[index], using: runtime)
                    }
                }
            }
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showThreads = false }
                }
            }
            .task { chat.refreshThreads(using: runtime) }
        }
    }

    private func threadSubtitle(_ thread: ChatThread) -> String {
        let date = Date(timeIntervalSince1970: thread.updatedAt / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "M-d HH:mm"
        let stamp = formatter.string(from: date)
        guard let last = thread.lastMessage, !last.isEmpty else { return stamp }
        return "\(stamp) · \(last)"
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
                withAnimation(.linear(duration: 0.1)) {
                    if chat.isStreaming {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    } else if let last = chat.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 10) {
            if runtime.state != .ready {
                Text("AI 内核未就绪：\(stateText)").font(.footnote).foregroundStyle(.secondary)
            } else if !settings.isConfigured {
                Text("还没配 AI 端点").font(.headline)
                Text("在「我的 → AI 设置」填端点、模型名和 API Key。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("去设置") { showSettings = true }
                    .buttonStyle(.borderedProminent)
            } else if let book = reading.book {
                Text("和《\(book.title)》对话")
                    .font(.title3.weight(.semibold))
                Text("提问会自动带上阅读位置和当前页正文；选中文字后提问，优先带选中的段落。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                suggestions
            } else {
                Text("从一本书开始")
                    .font(.title3.weight(.semibold))
                Text("在书库打开一本书，再回来提问。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    /// 空对话时给几个能直接点的开头，比一句「请输入问题」有用。
    private var suggestions: some View {
        VStack(spacing: 0) {
            ForEach(Self.starterPrompts, id: \.self) { prompt in
                Button {
                    draft = prompt
                } label: {
                    HStack(spacing: 10) {
                        Text(prompt)
                            .font(.subheadline)
                            .foregroundStyle(Color.primary)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.suggestion")
                if prompt != Self.starterPrompts.last {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.top, 8)
    }

    private static let starterPrompts = [
        "这一章讲了什么？",
        "这本书的核心观点是什么？",
        "把当前这一页讲得再简单一点",
    ]

    private var composer: some View {
        VStack(spacing: 8) {
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
            HStack(alignment: .bottom, spacing: 8) {
                TextField(pendingSkill?.needsInput ?? "问这本书…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
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
                        let text = draft
                        draft = ""
                        chat.send(
                            text,
                            book: reading.book,
                            contextText: reading.promptContext,
                            settings: settings,
                            skill: pendingSkill
                        )
                        pendingSkill = nil
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

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).font(.footnote).lineLimit(4)
            Spacer(minLength: 0)
            Button("知道了") { chat.error = nil }
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
