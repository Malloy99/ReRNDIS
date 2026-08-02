// SPDX-License-Identifier: GPL-2.0-or-later
// One attached RNDIS device: claimed interfaces, control-plane bring-up, the
// bulk data path, and the virtual NIC lifecycle.

import Foundation
import IOUSBHost
import RNDISCore

struct DeviceSessionKey: Hashable, Sendable {
    let deviceRegistryID: UInt64
    let controlInterfaceNumber: UInt8
}

/// IOUSBHost objects are not Sendable; they are confined to the owning session
/// after claiming, so carrying them across that single hop is safe.
final class ClaimedInterfaces: @unchecked Sendable {
    let control: IOUSBHostInterface
    let data: IOUSBHostInterface?
    /// Held open on the device-level path so the configuration stays applied.
    let device: IOUSBHostDevice?
    let controlInterfaceNumber: UInt8
    let configurationDescriptor: [UInt8]

    init(
        control: IOUSBHostInterface,
        data: IOUSBHostInterface?,
        device: IOUSBHostDevice?,
        controlInterfaceNumber: UInt8,
        configurationDescriptor: [UInt8]
    ) {
        self.control = control
        self.data = data
        self.device = device
        self.controlInterfaceNumber = controlInterfaceNumber
        self.configurationDescriptor = configurationDescriptor
    }
}

actor DeviceSession {
    enum Phase: String, Sendable {
        case initializing
        case up
        case failed
        case tornDown
    }

    struct Snapshot: Sendable {
        let id: String
        let displayName: String
        let serial: String?
        let phase: Phase
        let macAddress: [UInt8]
        let linkUp: Bool
        let interfaceName: String?
        let rxBytes: UInt64
        let txBytes: UInt64
    }

    nonisolated let key: DeviceSessionKey
    nonisolated let displayName: String
    nonisolated let serial: String?

    private let claimed: ClaimedInterfaces
    private let transport: EncapsulatedEP0Transport
    private let controlSession: RNDISControlSession
    private let onFatal: @Sendable (DeviceSessionKey, String) -> Void

    private var phase: Phase = .initializing
    private var capabilities: RNDISControlSession.DeviceCapabilities?
    private var macAddress: [UInt8] = []
    private var linkUp = true
    private var backend: FethBackend?
    private var dataPath: BulkDataPath?
    private var interfaceName: String?
    private var networkSetupTask: Task<Void, Never>?

    init(
        key: DeviceSessionKey,
        displayName: String,
        serial: String?,
        claimed: ClaimedInterfaces,
        onFatal: @escaping @Sendable (DeviceSessionKey, String) -> Void
    ) {
        self.key = key
        self.displayName = displayName
        self.serial = serial
        self.claimed = claimed
        self.onFatal = onFatal
        let transport = EncapsulatedEP0Transport(
            interface: claimed.control,
            interfaceNumber: claimed.controlInterfaceNumber,
            configurationDescriptor: claimed.configurationDescriptor
        )
        self.transport = transport
        self.controlSession = RNDISControlSession(
            transport: transport,
            log: { DaemonLog.debug(.rndis, $0) }
        )
    }

    func bringUp() async {
        DaemonLog.info(.rndis, "[\(displayName)] bringing up RNDIS control plane")
        transport.startInterruptPump()
        do {
            do {
                try await establishControlPlane()
            } catch {
                // The kext's recovery ladder: a wedged device (stale state from a
                // killed host) often answers again after REMOTE_NDIS_RESET_MSG.
                DaemonLog.info(.rndis, "[\(displayName)] control bring-up failed (\(error)); trying RESET recovery")
                try await controlSession.reset()
                try await establishControlPlane()
            }

            guard let dataInterface = claimed.data else {
                phase = .failed
                DaemonLog.error(.rndis, "[\(displayName)] no data interface claimed; cannot start the data path")
                return
            }

            guard let caps = capabilities else {
                phase = .failed
                DaemonLog.error(.rndis, "[\(displayName)] control plane finished without capabilities")
                return
            }
            let backend = FethBackend()
            backend.deviceSerial = serial
            let dataPath = try BulkDataPath(
                dataInterface: dataInterface,
                interfaceNumber: claimed.controlInterfaceNumber + 1,
                configurationDescriptor: claimed.configurationDescriptor,
                capabilities: caps,
                backend: backend,
                configuration: SettingsStore.load()
            )
            let name = try backend.attach(
                macAddress: macAddress,
                mtu: 1500,
                onOutboundFrame: { [weak dataPath] frame in
                    dataPath?.sendFrame(frame)
                }
            )
            let key = key
            let onFatal = onFatal
            dataPath.start(onFatalError: { message in
                onFatal(key, message)
            })
            self.backend = backend
            self.dataPath = dataPath
            self.interfaceName = name
            phase = .up
            DaemonLog.info(.rndis, String(
                format: "[%@] up on %@: host MAC %@, maxTransfer %d, maxPackets %d, link %@",
                displayName, name, macText(macAddress), caps.maxTransferSize,
                caps.maxPacketsPerTransfer,
                linkUp ? "connected" : "disconnected"
            ))
            networkSetupTask = Task { [backend] in
                await backend.completeNetworkSetup()
            }
        } catch {
            phase = .failed
            DaemonLog.error(.rndis, "[\(displayName)] bring-up failed: \(error)")
        }
    }

    private func establishControlPlane() async throws {
        let caps = try await controlSession.initialize()
        capabilities = caps
        macAddress = try await controlSession.queryPermanentMACAddress()
        if let connected = await controlSession.queryMediaConnected() {
            linkUp = connected
        }
        try await controlSession.setPacketFilter(RNDIS.DEFAULT_FILTER)
    }

    func tearDown(reason: String) async {
        guard phase != .tornDown else { return }
        let wasUp = phase == .up
        phase = .tornDown
        networkSetupTask?.cancel()
        dataPath?.stop()
        backend?.detach()
        if wasUp {
            await controlSession.halt()
        }
        transport.shutdown()
        claimed.data?.destroy()
        claimed.control.destroy()
        claimed.device?.destroy()
        DaemonLog.info(.rndis, "[\(displayName)] torn down (\(reason))")
    }

    func snapshot() -> Snapshot {
        let stats = dataPath?.statistics()
        // Media-connect indications ride the interrupt pipe, which stays
        // disabled on gadgets that wedge it; received frames are the ground
        // truth that the link works.
        let effectiveLinkUp = linkUp || (stats?.rxBytes ?? 0) > 0
        return Snapshot(
            id: "\(key.deviceRegistryID):\(key.controlInterfaceNumber)",
            displayName: displayName,
            serial: serial,
            phase: phase,
            macAddress: macAddress,
            linkUp: effectiveLinkUp,
            interfaceName: interfaceName,
            rxBytes: stats?.rxBytes ?? 0,
            txBytes: stats?.txBytes ?? 0
        )
    }

    func benchmarkContext() -> BenchmarkContext? {
        guard phase == .up, let dataPath, let backend, let interfaceName else { return nil }
        return BenchmarkContext(
            dataPath: dataPath,
            sourceMAC: macAddress,
            interfaceName: interfaceName,
            router: backend.currentRouter()
        )
    }
}
