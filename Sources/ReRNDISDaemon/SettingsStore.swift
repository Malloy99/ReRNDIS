// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import ReRNDISShared

enum SettingsStore {
    private static let url = URL(fileURLWithPath: "/Library/Application Support/be.zvz.rerndis/settings.json")

    static func load() -> DaemonConfiguration {
        guard
            let data = try? Data(contentsOf: url),
            let configuration = try? JSONDecoder().decode(DaemonConfiguration.self, from: data)
        else { return .default }
        return configuration.clamped()
    }

    static func save(_ configuration: DaemonConfiguration) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(configuration).write(to: url, options: .atomic)
    }
}
