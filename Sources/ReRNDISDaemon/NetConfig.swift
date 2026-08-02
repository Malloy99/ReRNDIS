// SPDX-License-Identifier: GPL-2.0-or-later
// IPv4 bring-up on the feth system side. `ipconfig set DHCP` routes through
// IPConfiguration's normal registration path: the lease, the scoped route, and
// the service state keys all come from the system, not from us. We only promote
// the default route and, when the lease DNS fails to reach the global state,
// publish the service DNS key ourselves.

import Foundation
import SystemConfiguration

enum NetConfig {
    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (127, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func startDHCP(interface: String) {
        let result = run("/usr/sbin/ipconfig", ["set", interface, "DHCP"])
        if result.status != 0 {
            DaemonLog.error(.net, "ipconfig set \(interface) DHCP exited \(result.status): \(result.output)")
        }
    }

    static func stopDHCP(interface: String) {
        _ = run("/usr/sbin/ipconfig", ["set", interface, "NONE"])
    }

    /// Polls the interface address until IPConfiguration lands the lease.
    static func waitForLease(pair: FethPair, timeoutSeconds: Double) async -> String? {
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while ContinuousClock.now < deadline {
            if let address = pair.systemSideIPv4() {
                return address
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    struct ServiceInfo {
        let serviceID: String
        let router: String?
    }

    /// Finds the dynamic-store service that IPConfiguration created for the
    /// interface by scanning State:/Network/Service/*/IPv4.
    static func serviceInfo(interfaceName: String) -> ServiceInfo? {
        guard let store = SCDynamicStoreCreate(nil, "rerndisd" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String]
        else { return nil }
        for key in keys {
            guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  value["InterfaceName"] as? String == interfaceName
            else { continue }
            let serviceID = key
                .replacingOccurrences(of: "State:/Network/Service/", with: "")
                .replacingOccurrences(of: "/IPv4", with: "")
            return ServiceInfo(serviceID: serviceID, router: value["Router"] as? String)
        }
        return nil
    }

    /// True when a non-interface-scoped IPv4 default route exists. Scoped
    /// defaults (the I flag) do not serve unbound sockets, so they must not
    /// count as connectivity here.
    static func hasUnscopedDefaultRoute() -> Bool {
        let output = run("/usr/sbin/netstat", ["-rn", "-f", "inet"]).output
        for line in output.split(separator: "\n") where line.hasPrefix("default") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            if columns.count >= 3, !columns[2].contains("I") {
                return true
            }
        }
        return false
    }

    static func addDefaultRoute(router: String) {
        let result = run("/sbin/route", ["-n", "add", "default", router])
        if result.status != 0 {
            DaemonLog.error(.net, "route add default \(router) exited \(result.status)")
        }
    }

    static func deleteDefaultRoute(router: String) {
        _ = run("/sbin/route", ["-n", "delete", "default", router])
    }

    /// Primary IPv4 service elected by IPMonitor, nil when no uplink is primary
    /// (for example Wi-Fi just turned off and only the tether remains).
    static func globalIPv4PrimaryService() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "rerndisd" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return value["PrimaryService"] as? String
    }

    /// Our state-only service is invisible to primary election, so when nothing
    /// else is primary the global DNS state stays empty unless we publish it.
    static func setGlobalDNS(servers: [String]) -> Bool {
        guard !servers.isEmpty,
              let store = SCDynamicStoreCreate(nil, "rerndisd" as CFString, nil, nil)
        else { return false }
        return SCDynamicStoreSetValue(
            store,
            "State:/Network/Global/DNS" as CFString,
            ["ServerAddresses": servers] as CFDictionary
        )
    }

    static func removeGlobalDNS() {
        guard let store = SCDynamicStoreCreate(nil, "rerndisd" as CFString, nil, nil) else { return }
        SCDynamicStoreRemoveValue(store, "State:/Network/Global/DNS" as CFString)
    }

    /// True when the global DNS state already includes any of the servers.
    static func globalDNSIncludes(servers: [String]) -> Bool {
        guard !servers.isEmpty,
              let store = SCDynamicStoreCreate(nil, "rerndisd" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let current = value["ServerAddresses"] as? [String]
        else { return false }
        return !Set(current).isDisjoint(with: servers)
    }

    /// DNS servers offered in the current lease, from ipconfig's packet dump.
    /// Format in the dump: `domain_name_server (ip_mult): {10.221.71.129}`.
    static func leaseDNSServers(interface: String) -> [String] {
        let output = run("/usr/sbin/ipconfig", ["getpacket", interface]).output
        guard let line = output.split(separator: "\n").first(where: { $0.contains("domain_name_server") }),
              let open = line.firstIndex(of: "{"), let close = line.firstIndex(of: "}")
        else { return [] }
        return line[line.index(after: open)..<close]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func publishDNS(serviceID: String, servers: [String]) -> Bool {
        guard !servers.isEmpty,
              let store = SCDynamicStoreCreate(nil, "rerndisd" as CFString, nil, nil)
        else { return false }
        let key = "State:/Network/Service/\(serviceID)/DNS" as CFString
        let value = ["ServerAddresses": servers] as CFDictionary
        return SCDynamicStoreSetValue(store, key, value)
    }

    static func removeDNS(serviceID: String) {
        guard let store = SCDynamicStoreCreate(nil, "rerndisd" as CFString, nil, nil) else { return }
        SCDynamicStoreRemoveValue(store, "State:/Network/Service/\(serviceID)/DNS" as CFString)
    }
}
