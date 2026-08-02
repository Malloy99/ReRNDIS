// SPDX-License-Identifier: GPL-2.0-or-later

import CFeth
import Foundation
import RNDISCore
import Synchronization

final class FethBackend: NICBackend, @unchecked Sendable {
    private struct BackendState {
        var pair: FethPair?
        var bpf: BPFLink?
        var dhcpInterface: String?
        var publishedDNSServiceID: String?
        var router: String?
    }

    private let state = Mutex(BackendState())
    private let injectDropCount = Atomic<Int>(0)
    var deviceSerial: String?
    private let reconciler = NetworkReconciler()

    /// Batch payload assembly area. `inject` runs only on the session's serial
    /// USB completion queue, so this needs no lock of its own.
    private var batchScratch = [UInt8](repeating: 0, count: 32 * 1024)

    /// Batch injection demotes itself permanently after any write failure
    /// (turning the fd's batch mode off so raw writes become valid again).
    private var batchInjectDemoted = false

    func attach(
        macAddress: [UInt8],
        mtu: Int,
        onOutboundFrame: @escaping @Sendable (UnsafeRawBufferPointer) -> Void
    ) throws -> String {
        let pair = try FethPair.create()
        StateStore.registerPair(system: pair.systemSide, io: pair.ioSide)
        do {
            try pair.configure(macAddress: macAddress, mtu: Int32(mtu))
            let bpf = try BPFLink(interfaceName: pair.ioSide)
            bpf.start(onFrame: onOutboundFrame)
            let injection = bpf.supportsBatchWrite ? "batched" : "per-frame"
            let systemSide = pair.systemSide
            let ioSide = pair.ioSide
            state.withLock {
                $0.pair = pair
                $0.bpf = bpf
            }
            DaemonLog.info(.net, "virtual interface \(systemSide) up (io \(ioSide), MAC \(macText(macAddress)), "
                + "\(injection) injection)")
            return systemSide
        } catch {
            pair.destroy()
            StateStore.unregisterPair(system: pair.systemSide)
            throw error
        }
    }

    func completeNetworkSetup() async {
        guard let pair = state.withLock({ $0.pair }) else { return }

        state.withLock { $0.dhcpInterface = pair.systemSide }

        // macOS's per-interface DHCP client can die silently when interfaces
        // are recreated in quick succession; reissuing `ipconfig set` revives it.
        var lease: String?
        for attempt in 1...3 {
            NetConfig.startDHCP(interface: pair.systemSide)
            lease = await NetConfig.waitForLease(pair: pair, timeoutSeconds: 12)
            if lease != nil { break }
            DaemonLog.error(.net, "\(pair.systemSide): no DHCP lease within 12s "
                + "(attempt \(attempt); is tethering active on the device?)")
        }
        guard let address = lease else { return }
        DaemonLog.info(.net, "\(pair.systemSide): DHCP lease \(address)")

        guard let info = NetConfig.serviceInfo(interfaceName: pair.systemSide) else {
            DaemonLog.error(.net, "\(pair.systemSide): no dynamic-store service found for the lease")
            return
        }

        let leaseDNS = NetConfig.leaseDNSServers(interface: pair.systemSide)
        state.withLock { $0.router = info.router }

        // Default route and global DNS are managed continuously, not just at
        // setup: turning the other uplink off later must promote the tether.
        let serial = deviceSerial
        reconciler.activate(context: NetworkReconciler.LeaseContext(
            interfaceName: pair.systemSide,
            serviceID: info.serviceID,
            router: info.router,
            dnsServers: leaseDNS,
            mayTakeOver: { UplinkPreference.shared.allowsTakeover(serial: serial) }
        ))

        if leaseDNS.isEmpty {
            DaemonLog.error(.net, "\(pair.systemSide): lease carried no DNS servers")
        } else if NetConfig.globalDNSIncludes(servers: leaseDNS) {
            DaemonLog.info(.net, "\(pair.systemSide): lease DNS \(leaseDNS.joined(separator: ", ")) active via IPConfiguration")
        } else if NetConfig.publishDNS(serviceID: info.serviceID, servers: leaseDNS) {
            state.withLock { $0.publishedDNSServiceID = info.serviceID }
            DaemonLog.info(.net, "\(pair.systemSide): published DNS \(leaseDNS.joined(separator: ", ")) (fallback path)")
        } else {
            DaemonLog.error(.net, "\(pair.systemSide): DNS publication failed; name resolution may not work")
        }
    }

    func currentRouter() -> String? {
        state.withLock { $0.router }
    }

    func inject(transfer: UnsafeRawBufferPointer, frames: [RNDISFraming.FrameRange]) {
        guard !frames.isEmpty, let bpf = state.withLock({ $0.bpf }) else { return }
        // While batch mode is on, the kernel parses EVERY write as batch
        // records, so single frames must be wrapped too. Raw writes are only
        // valid after demotion turns the mode off.
        if bpf.supportsBatchWrite, !batchInjectDemoted {
            if writeBatch(bpf, transfer, frames) {
                return
            }
            batchInjectDemoted = true
            bpf.disableBatchWrite()
            DaemonLog.error(.net, "batch injection failed; demoting to per-frame writes")
        }
        for range in frames {
            let frame = UnsafeRawBufferPointer(rebasing: transfer[range.offset..<(range.offset + range.length)])
            if !bpf.writeRaw(frame) {
                recordInjectDrop()
            }
        }
    }

    /// One write(2) per USB transfer: records of [bpf_hdr + frame + pad].
    private func writeBatch(
        _ bpf: BPFLink,
        _ transfer: UnsafeRawBufferPointer,
        _ frames: [RNDISFraming.FrameRange]
    ) -> Bool {
        let headerSize = MemoryLayout<bpf_hdr>.size
        var required = 0
        for range in frames {
            required += cfeth_bpf_wordalign(headerSize + range.length)
        }
        if batchScratch.count < required {
            batchScratch = [UInt8](repeating: 0, count: required)
        }
        let total = batchScratch.withUnsafeMutableBytes { out -> Int in
            let base = out.baseAddress!
            var offset = 0
            for range in frames {
                var header = bpf_hdr()
                header.bh_caplen = UInt32(range.length)
                header.bh_datalen = UInt32(range.length)
                header.bh_hdrlen = UInt16(headerSize)
                withUnsafeBytes(of: header) { source in
                    base.advanced(by: offset).copyMemory(from: source.baseAddress!, byteCount: headerSize)
                }
                base.advanced(by: offset + headerSize).copyMemory(
                    from: transfer.baseAddress!.advanced(by: range.offset),
                    byteCount: range.length
                )
                let record = cfeth_bpf_wordalign(headerSize + range.length)
                let padding = record - (headerSize + range.length)
                if padding > 0 {
                    base.advanced(by: offset + headerSize + range.length)
                        .initializeMemory(as: UInt8.self, repeating: 0, count: padding)
                }
                offset += record
            }
            return offset
        }
        // Frames are not counted as dropped here: on failure the caller demotes
        // and retries them per-frame.
        return batchScratch.withUnsafeBytes { raw in
            bpf.writeRaw(UnsafeRawBufferPointer(rebasing: raw[0..<total]))
        }
    }

    private func recordInjectDrop(count: Int = 1) {
        let total = injectDropCount.wrappingAdd(count, ordering: .relaxed).newValue
        if total % 512 <= count {
            DaemonLog.debug(.net, "inject drop count \(total)")
        }
    }

    func detach() {
        let captured = state.withLock { current -> BackendState in
            let copy = current
            current = BackendState()
            return copy
        }
        let pair = captured.pair
        let bpf = captured.bpf
        let dhcp = captured.dhcpInterface
        let dnsServiceID = captured.publishedDNSServiceID

        // Teardown order: takeover withdrawal and DNS keys before ipconfig
        // NONE, BPF before destroying the interfaces, state-store record last.
        reconciler.deactivate()
        if let dnsServiceID {
            NetConfig.removeDNS(serviceID: dnsServiceID)
        }
        if let dhcp {
            NetConfig.stopDHCP(interface: dhcp)
        }
        bpf?.shutdown()
        if let pair {
            pair.destroy()
            StateStore.unregisterPair(system: pair.systemSide)
            DaemonLog.info(.net, "virtual interface \(pair.systemSide) removed")
        }
    }
}
