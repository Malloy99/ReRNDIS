// SPDX-License-Identifier: GPL-2.0-or-later
// Status and control endpoint. Ad-hoc signing rules out code-signing checks on
// clients, so trust rests on the caller's euid: reads are open to local users,
// control needs root or the admin group (the same bar as sudo ifconfig).

import Foundation
import ReRNDISShared

final class XPCServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let registry: DeviceRegistry

    init(registry: DeviceRegistry) {
        self.listener = NSXPCListener(machServiceName: rerndisMachServiceName)
        self.registry = registry
        super.init()
        listener.delegate = self
        listener.resume()
        DaemonLog.info(.xpc, "XPC listener active on \(rerndisMachServiceName)")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let handler = XPCConnectionHandler(registry: registry, clientUID: newConnection.effectiveUserIdentifier)
        newConnection.exportedInterface = NSXPCInterface(with: ReRNDISDaemonXPC.self)
        newConnection.exportedObject = handler
        newConnection.resume()
        return true
    }
}

final class XPCConnectionHandler: NSObject, ReRNDISDaemonXPC, @unchecked Sendable {
    private let registry: DeviceRegistry
    private let clientUID: uid_t

    init(registry: DeviceRegistry, clientUID: uid_t) {
        self.registry = registry
        self.clientUID = clientUID
    }

    private var clientMayControl: Bool {
        if clientUID == 0 { return true }
        guard let passwd = getpwuid(clientUID) else { return false }
        var groups = [Int32](repeating: 0, count: 64)
        var count = Int32(groups.count)
        guard getgrouplist(passwd.pointee.pw_name, Int32(passwd.pointee.pw_gid), &groups, &count) >= 0 else {
            return false
        }
        guard let admin = getgrnam("admin") else { return false }
        let adminGID = Int32(admin.pointee.gr_gid)
        return groups.prefix(Int(count)).contains(adminGID)
    }

    func fetchStatus(reply: @escaping @Sendable (Data?) -> Void) {
        let registry = registry
        Task {
            let snapshots = await registry.snapshots()
            let enabled = await registry.isEnabled
            let status = DaemonStatus(
                version: daemonVersion,
                enabled: enabled,
                devices: snapshots.map { snapshot in
                    DaemonStatus.Device(
                        id: snapshot.id,
                        name: snapshot.displayName,
                        serial: snapshot.serial,
                        phase: snapshot.phase.rawValue,
                        macAddress: macText(snapshot.macAddress),
                        linkUp: snapshot.linkUp,
                        interfaceName: snapshot.interfaceName,
                        rxBytes: snapshot.rxBytes,
                        txBytes: snapshot.txBytes
                    )
                }
            )
            reply(try? JSONEncoder().encode(status))
        }
    }

    func fetchRecentLogs(limit: Int, reply: @escaping @Sendable (Data?) -> Void) {
        let bounded = min(max(limit, 1), 2000)
        let lines = LogRing.shared.tail(bounded).map { entry in
            LogLine(
                timestamp: entry.timestamp,
                level: entry.level.rawValue,
                category: entry.category,
                message: entry.message
            )
        }
        reply(try? JSONEncoder().encode(lines))
    }

    func setEnabled(_ enabled: Bool, reply: @escaping @Sendable (Bool, String?) -> Void) {
        guard clientMayControl else {
            reply(false, "admin privileges required")
            return
        }
        let registry = registry
        DaemonLog.info(.xpc, "setEnabled(\(enabled)) from uid \(clientUID)")
        Task {
            await registry.setEnabled(enabled)
            reply(true, nil)
        }
    }

    func fetchConfiguration(reply: @escaping @Sendable (Data?) -> Void) {
        reply(try? JSONEncoder().encode(SettingsStore.load()))
    }

    func applyConfiguration(_ data: Data, reply: @escaping @Sendable (Bool, String?) -> Void) {
        guard clientMayControl else {
            reply(false, "admin privileges required")
            return
        }
        guard let configuration = try? JSONDecoder().decode(DaemonConfiguration.self, from: data) else {
            reply(false, "malformed configuration payload")
            return
        }
        let registry = registry
        DaemonLog.info(.xpc, "applyConfiguration from uid \(clientUID)")
        Task {
            if let error = await registry.applyConfiguration(configuration) {
                reply(false, error)
            } else {
                reply(true, nil)
            }
        }
    }

    func runBenchmark(deviceID: String?, reply: @escaping @Sendable (Data?) -> Void) {
        guard clientMayControl else {
            reply(try? JSONEncoder().encode(BenchmarkResult.failure("admin privileges required")))
            return
        }
        let registry = registry
        DaemonLog.info(.xpc, "benchmark requested by uid \(clientUID)")
        Task {
            let result = await registry.runBenchmark(deviceID: deviceID)
            reply(try? JSONEncoder().encode(result))
        }
    }
}
