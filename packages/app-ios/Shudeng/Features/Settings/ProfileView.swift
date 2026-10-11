// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ProfileView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var runtime: RuntimeHost
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var aiSettings: AISettings
    @EnvironmentObject private var reading: ReadingSession
    @StateObject private var stats = StatsStore()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        StatsView()
                    } label: {
                        rowLayout {
                            Label("阅读统计", systemImage: "chart.bar")
                            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                            Text(todayText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("阅读")
                }

                // 字号、行距、页边距、朗读语速都在阅读器右上角的「阅读设置」里，
                // 这里只留全 App 的东西 —— 同一件事不在两个地方各设一遍。
                Section("外观") {
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        rowLayout {
                            Label("外观", systemImage: "paintpalette")
                            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                            Text(settings.appearance.label)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("profile.appearance")
                }

                Section("AI") {
                    NavigationLink {
                        AISettingsView(inSheet: false)
                    } label: {
                        rowLayout {
                            Label("AI 设置", systemImage: "sparkles")
                            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                            Text(aiSettings.isConfigured ? aiSettings.model : "未配置")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        }
                    }
                    .accessibilityIdentifier("profile.ai")
                    NavigationLink {
                        VectorModelView()
                    } label: {
                        Label("智能搜索", systemImage: "magnifyingglass")
                    }
                    .accessibilityIdentifier("profile.vector")
                }

                Section("关于") {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("关于书灯", systemImage: "info.circle")
                    }
                        .accessibilityIdentifier("profile.about")
                }
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .task { stats.refresh(using: runtime) }
            .onChange(of: runtime.state) { _, _ in stats.refresh(using: runtime) }
            .onChange(of: reading.dataVersion) { _, _ in stats.refresh(using: runtime) }
        }
    }

    private var rowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout())
    }

    private var todayText: String {
        guard let today = stats.payload?.today else { return "" }
        return today.minutes >= 1 ? "今天 \(Int(today.minutes)) 分钟" : "今天还没读"
    }
}

struct AppearanceSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        List {
            Section {
                Picker("主题", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("阅读页面保持黑白灰，颜色只出现在书封、高亮和主题色上。")
            }

            Section {
                HStack(spacing: 10) {
                    ForEach(AccentTheme.allCases) { theme in
                        Button {
                            settings.accent = theme
                        } label: {
                            Circle()
                                .fill(theme.color)
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle().strokeBorder(
                                        settings.accent == theme ? Color.primary : Theme.hairline,
                                        lineWidth: settings.accent == theme ? 2 : 0.5
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(theme.label)
                        .accessibilityIdentifier("accent.\(theme.rawValue)")
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("主题色")
            } footer: {
                Text("只换强调色：滑杆、选中态、按钮、进度、奖章和标签栏跟着变；书封和高亮颜色不动。")
            }

        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }
}
