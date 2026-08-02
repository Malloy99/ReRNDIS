// SPDX-License-Identifier: GPL-2.0-or-later
// Owns every DeviceSession, dedupes hotplug double-fires, and reaps sessions
// when their underlying service terminates. Two attach paths: composite devices
// arrive as matched interfaces; Samsung S7 Edge style devices declare RNDIS at
// the device level and need a configuration walk first.

import Foundation
import IOKit
@preconcurrency import IOUSBHost
import ReRNDISShared
import RNDISCore

actor DeviceRegistry {
    private var sessions: [DeviceSessionKey: DeviceSession] = [:]
    private var enabled = true
    private var rescanHook: (@Sendable () -> Void)?

    private func syncAttachedSerials() {
        UplinkPreference.shared.setAttached(Set(sessions.values.compactMap(\.serial)))
    }

    var isEnabled: Bool { enabled }

    func setRescanHook(_ hook: @escaping @Sendable () -> Void) {
        rescanHook = hook
    }

    func setInitialEnabled(_ value: Bool) {
        enabled = value
    }

    func setEnabled(_ value: Bool) async {
        guard enabled != value else { return }
        enabled = value
        if value {
            DaemonLog.info(.lifecycle, "enabled: rescanning for RNDIS devices")
            rescanHook?()
        } else {
            DaemonLog.info(.lifecycle, "disabled: tearing down active sessions")
            await reapAll(reason: "disabled by user")
        }
    }

    func handle(_ event: USBWatchEvent) async {
        guard enabled else {
            switch event {
            case .interfaceCandidate(let service, _), .deviceCandidate(let service):
                IOObjectRelease(service)
            }
            return
        }
        switch event {
        case .interfaceCandidate(let service, let triple):
            await attachInterface(service: service, triple: triple)
        case .deviceCandidate(let service):
            await attachDeviceLevel(service: service)
        }
    }

    func reap(key: DeviceSessionKey, reason: String) async {
        guard let session = sessions.removeValue(forKey: key) else { return }
        syncAttachedSerials()
        await session.tearDown(reason: reason)
    }

    func reapAll(reason: String) async {
        let all = sessions
        sessions.removeAll()
        syncAttachedSerials()
        for session in all.values {
            await session.tearDown(reason: reason)
        }
    }

    func snapshots() async -> [DeviceSession.Snapshot] {
        var result: [DeviceSession.Snapshot] = []
        for session in sessions.values {
            result.append(await session.snapshot())
        }
        return result
    }

    func applyConfiguration(_ configuration: DaemonConfiguration) async -> String? {
        let clamped = configuration.clamped()
        let current = SettingsStore.load()
        do {
            try SettingsStore.save(clamped)
        } catch {
            return "settings not saved: \(error.localizedDescription)"
        }
        UplinkPreference.shared.setPreferred(clamped.preferredDevice)
        DaemonLog.info(.lifecycle, "configuration: txMode \(clamped.txMode.rawValue), rxReaders \(clamped.rxReaders), "
            + "autoStart \(clamped.autoStartsOnBoot), preferred \(clamped.preferredDevice ?? "none")")
        if !clamped.sharesDataPlane(with: current), enabled {
            await reapAll(reason: "configuration changed")
            rescanHook?()
        }
        return nil
    }

    func runBenchmark(deviceID: String?) async -> BenchmarkResult {
        let preferred = SettingsStore.load().preferredDevice
        var fallback: DeviceSession?
        for session in sessions.values {
            if let deviceID {
                let snapshot = await session.snapshot()
                if snapshot.id == deviceID || snapshot.serial == deviceID {
                    fallback = session
                    break
                }
            } else if session.serial != nil, session.serial == preferred {
                fallback = session
                break
            } else if fallback == nil {
                fallback = session
            }
        }
        guard let chosen = fallback, let context = await chosen.benchmarkContext() else {
            return .failure(deviceID == nil ? "no active device" : "device not found")
        }
        return await Task.detached(priority: .userInitiated) {
            TetherBenchmark.run(context)
        }.value
    }

    // MARK: - Interface-level path (stock Android and Linux gadgets)

    private func attachInterface(service: io_service_t, triple: USBInterfaceTriple) async {
        defer { IOObjectRelease(service) }

        guard let interfaceNumber: Int = ServiceProperties.value(service, "bInterfaceNumber") else {
            DaemonLog.error(.usb, "matched interface without bInterfaceNumber; ignoring")
            return
        }
        let device = ServiceProperties.parentDevice(of: service)
        guard device != 0 else {
            DaemonLog.error(.usb, "matched interface without parent device; ignoring")
            return
        }
        defer { IOObjectRelease(device) }

        let key = DeviceSessionKey(
            deviceRegistryID: ServiceProperties.registryEntryID(device),
            controlInterfaceNumber: UInt8(interfaceNumber)
        )
        guard sessions[key] == nil else { return }

        let name = ServiceProperties.displayName(ofDevice: device)
        DaemonLog.info(.usb, String(
            format: "%@: RNDIS control interface #%d (%d/%d/%d)",
            name, interfaceNumber,
            Int(triple.interfaceClass), Int(triple.interfaceSubclass), Int(triple.interfaceProtocol)
        ))

        let dataService = ServiceProperties.interfaceChild(of: device, number: interfaceNumber + 1)
        defer { if dataService != 0 { IOObjectRelease(dataService) } }

        startSession(
            key: key,
            name: name,
            serial: ServiceProperties.serialNumber(ofDevice: device),
            controlService: service,
            dataService: dataService,
            deviceClient: nil
        )
    }

    // MARK: - Device-level path (bDeviceClass 224/0/0)

    private func attachDeviceLevel(service: io_service_t) async {
        defer { IOObjectRelease(service) }

        let deviceID = ServiceProperties.registryEntryID(service)
        guard !sessions.keys.contains(where: { $0.deviceRegistryID == deviceID }) else { return }
        let name = ServiceProperties.displayName(ofDevice: service)
        DaemonLog.info(.usb, "\(name): device-level RNDIS candidate; scanning configurations")

        let ioQueue = DispatchQueue(label: "be.zvz.rerndis.device.\(deviceID)")
        let deviceClient: IOUSBHostDevice
        do {
            deviceClient = try IOUSBHostDevice(
                __ioService: service,
                options: [],
                queue: ioQueue,
                interestHandler: nil
            )
        } catch {
            DaemonLog.error(.usb, "\(name): device open failed: \(error)")
            return
        }

        guard let pair = firstRNDISPair(in: deviceClient) else {
            DaemonLog.info(.usb, "\(name): no RNDIS interface pair in any configuration; ignoring")
            deviceClient.destroy()
            return
        }

        do {
            // matchInterfaces false: nubs appear, kernel driver matching
            // stays out of the way.
            try deviceClient.__configure(withValue: Int(pair.configurationValue), matchInterfaces: false)
        } catch {
            DaemonLog.error(.usb, "\(name): setConfiguration(\(pair.configurationValue)) failed: \(error)")
            deviceClient.destroy()
            return
        }

        let (controlService, dataService) = await waitForInterfaceServices(device: service, pair: pair)
        defer {
            if controlService != 0 { IOObjectRelease(controlService) }
            if dataService != 0 { IOObjectRelease(dataService) }
        }
        guard controlService != 0 else {
            DaemonLog.error(.usb, "\(name): interface nubs never appeared after configuration")
            deviceClient.destroy()
            return
        }

        let key = DeviceSessionKey(deviceRegistryID: deviceID, controlInterfaceNumber: pair.controlInterfaceNumber)
        guard sessions[key] == nil else {
            deviceClient.destroy()
            return
        }
        DaemonLog.info(.usb, "\(name): configured value \(pair.configurationValue), control #\(pair.controlInterfaceNumber)")
        startSession(
            key: key,
            name: name,
            serial: ServiceProperties.serialNumber(ofDevice: service),
            controlService: controlService,
            dataService: dataService,
            deviceClient: deviceClient
        )
    }

    private func firstRNDISPair(in deviceClient: IOUSBHostDevice) -> RNDISMatching.InterfacePair? {
        guard let descriptor = deviceClient.deviceDescriptor else { return nil }
        for index in 0..<Int(descriptor.pointee.bNumConfigurations) {
            guard let config = try? deviceClient.configurationDescriptor(with: index) else { continue }
            let blob = [UInt8](Data(bytes: UnsafeRawPointer(config), count: Int(config.pointee.wTotalLength)))
            if let pair = RNDISMatching.findPairs(inConfigurationDescriptor: blob).first {
                return pair
            }
        }
        return nil
    }

    /// Interface nubs are not guaranteed to appear immediately after
    /// configuration; poll briefly for both.
    private func waitForInterfaceServices(
        device: io_service_t,
        pair: RNDISMatching.InterfacePair
    ) async -> (control: io_service_t, data: io_service_t) {
        var control: io_service_t = 0
        var data: io_service_t = 0
        for _ in 0..<40 {
            if control == 0 {
                control = ServiceProperties.interfaceChild(of: device, number: Int(pair.controlInterfaceNumber))
            }
            if data == 0 {
                data = ServiceProperties.interfaceChild(of: device, number: Int(pair.controlInterfaceNumber) + 1)
            }
            if control != 0 && data != 0 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return (control, data)
    }

    // MARK: - Shared claim path

    // swiftlint:disable:next function_parameter_count
    private func startSession(
        key: DeviceSessionKey,
        name: String,
        serial: String?,
        controlService: io_service_t,
        dataService: io_service_t,
        deviceClient: IOUSBHostDevice?
    ) {
        let ioQueue = DispatchQueue(label: "be.zvz.rerndis.io.\(key.deviceRegistryID).\(key.controlInterfaceNumber)")

        let control: IOUSBHostInterface
        do {
            control = try IOUSBHostInterface(
                __ioService: controlService,
                options: [],
                queue: ioQueue,
                interestHandler: terminationHandler(for: key)
            )
        } catch {
            DaemonLog.error(.usb, "\(name): control interface claim failed: \(error)")
            deviceClient?.destroy()
            return
        }

        var dataInterface: IOUSBHostInterface?
        if dataService != 0 {
            do {
                dataInterface = try IOUSBHostInterface(
                    __ioService: dataService,
                    options: [],
                    queue: ioQueue,
                    interestHandler: nil
                )
            } catch {
                DaemonLog.error(.usb, "\(name): data interface claim failed: \(error)")
            }
        } else {
            DaemonLog.error(.usb, "\(name): no data interface at #\(key.controlInterfaceNumber + 1); control-only session")
        }

        let descriptor = control.configurationDescriptor
        let blob = [UInt8](Data(
            bytes: UnsafeRawPointer(descriptor),
            count: Int(descriptor.pointee.wTotalLength)
        ))

        let session = DeviceSession(
            key: key,
            displayName: name,
            serial: serial,
            claimed: ClaimedInterfaces(
                control: control,
                data: dataInterface,
                device: deviceClient,
                controlInterfaceNumber: key.controlInterfaceNumber,
                configurationDescriptor: blob
            ),
            onFatal: { [weak self] key, reason in
                guard let self else { return }
                Task {
                    await self.reap(key: key, reason: reason)
                }
            }
        )
        sessions[key] = session
        syncAttachedSerials()
        Task {
            await session.bringUp()
        }
    }

    private func terminationHandler(
        for key: DeviceSessionKey
    ) -> @Sendable (IOUSBHostObject, UInt32, UnsafeMutableRawPointer?) -> Void {
        { [weak self] _, messageType, _ in
            guard messageType == kIOMessageServiceIsTerminatedValue, let self else { return }
            Task {
                await self.reap(key: key, reason: "USB service terminated")
            }
        }
    }
}
