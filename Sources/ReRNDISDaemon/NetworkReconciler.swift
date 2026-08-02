// SPDX-License-Identifier: GPL-2.0-or-later
// The tether service is created by ipconfig as state-only configuration, which
// primary election never considers. While another uplink (Wi-Fi, Ethernet) is
// primary that is fine: the tether stays a scoped alternative. The moment no
// primary exists, unbound sockets lose their default route and the global DNS
// state goes empty, which shows up as "existing connections limp along, every
// new connection and lookup fails". This reconciler watches the global IPv4
// state and installs or withdraws the default route and global DNS accordingly.

import Foundation
import Synchronization
import SystemConfiguration

final class NetworkReconciler: @unchecked Sendable {
    struct LeaseContext: Sendable {
        let interfaceName: String
        let serviceID: String
        let router: String?
        let dnsServers: [String]
        var mayTakeOver: @Sendable () -> Bool = { true }
    }

    private struct State {
        var context: LeaseContext?
        var tookDefaultRoute = false
        var publishedGlobalDNS = false
        var lastOutcome = ""
    }

    private let queue = DispatchQueue(label: "be.zvz.rerndis.net-reconcile")
    private let state = Mutex(State())
    private var store: SCDynamicStore?

    init() {
        // The store must RETAIN us through the context callbacks: notifications
        // can still be queued when the owning session tears down, and an
        // unretained pointer there is a use-after-free (observed as a SIGSEGV
        // on the reconcile queue). deactivate() breaks the resulting cycle.
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                UnsafeRawPointer(Unmanaged<NetworkReconciler>.fromOpaque(info).retain().toOpaque())
            },
            release: { info in
                Unmanaged<NetworkReconciler>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkReconciler>.fromOpaque(info).takeUnretainedValue().reconcile()
        }
        guard let store = SCDynamicStoreCreate(nil, "rerndisd-reconciler" as CFString, callback, &context) else {
            DaemonLog.error(.net, "reconciler: SCDynamicStore creation failed")
            return
        }
        SCDynamicStoreSetNotificationKeys(store, ["State:/Network/Global/IPv4"] as CFArray, nil)
        SCDynamicStoreSetDispatchQueue(store, queue)
        self.store = store
    }

    func activate(context: LeaseContext) {
        state.withLock { $0.context = context }
        queue.async { self.reconcile() }
    }

    func deactivate() {
        let previous = state.withLock { state -> State in
            let previous = state
            state.context = nil
            state.tookDefaultRoute = false
            state.publishedGlobalDNS = false
            state.lastOutcome = ""
            return previous
        }
        withdraw(from: previous, reason: "detaching")
        // Stop deliveries, then drop the store: releasing it releases the
        // context's retained reference to us, breaking the retain cycle.
        if let store {
            SCDynamicStoreSetDispatchQueue(store, nil)
        }
        store = nil
    }

    private func reconcile() {
        guard let context = state.withLock({ $0.context }) else { return }
        let primary = NetConfig.globalIPv4PrimaryService()

        if primary == nil {
            guard context.mayTakeOver() else {
                logOutcome("no primary uplink, but the preferred device owns takeover; staying scoped")
                return
            }
            var actions: [String] = []
            state.withLock { current in
                if let router = context.router, !current.tookDefaultRoute, !NetConfig.hasUnscopedDefaultRoute() {
                    NetConfig.addDefaultRoute(router: router)
                    current.tookDefaultRoute = true
                    actions.append("default via \(router)")
                }
                if !current.publishedGlobalDNS, NetConfig.setGlobalDNS(servers: context.dnsServers) {
                    current.publishedGlobalDNS = true
                    actions.append("global DNS \(context.dnsServers.joined(separator: ", "))")
                }
            }
            logOutcome("no primary uplink: tether takes over" + (actions.isEmpty ? "" : " (\(actions.joined(separator: "; ")))"))
        } else if primary == context.serviceID {
            // The system elected the tether itself; IPMonitor now owns the
            // global state, so our manual overrides must not shadow it.
            let previous = clearFlags()
            withdraw(from: previous, reason: "tether elected primary")
            logOutcome("tether service is primary; standard election in effect")
        } else {
            let previous = clearFlags()
            withdraw(from: previous, reason: "another uplink is primary")
            logOutcome("another uplink is primary; tether stays scoped")
        }
    }

    private func clearFlags() -> State {
        state.withLock { current in
            let previous = current
            current.tookDefaultRoute = false
            current.publishedGlobalDNS = false
            return previous
        }
    }

    private func withdraw(from previous: State, reason: String) {
        guard previous.tookDefaultRoute || previous.publishedGlobalDNS else { return }
        if previous.publishedGlobalDNS {
            NetConfig.removeGlobalDNS()
        }
        if previous.tookDefaultRoute, let router = previous.context?.router {
            NetConfig.deleteDefaultRoute(router: router)
        }
        DaemonLog.info(.net, "withdrew tether takeover (\(reason))")
    }

    /// Reconciles fire on every global-state churn; only state changes are worth
    /// a log line.
    private func logOutcome(_ outcome: String) {
        let changed = state.withLock { current -> Bool in
            guard current.lastOutcome != outcome else { return false }
            current.lastOutcome = outcome
            return true
        }
        if changed {
            DaemonLog.info(.net, "reconciler: \(outcome)")
        }
    }
}
