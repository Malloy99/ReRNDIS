// SPDX-License-Identifier: GPL-2.0-or-later

import ReRNDISShared
import SwiftUI

@main
struct ReRNDISApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = StatusModel()
    @StateObject private var installer = InstallerService()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model, installer: installer)
        } label: {
            Image(systemName: iconName)
        }
        .menuBarExtraStyle(.window)
    }

    private var iconName: String {
        guard model.reachable else { return "personalhotspot.slash" }
        let hasLiveDevice = model.status?.devices.contains { $0.phase == "up" && $0.linkUp } ?? false
        return hasLiveDevice ? "personalhotspot" : "personalhotspot.slash"
    }
}

/// The daemon follows the app's lifecycle: running the app is the intent to
/// tether, quitting it is the intent to stop.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        let connection = ReRNDISXPCClient.makeConnection()
        defer { connection.invalidate() }
        let done = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in
            done.signal()
        } as? ReRNDISDaemonXPC
        proxy?.setEnabled(false) { @Sendable _, _ in
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
    }
}
