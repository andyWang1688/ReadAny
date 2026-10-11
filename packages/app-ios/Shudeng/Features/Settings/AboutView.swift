// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var settings: AISettings
    private let sourceURL = URL(string: "https://github.com/andyWang1688/ReadAny")!

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("书灯").font(.title.weight(.semibold))
                    Text("一盏照书的灯，陪你读懂每一页。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("开源") {
                Link("源码仓库", destination: sourceURL)
                NavigationLink("许可证") { LicenseView() }
                Text("书灯基于 ReadAny（GPL-3.0-or-later）构建，本 App 同样以 GPL-3.0-or-later 分发。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("版本") {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            }
        }
        .navigationTitle("关于书灯")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseView: View {
    var body: some View {
        ScrollView {
            Text(licenseText)
                .font(.system(.footnote, design: .monospaced))
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle("GPL-3.0")
    }

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "未找到 LICENSE 文件（应随 App Bundle 一起分发）。"
        }
        return text
    }
}
