// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// 两处笔记编辑共用退出确认；保存仍由各自的持久化路径负责。
struct NoteCancelButton: View {
    let hasChanges: Bool
    let discard: () -> Void
    @State private var showConfirmation = false

    var body: some View {
        Button("取消") {
            if hasChanges { showConfirmation = true } else { discard() }
        }
        .accessibilityIdentifier("note.cancel")
        .alert("放弃未保存的修改？", isPresented: $showConfirmation) {
            Button("放弃修改", role: .destructive, action: discard)
                .accessibilityIdentifier("note.discard")
            Button("继续编辑", role: .cancel) {}
                .accessibilityIdentifier("note.keepEditing")
        }
    }
}
