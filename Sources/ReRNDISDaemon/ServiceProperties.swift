// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import IOKit

// iokit_common_msg(0x010); the macro form does not import into Swift.
let kIOMessageServiceIsTerminatedValue: UInt32 = 0xE000_0010

// kUSBHostReturnPipeStalled from the kernel's IOUSBHostFamilyDefinitions.h;
// the userspace framework does not re-export it.
let kUSBHostReturnPipeStalledValue = IOReturn(bitPattern: 0xE000_5000)

// kIOReturnAborted; the function-like macro form does not import into Swift.
let kIOReturnAbortedValue = IOReturn(bitPattern: 0xE000_02EB)

enum ServiceProperties {
    static func value<T>(_ service: io_service_t, _ key: String) -> T? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return raw.takeRetainedValue() as? T
    }

    static func registryEntryID(_ service: io_service_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &id)
        return id
    }

    /// Owned reference to the parent device, or 0.
    static func parentDevice(of interfaceService: io_service_t) -> io_service_t {
        var parent: io_service_t = 0
        guard IORegistryEntryGetParentEntry(interfaceService, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return 0
        }
        return parent
    }

    /// Owned reference to the IOUSBHostInterface child with the given interface
    /// number, or 0 when absent.
    static func interfaceChild(of device: io_service_t, number: Int) -> io_service_t {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }
        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
               let candidate: Int = value(child, "bInterfaceNumber"),
               candidate == number {
                return child
            }
            IOObjectRelease(child)
        }
        return 0
    }

    static func serialNumber(ofDevice device: io_service_t) -> String? {
        let serial: String? = value(device, "USB Serial Number")
        return (serial?.isEmpty ?? true) ? nil : serial
    }

    static func displayName(ofDevice device: io_service_t) -> String {
        let product: String = value(device, "USB Product Name") ?? "USB device"
        if let serial = serialNumber(ofDevice: device) {
            return "\(product) (\(serial))"
        }
        let vendorID: Int = value(device, "idVendor") ?? 0
        let productID: Int = value(device, "idProduct") ?? 0
        return String(format: "%@ (%04x:%04x)", product, vendorID, productID)
    }
}

func macText(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
}
