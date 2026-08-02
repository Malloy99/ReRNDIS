// SPDX-License-Identifier: GPL-2.0-or-later

import Synchronization

/// When several tethers are live and no other uplink is primary, only the
/// preferred device (when attached) may install the default route and DNS.
final class UplinkPreference: Sendable {
    static let shared = UplinkPreference()

    private let state = Mutex<(preferred: String?, attached: Set<String>)>((nil, []))

    func setPreferred(_ serial: String?) {
        state.withLock { $0.preferred = serial }
    }

    func setAttached(_ serials: Set<String>) {
        state.withLock { $0.attached = serials }
    }

    func allowsTakeover(serial: String?) -> Bool {
        state.withLock { current in
            guard let preferred = current.preferred else { return true }
            return serial == preferred || !current.attached.contains(preferred)
        }
    }
}
