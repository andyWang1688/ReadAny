// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct AISettingsView: View {
    @EnvironmentObject private var settings: AISettings
    @Environment(\.dismiss) private var dismiss
    @State private var revealKey = false
    @State private var showAdvancedConnection = false
    /// sheet 里要自带导航栏 + 「完成」按钮；被 NavigationLink push 时不能再套一层。
    var inSheet = true

    var body: some View {
        if inSheet {
            NavigationStack { form }
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
                    settings.applyProviderDefaults(for: newValue)
                    showAdvancedConnection = newValue == .custom
                }
                LabeledContent("模型") {
                    TextField("填写模型名称", text: $settings.model)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("模型名称")
                        .accessibilityIdentifier("ai.model")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key")
                    HStack(spacing: 8) {
                        Group {
                            if revealKey {
                                TextField("填写 API Key", text: $settings.apiKey)
                            } else {
                                SecureField("填写 API Key", text: $settings.apiKey)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .accessibilityLabel("API Key")
                        .accessibilityIdentifier("ai.apiKey")
                        Button {
                            revealKey.toggle()
                        } label: {
                            Image(systemName: revealKey ? "eye.slash" : "eye")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(revealKey ? "隐藏 API Key" : "显示 API Key")
                    }
                }
                if let error = settings.apiKeyError {
                    Text(error).foregroundStyle(.red)
                        .accessibilityIdentifier("ai.keychainError")
                    Button("重试保存") { settings.retryKeychain() }
                        .accessibilityIdentifier("ai.retryKeychain")
                }
            } footer: {
                Text(settings.apiKeyError == nil
                    ? "设置自动保存，Key 仅存于这台设备的钥匙串。"
                    : "Key 读取或保存失败，请重试。")
            }

            Section {
                DisclosureGroup("高级连接设置", isExpanded: $showAdvancedConnection) {
                    TextField("服务地址", text: $settings.baseURL, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityLabel("服务地址")
                        .accessibilityIdentifier("ai.baseURL")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("连接地址：\(settings.baseURL.isEmpty ? "未填写" : settings.baseURL)")
                    if let issue = settings.configurationIssue {
                        Text(issue).foregroundStyle(.orange)
                            .accessibilityIdentifier("ai.configurationIssue")
                    }
                }
            }
        }
        .onAppear { showAdvancedConnection = settings.provider == .custom }
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
