// SPDX-License-Identifier: GPL-2.0-or-later
// Installing the daemon needs root. The app never sees the password: it hands
// the script to osascript's `with administrator privileges`, and macOS itself
// runs the authentication panel.

import Foundation

@MainActor
final class InstallerService: ObservableObject {
    enum State: Equatable {
        case missing
        case installed(version: String?)
        case working
    }

    @Published private(set) var state: State = .missing
    @Published var failure: String?

    private static let label = "be.zvz.rerndis.daemon"
    private static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    private static let helperPath = "/Library/PrivilegedHelperTools/\(label)"
    private let queue = DispatchQueue(label: "be.zvz.rerndis.installer")

    /// Payload the bundle carries: daemon, CLI, plist, and the shell scripts.
    private var payload: URL? {
        Bundle.main.resourceURL.map { $0.appendingPathComponent("Payload", isDirectory: true) }
    }

    var canInstall: Bool {
        guard let payload else { return false }
        return FileManager.default.fileExists(atPath: payload.appendingPathComponent("install.sh").path)
    }

    func refresh() {
        guard state != .working else { return }
        guard FileManager.default.fileExists(atPath: Self.plistPath) else {
            state = .missing
            return
        }
        state = .installed(version: installedVersion())
    }

    /// Version of the binary on disk, which may differ from the app's payload
    /// after an app update.
    private func installedVersion() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.helperPath)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func install() {
        guard let payload else { return }
        run(script: "'\(payload.appendingPathComponent("install.sh").path)'")
    }

    func uninstall() {
        guard let payload else { return }
        run(script: "'\(payload.appendingPathComponent("uninstall.sh").path)'")
    }

    private func run(script: String) {
        state = .working
        failure = nil
        queue.async { [weak self] in
            let source = "do shell script \"\(script)\" with administrator privileges"
            var errorInfo: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
            // -128 is the user dismissing the authentication panel.
            let cancelled = (errorInfo?["NSAppleScriptErrorNumber"] as? Int) == -128
            let message = cancelled ? nil : errorInfo?["NSAppleScriptErrorMessage"] as? String
            Task { @MainActor in
                guard let self else { return }
                self.state = .missing
                self.refresh()
                self.failure = message
            }
        }
    }
}
