// SPDX-License-Identifier: GPL-2.0-or-later
// Registry of feth pairs this daemon created, for crash-orphan cleanup. feth is
// shared infrastructure (ZeroTier uses it too): only interfaces recorded here
// may ever be destroyed. /var/run self-clears on reboot.

import Foundation

struct FethPairRecord: Codable, Equatable {
    let system: String
    let io: String
    /// Owning process; records whose owner is still alive are never cleaned.
    /// Optional so files written by older builds keep decoding.
    var pid: Int32?
}

enum StateStore {
    static let directory = "/var/run/rerndis"
    static var path: String { directory + "/interfaces.json" }

    private static let lock = NSLock()

    static func registerPair(system: String, io: String) {
        lock.lock()
        defer { lock.unlock() }
        var records = load()
        records.append(FethPairRecord(system: system, io: io, pid: getpid()))
        save(records)
    }

    static func unregisterPair(system: String) {
        lock.lock()
        defer { lock.unlock() }
        save(load().filter { $0.system != system })
    }

    static func registeredPairs() -> [FethPairRecord] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    /// Destroys pairs whose owning process is gone. Records held by a live
    /// rerndisd (for example the installed daemon, while a foreground instance
    /// starts) are left untouched.
    @discardableResult
    static func cleanupOrphans() -> Int {
        lock.lock()
        let records = load()
        let orphaned = records.filter { !processIsAlive($0.pid) }
        save(records.filter { processIsAlive($0.pid) })
        lock.unlock()
        for record in orphaned {
            DaemonLog.info(.net, "cleaning up orphaned pair \(record.system)/\(record.io)")
            NetConfig.stopDHCP(interface: record.system)
            FethPair.destroyInterface(named: record.io)
            FethPair.destroyInterface(named: record.system)
        }
        return orphaned.count
    }

    private static func processIsAlive(_ pid: Int32?) -> Bool {
        // Legacy records without a pid are treated as orphaned.
        guard let pid, pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private static func load() -> [FethPairRecord] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([FethPairRecord].self, from: data)) ?? []
    }

    private static func save(_ records: [FethPairRecord]) {
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            let data = try JSONEncoder().encode(records)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            // Non-root development runs land here; orphan tracking degrades.
            DaemonLog.error(.net, "state store write failed: \(error)")
        }
    }
}
