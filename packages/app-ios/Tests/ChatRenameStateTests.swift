// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@main struct ChatRenameStateTests {
    @MainActor static func main() {
        let probe = RenameProbe()
        let thread = ChatThread(id: "B", title: "old", bookId: nil, updatedAt: 0, messageCount: nil, lastMessage: nil)
        probe.chat.open(thread, using: probe.runtime)
        var failures = 0, checks = 0
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: " + message) }
        }
        probe.renaming = thread; probe.renameText = "draft must survive"
        probe.runtime.failPrefix = "ShudengApp.renameThread"
        probe.saveRename()
        expect(probe.renaming?.id == "B" && probe.renameText == "draft must survive" && probe.chat.error != nil, "failed save retains editor, target and draft with visible error")
        expect(probe.chat.activeThreadTitle == "old", "failed write preserves active title")
        probe.runtime.failPrefix = ""
        for receipt in ["{}", #"{"ok":false}"#, #"{"ok":1}"#] {
            probe.renaming = thread; probe.runtime.renameReceipt = receipt
            probe.saveRename()
            expect(probe.renaming != nil && probe.renameText == "draft must survive", "invalid receipt retains draft: " + receipt)
        }
        probe.renaming = thread; probe.renameText = "   "
        probe.saveRename()
        expect(probe.renaming != nil && probe.renameText == "   " && probe.chat.error != nil, "invalid empty title keeps editor")
        probe.renameText = "new title"; probe.runtime.renameReceipt = nil
        probe.saveRename()
        expect(probe.renaming == nil && probe.chat.activeThreadTitle == "new title" && probe.chat.error == nil, "successful retry closes editor and updates title")
        guard failures == 0 else { print("\(failures)/\(checks) failed"); exit(1) }
        print("Chat rename regression passed (\(checks) checks)")
    }
}
