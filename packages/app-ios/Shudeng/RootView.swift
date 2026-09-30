// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var runtime: RuntimeHost
    @EnvironmentObject private var settings: AppSettings
    /// 首次启动看一页引导；跑 UI 测试时用 `-shudeng.onboarded YES` 跳过。
    @AppStorage("shudeng.onboarded") private var onboarded = false
    @StateObject private var reading = ReadingSession()
    /// 对话状态放在根视图：AI Tab 和阅读器里的 AI 弹层共用同一段对话，
    /// 弹层关掉再打开不会丢上下文。
    @StateObject private var chat = ChatService()
    @State private var showSplash = true
    @State private var showOnboarding = false

    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("书架", systemImage: "books.vertical") }
            ChatListView()
                .tabItem { Label("AI", systemImage: "sparkles") }
            NotesView()
                .tabItem { Label("笔记", systemImage: "highlighter") }
            ProfileView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
        .tint(settings.accent.color)
        .environmentObject(reading)
        .environmentObject(chat)
        .preferredColorScheme(settings.appearance.colorScheme)
        .fullScreenCover(isPresented: $reading.isReaderPresented) {
            ReaderScreen()
                .environmentObject(reading)
                // 阅读器里的 AI 弹层要用同一段对话；少注入这一层，点 ✨ 会直接闪退。
                .environmentObject(chat)
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
        .onChange(of: runtime.state) { _, state in
            // Runtime 启动和根视图 task 的先后顺序不固定；状态变化后补一次绑定，
            // 避免启动稍慢时书库 / AI 已显示但第一次加载没有发生。
            guard state == .ready else { return }
            reading.attach(to: runtime)
            chat.attach(to: runtime)
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
