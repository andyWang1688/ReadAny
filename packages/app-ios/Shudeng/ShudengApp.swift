// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct ShudengApp: App {
    @StateObject private var runtime = RuntimeHost()
    @StateObject private var settings = AISettings()
    @StateObject private var appSettings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(runtime)
                .environmentObject(settings)
                .environmentObject(appSettings)
                .task { runtime.start() }
        }
    }
}
