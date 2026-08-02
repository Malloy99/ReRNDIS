// SPDX-License-Identifier: GPL-2.0-or-later
// Hotplug matching for the RNDIS shapes. First-match notifications only:
// per-device termination is observed by each session's interest handler, the
// way the kext relied on willTerminate.

import Foundation
import IOKit
import RNDISCore

enum USBWatchEvent: Sendable {
    case interfaceCandidate(service: io_service_t, triple: USBInterfaceTriple)
    case deviceCandidate(service: io_service_t)
}

final class USBWatcher: @unchecked Sendable {
    typealias Handler = @Sendable (USBWatchEvent) -> Void

    /// refcon target for the C callback; also carries which rule fired.
    private final class Registration {
        unowned let watcher: USBWatcher
        let triple: USBInterfaceTriple?

        init(watcher: USBWatcher, triple: USBInterfaceTriple?) {
            self.watcher = watcher
            self.triple = triple
        }
    }

    private let notifyPort: IONotificationPortRef
    private let queue = DispatchQueue(label: "be.zvz.rerndis.usb-watcher")
    private let handler: Handler
    private var registrations: [Registration] = []
    private var iterators: [io_iterator_t] = []

    init?(handler: @escaping Handler) {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        self.notifyPort = port
        self.handler = handler
        IONotificationPortSetDispatchQueue(port, queue)

        for triple in RNDISMatching.controlTriples {
            arm(matching: Self.interfaceMatching(triple), triple: triple)
        }
        arm(matching: Self.deviceMatching(), triple: nil)
    }

    private static func interfaceMatching(_ triple: USBInterfaceTriple) -> NSMutableDictionary {
        let matching = IOServiceMatching("IOUSBHostInterface")! as NSMutableDictionary
        matching["bInterfaceClass"] = Int(triple.interfaceClass)
        matching["bInterfaceSubClass"] = Int(triple.interfaceSubclass)
        matching["bInterfaceProtocol"] = Int(triple.interfaceProtocol)
        return matching
    }

    private static func deviceMatching() -> NSMutableDictionary {
        let matching = IOServiceMatching("IOUSBHostDevice")! as NSMutableDictionary
        matching["bDeviceClass"] = 224
        matching["bDeviceSubClass"] = 0
        matching["bDeviceProtocol"] = 0
        return matching
    }

    /// Re-delivers already-attached devices. First-match notifications fire only
    /// once per service instance, so re-enabling after a disable needs a scan.
    func rescan() {
        queue.async { [self] in
            for triple in RNDISMatching.controlTriples {
                scanExisting(matching: Self.interfaceMatching(triple), triple: triple)
            }
            scanExisting(matching: Self.deviceMatching(), triple: nil)
        }
    }

    private func scanExisting(matching: NSMutableDictionary, triple: USBInterfaceTriple?) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        drain(iterator: iterator, triple: triple)
    }

    deinit {
        for iterator in iterators {
            IOObjectRelease(iterator)
        }
        IONotificationPortDestroy(notifyPort)
    }

    private func arm(matching: NSMutableDictionary, triple: USBInterfaceTriple?) {
        let registration = Registration(watcher: self, triple: triple)
        registrations.append(registration)

        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let registration = Unmanaged<Registration>.fromOpaque(refcon).takeUnretainedValue()
            registration.watcher.drain(iterator: iterator, triple: registration.triple)
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
            notifyPort,
            kIOFirstMatchNotification,
            matching,
            callback,
            Unmanaged.passUnretained(registration).toOpaque(),
            &iterator
        )
        guard result == KERN_SUCCESS else {
            DaemonLog.error(.usb, "IOServiceAddMatchingNotification failed: \(result)")
            return
        }
        iterators.append(iterator)
        // Draining arms the notification and delivers already-attached devices.
        drain(iterator: iterator, triple: triple)
    }

    private func drain(iterator: io_iterator_t, triple: USBInterfaceTriple?) {
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            let rule = triple.map { "\($0.interfaceClass)/\($0.interfaceSubclass)/\($0.interfaceProtocol)" } ?? "device-level"
            DaemonLog.debug(.usb, "first-match notification: service \(service), rule \(rule)")
            if let triple {
                handler(.interfaceCandidate(service: service, triple: triple))
            } else {
                handler(.deviceCandidate(service: service))
            }
        }
    }
}
