// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var runtime: RuntimeHost
    @EnvironmentObject private var settings: AppSettings
    /// 首次启动看一页引导；跑 UI 测试时用 `-shudeng.onboarded YES` 跳过。
    @AppStorage("shudeng.onboarded") private var onboarded = false
    @StateObject private var reading = ReadingSession()
    /// 对话状态放在根视图：AI Tab 和阅读器里的 AI 弹层共用同一段对话，
    /// 弹层关掉再打开不会丢上下文。
    @StateObject private var chat = ChatService()
    @StateObject private var reportAI = ReportAIStore()
    @State private var showSplash = true
    @State private var showOnboarding = false

    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("书架", systemImage: "books.vertical") }
            NotesView()
                .tabItem { Label("笔记", systemImage: "highlighter") }
            ChatListView()
                .tabItem { Label("对话", systemImage: "ellipsis.bubble") }
            ProfileView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
        .tint(settings.accent.color)
        .environmentObject(reading)
        .environmentObject(chat)
        .environmentObject(reportAI)
        .preferredColorScheme(settings.appearance.colorScheme)
        .safeAreaInset(edge: .top) { readingSaveError }
        .fullScreenCover(isPresented: $reading.isReaderPresented) {
            ReaderScreen()
                .preferredColorScheme(settings.readerTheme == .ink ? .dark : .light)
                .tint(settings.accent.color)
                .environmentObject(reading)
                // 阅读器里的 AI 弹层要用同一段对话；少注入这一层，点 ✨ 会直接闪退。
                .environmentObject(chat)
                .safeAreaInset(edge: .top) { readingSaveError }
        }
        .overlay {
            if showOnboarding {
                OnboardingView {
                    onboarded = true
                    withAnimation(.easeOut(duration: 0.2)) { showOnboarding = false }
                }
                .transition(.opacity)
            } else if showSplash {
                SplashOverlay().transition(.opacity)
            } else if case .failed(let message) = runtime.state {
                RuntimeFailureOverlay(message: message) { runtime.retry() }
            }
        }
        .task {
            reading.attach(to: runtime)
            chat.attach(to: runtime)
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation(.easeOut(duration: 0.3)) { showSplash = false }
            if !onboarded { showOnboarding = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { chat.stop() }
        }
        .onChange(of: runtime.state) { _, state in
            // Runtime 启动和根视图 task 的先后顺序不固定；状态变化后补一次绑定，
            // 避免启动稍慢时书库 / AI 已显示但第一次加载没有发生。
            guard state == .ready else { return }
            reading.attach(to: runtime)
            chat.attach(to: runtime)
        }
    }

    @ViewBuilder private var readingSaveError: some View {
        if let error = reading.persistenceError {
            HStack {
                Text(error).font(.footnote)
                Spacer()
                Button("重试保存") { reading.retryPersistence(using: runtime) }
            }
            .padding(10)
            .background(Color.orange.opacity(0.15))
            .accessibilityIdentifier("reading.persistenceError")
        }
    }
}

private struct RuntimeFailureOverlay: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("书灯暂时没准备好")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                Button("重新启动") { retry() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
            .padding(32)
        }
        .accessibilityIdentifier("runtime.failure")
    }
}
