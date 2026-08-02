// SPDX-License-Identifier: GPL-2.0-or-later
// EP0 encapsulated-command transport over a claimed IOUSBHostInterface, plus the
// RESPONSE_AVAILABLE interrupt listener. Synchronous IOUSBHost calls run on a
// dedicated queue so actors never block on USB.

import Foundation
@preconcurrency import IOUSBHost
import RNDISCore
import Synchronization

/// Counts RESPONSE_AVAILABLE signals from the interrupt endpoint.
final class InterruptSignalBridge: Sendable {
    private let pending = Mutex(0)

    func signal() {
        pending.withLock { $0 += 1 }
    }

    func consume() -> Bool {
        pending.withLock { count in
            guard count > 0 else { return false }
            count -= 1
            return true
        }
    }
}

final class EncapsulatedEP0Transport: RNDISEncapsulatedTransport, @unchecked Sendable {
    private struct PumpState {
        var interruptPipe: IOUSBHostPipe?
        var stopped = false
        var interruptActive = false
    }

    private let interface: IOUSBHostInterface
    private let interfaceNumber: UInt8
    private let configurationDescriptor: [UInt8]
    private let ep0Queue: DispatchQueue
    private let signals = InterruptSignalBridge()
    private let pumpState = Mutex(PumpState())

    init(interface: IOUSBHostInterface, interfaceNumber: UInt8, configurationDescriptor: [UInt8]) {
        self.interface = interface
        self.interfaceNumber = interfaceNumber
        self.configurationDescriptor = configurationDescriptor
        self.ep0Queue = DispatchQueue(label: "be.zvz.rerndis.ep0.\(interfaceNumber)")
    }

    var hasInterruptEndpoint: Bool {
        pumpState.withLock { $0.interruptActive }
    }

    // MARK: - Interrupt listener

    func startInterruptPump() {
        // HACK: async interrupt reads on the shared user client intermittently
        // wedge completion delivery for EP0 transfers; the poll fallback is
        // the reliable path.
        guard ProcessInfo.processInfo.environment["RERNDIS_INTERRUPT_EP"] != nil else {
            DaemonLog.debug(.rndis, "interrupt endpoint listener disabled; poll fallback only")
            return
        }
        guard let endpoint = USBDescriptors.interruptInput(
            forInterface: interfaceNumber,
            inConfigurationDescriptor: configurationDescriptor
        ) else {
            DaemonLog.info(.rndis, "no notification endpoint on interface \(interfaceNumber); poll fallback only")
            return
        }
        do {
            let pipe = try interface.copyPipe(withAddress: Int(endpoint.address))
            pumpState.withLock {
                $0.interruptPipe = pipe
                $0.interruptActive = true
            }
            enqueueInterruptRead(pipe: pipe, size: max(16, endpoint.maxPacketSize))
        } catch {
            DaemonLog.error(.rndis, "interrupt pipe open failed: \(error)")
        }
    }

    private func enqueueInterruptRead(pipe: IOUSBHostPipe, size: Int) {
        let isStopped = pumpState.withLock { $0.stopped }
        guard !isStopped, let buffer = NSMutableData(length: size) else { return }
        do {
            try pipe.enqueueIORequest(with: buffer, completionTimeout: 0) { [weak self] (status: IOReturn, _: Int) in
                guard let self else { return }
                guard status == kIOReturnSuccess else {
                    self.pumpState.withLock { $0.interruptActive = false }
                    DaemonLog.debug(.rndis, "interrupt pipe finished with status \(status)")
                    return
                }
                self.signals.signal()
                // Never re-enqueue from inside the completion handler: it runs on the
                // interface's IO queue and re-entering IOUSBHost from there deadlocks
                // delivery of every other completion on that queue.
                self.ep0Queue.async {
                    self.enqueueInterruptRead(pipe: pipe, size: size)
                }
            }
        } catch {
            DaemonLog.error(.rndis, "interrupt enqueue failed: \(error)")
        }
    }

    func shutdown() {
        let pipe = pumpState.withLock { state -> IOUSBHostPipe? in
            state.stopped = true
            let pipe = state.interruptPipe
            state.interruptPipe = nil
            state.interruptActive = false
            return pipe
        }
        if let pipe {
            try? pipe.__abort(with: .synchronous)
        }
    }

    // MARK: - RNDISEncapsulatedTransport

    func sendEncapsulated(_ message: Data) async throws {
        _ = try await enqueueControlTransfer(
            bmRequestType: 0x21,
            bRequest: 0x00,
            data: NSMutableData(data: message)
        )
    }

    func readEncapsulated() async throws -> [UInt8]? {
        guard let buffer = NSMutableData(length: RNDIS.CONTROL_BUFFER_SIZE) else { return nil }
        let transferred = try await enqueueControlTransfer(
            bmRequestType: 0xA1,
            bRequest: 0x01,
            data: buffer
        )
        guard transferred > 0 else { return nil }
        return [UInt8](Data(bytes: buffer.bytes, count: transferred))
    }

    func waitResponseAvailable(timeoutMilliseconds: Int) async {
        guard hasInterruptEndpoint else { return }
        let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
        while ContinuousClock.now < deadline {
            if signals.consume() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Fully async EP0 transfer. Nothing here ever blocks a thread on USB:
    /// mixing synchronous sendDeviceRequest with async pipe completions on one
    /// user client intermittently wedged completion delivery, so every transfer
    /// goes through the enqueue + completion-handler path.
    private func enqueueControlTransfer(
        bmRequestType: UInt8,
        bRequest: UInt8,
        data: NSMutableData
    ) async throws -> Int {
        let interface = interface
        let wIndex = UInt16(interfaceNumber)
        nonisolated(unsafe) let buffer = data
        return try await withCheckedThrowingContinuation { continuation in
            ep0Queue.async {
                let request = IOUSBDeviceRequest(
                    bmRequestType: bmRequestType,
                    bRequest: bRequest,
                    wValue: 0,
                    wIndex: wIndex,
                    wLength: UInt16(buffer.length)
                )
                do {
                    try interface.__enqueue(
                        request,
                        data: buffer,
                        completionTimeout: 1.0
                    ) { (status: IOReturn, transferred: Int) in
                        // Keep the data phase buffer alive until completion.
                        withExtendedLifetime(buffer) {}
                        if status == kIOReturnSuccess {
                            continuation.resume(returning: transferred)
                        } else {
                            continuation.resume(throwing: USBTransferError(status: status))
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct USBTransferError: Error, CustomStringConvertible {
    let status: IOReturn

    var description: String {
        String(format: "USB transfer failed: IOReturn 0x%08x", status)
    }
}
