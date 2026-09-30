// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct AISettingsView: View {
    @EnvironmentObject private var settings: AISettings
    @Environment(\.dismiss) private var dismiss
    @State private var revealKey = false
    /// sheet 里要自带导航栏 + 「完成」按钮；被 NavigationLink push 时不能再套一层。
    var inSheet = true

    var body: some View {
        if inSheet {
            NavigationStack {
                form
            }
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker("服务商", selection: $settings.provider) {
                    ForEach(AISettings.Provider.allCases) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
                .onChange(of: settings.provider) { _, newValue in
                    if settings.baseURL.isEmpty || AISettings.Provider.allCases.contains(where: { $0.defaultBaseURL == settings.baseURL }) {
                        settings.baseURL = newValue.defaultBaseURL
                    }
                }
            } header: {
                Text("服务商")
            } footer: {
                Text("书灯只在设备上直连你填的端点，不经过任何中转。")
            }

            Section("端点") {
                TextField("Base URL", text: $settings.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("模型名，例如 deepseek-chat", text: $settings.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                if revealKey {
                    TextField("sk-…", text: $settings.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField("sk-…", text: $settings.apiKey)
                }
                Toggle("显示明文", isOn: $revealKey)
            } header: {
                Text("API Key")
            } footer: {
                Text("Key 存在 iOS 钥匙串（Keychain），不写入 UserDefaults，也不随备份导出。")
            }

            Section("常用端点") {
                ForEach(AISettings.Provider.allCases) { provider in
                    if !provider.defaultBaseURL.isEmpty {
                        Button {
                            settings.provider = provider
                            settings.baseURL = provider.defaultBaseURL
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.label).font(.subheadline)
                                Text(provider.defaultBaseURL).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                LabeledContent("状态", value: settings.isConfigured ? "已配置" : "未配置")
            }
        }
        .navigationTitle("AI 设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
