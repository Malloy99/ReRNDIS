// SPDX-License-Identifier: GPL-2.0-or-later
// M0a spike: prove userspace IOUSBHost can claim a phone's RNDIS interfaces and
// complete INITIALIZE plus QUERY(permanent MAC) over EP0. Also dumps the raw
// configuration descriptor for the M1 matching test vectors.

import Foundation
import IOKit
import IOUSBHost
import RNDISCore

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("spike-usb: " + message + "\n").utf8))
    exit(1)
}

// The IOUSBHost convenience constructors are NS_REFINED_FOR_SWIFT with no shipped
// overlay, so matching dictionaries are built by hand with the same keys the
// kext personalities used.
func interfaceMatchingDictionary(cls: Int, sub: Int, proto: Int) -> CFDictionary {
    let dictionary = IOServiceMatching("IOUSBHostInterface")! as NSMutableDictionary
    dictionary["bInterfaceClass"] = cls
    dictionary["bInterfaceSubClass"] = sub
    dictionary["bInterfaceProtocol"] = proto
    return dictionary
}

func deviceMatchingDictionary(cls: Int, sub: Int, proto: Int) -> CFDictionary {
    let dictionary = IOServiceMatching("IOUSBHostDevice")! as NSMutableDictionary
    dictionary["bDeviceClass"] = cls
    dictionary["bDeviceSubClass"] = sub
    dictionary["bDeviceProtocol"] = proto
    return dictionary
}

func services(matching dictionary: CFDictionary) -> [io_service_t] {
    var iterator: io_iterator_t = 0
    let result = IOServiceGetMatchingServices(kIOMainPortDefault, dictionary, &iterator)
    guard result == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var found: [io_service_t] = []
    while true {
        let service = IOIteratorNext(iterator)
        guard service != 0 else { break }
        found.append(service)
    }
    return found
}

func property<T>(_ service: io_service_t, _ key: String) -> T? {
    guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
        return nil
    }
    return value.takeRetainedValue() as? T
}

func parentDevice(of interfaceService: io_service_t) -> io_service_t {
    var parent: io_service_t = 0
    guard IORegistryEntryGetParentEntry(interfaceService, kIOServicePlane, &parent) == KERN_SUCCESS else {
        die("no parent device for interface service")
    }
    return parent
}

func siblingInterface(of device: io_service_t, interfaceNumber: Int) -> io_service_t? {
    var iterator: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    while true {
        let child = IOIteratorNext(iterator)
        guard child != 0 else { break }
        if IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
           let number: Int = property(child, "bInterfaceNumber"),
           number == interfaceNumber {
            return child
        }
        IOObjectRelease(child)
    }
    return nil
}

func macText(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
}

func describe(interface service: io_service_t) -> String {
    let number: Int = property(service, "bInterfaceNumber") ?? -1
    let cls: Int = property(service, "bInterfaceClass") ?? -1
    let sub: Int = property(service, "bInterfaceSubClass") ?? -1
    let proto: Int = property(service, "bInterfaceProtocol") ?? -1
    let device = parentDevice(of: service)
    defer { IOObjectRelease(device) }
    let product: String = property(device, "USB Product Name") ?? "?"
    let vendor: Int = property(device, "idVendor") ?? 0
    let productID: Int = property(device, "idProduct") ?? 0
    return String(
        format: "%@ (%04x:%04x) interface #%d class %d/%d/%d",
        product, vendor, productID, number, cls, sub, proto
    )
}

// MARK: - Encapsulated command transport

final class ControlChannel {
    let interface: IOUSBHostInterface
    let interfaceNumber: Int

    init(interface: IOUSBHostInterface, interfaceNumber: Int) {
        self.interface = interface
        self.interfaceNumber = interfaceNumber
    }

    func sendEncapsulated(_ message: Data) throws {
        let request = IOUSBDeviceRequest(
            bmRequestType: 0x21,
            bRequest: 0x00,
            wValue: 0,
            wIndex: UInt16(interfaceNumber),
            wLength: UInt16(message.count)
        )
        var transferred: UInt = 0
        try interface.__send(
            request,
            data: NSMutableData(data: message),
            bytesTransferred: &transferred,
            completionTimeout: 1.0
        )
    }

    func readEncapsulated() throws -> [UInt8]? {
        guard let buffer = NSMutableData(length: RNDIS.CONTROL_BUFFER_SIZE) else { die("buffer allocation failed") }
        let request = IOUSBDeviceRequest(
            bmRequestType: 0xA1,
            bRequest: 0x01,
            wValue: 0,
            wIndex: UInt16(interfaceNumber),
            wLength: UInt16(RNDIS.CONTROL_BUFFER_SIZE)
        )
        var transferred: UInt = 0
        try interface.__send(
            request,
            data: buffer,
            bytesTransferred: &transferred,
            completionTimeout: 1.0
        )
        guard transferred > 0 else { return nil }
        return [UInt8](Data(bytes: buffer.bytes, count: Int(transferred)))
    }

    /// The kext's poll loop: the device may need time before the response is ready,
    /// and unsolicited messages can arrive interleaved.
    func awaitResponse(matching predicate: (RNDISControlMessage) -> Bool) throws -> RNDISControlMessage {
        for _ in 0..<10 {
            if let bytes = try readEncapsulated(), !bytes.isEmpty {
                let message = try RNDISControlMessage.parse(bytes)
                if predicate(message) { return message }
                print("  (interleaved message: \(message))")
            }
            usleep(20_000)
        }
        die("no matching control response after 10 polls")
    }
}

// MARK: - Main flow

let interfaceRules: [(name: String, cls: Int, sub: Int, proto: Int)] = [
    ("stock Android RNDIS", 224, 1, 3),
    ("RNDIS over Ethernet (Nokia 7 Plus style)", 239, 4, 1),
    ("Linux gadget f_rndis", 2, 2, 255),
]

var candidates: [(rule: String, service: io_service_t)] = []
for rule in interfaceRules {
    let dictionary = interfaceMatchingDictionary(cls: rule.cls, sub: rule.sub, proto: rule.proto)
    for service in services(matching: dictionary) {
        candidates.append((rule.name, service))
    }
}

let deviceLevelMatches = services(matching: deviceMatchingDictionary(cls: 224, sub: 0, proto: 0))

print("interface-level RNDIS candidates: \(candidates.count)")
for candidate in candidates {
    print("  [\(candidate.rule)] \(describe(interface: candidate.service))")
}
print("device-level 224/0/0 candidates: \(deviceLevelMatches.count)")

guard let target = candidates.first else {
    if deviceLevelMatches.isEmpty {
        die("no RNDIS device found. Plug the phone and enable USB tethering, then rerun.")
    }
    die("only a device-level match found; that path lands in M2. Interface claim not exercised.")
}

guard let controlNumber: Int = property(target.service, "bInterfaceNumber") else {
    die("control interface has no bInterfaceNumber property")
}
print("claiming control interface #\(controlNumber) [\(target.rule)] ...")

let queue = DispatchQueue(label: "spike-usb.io")
let controlInterface: IOUSBHostInterface
do {
    controlInterface = try IOUSBHostInterface(
        __ioService: target.service,
        options: [],
        queue: queue,
        interestHandler: nil
    )
} catch {
    die("control interface claim failed: \(error)")
}
print("control interface claimed")

// Dump the configuration descriptor for M1 matching test vectors.
let configDescriptor = controlInterface.configurationDescriptor
let configTotalLength = Int(configDescriptor.pointee.wTotalLength)
let configBlob = Data(bytes: UnsafeRawPointer(configDescriptor), count: configTotalLength)
let configBlobPath = FileManager.default.currentDirectoryPath + "/rndis-config-descriptor.bin"
try? configBlob.write(to: URL(fileURLWithPath: configBlobPath))
print("configuration descriptor (\(configTotalLength) bytes) saved to \(configBlobPath)")

// Claim the data interface too: RNDIS pairs control N with data N+1.
let device = parentDevice(of: target.service)
var dataInterface: IOUSBHostInterface?
if let dataService = siblingInterface(of: device, interfaceNumber: controlNumber + 1) {
    do {
        dataInterface = try IOUSBHostInterface(
            __ioService: dataService,
            options: [],
            queue: queue,
            interestHandler: nil
        )
        print("data interface #\(controlNumber + 1) claimed")
    } catch {
        print("data interface claim failed (continuing, EP0 does not need it): \(error)")
    }
    IOObjectRelease(dataService)
} else {
    print("warning: no sibling data interface #\(controlNumber + 1) visible")
}

let channel = ControlChannel(interface: controlInterface, interfaceNumber: controlNumber)

print("sending REMOTE_NDIS_INITIALIZE_MSG ...")
try channel.sendEncapsulated(RNDISControl.initializeMessage(requestID: 1))
let initReply = try channel.awaitResponse { message in
    if case .initializeComplete = message { return true }
    return false
}
guard case let .initializeComplete(_, status, maxPackets, maxTransfer, alignment) = initReply else {
    die("unreachable")
}
guard status == RNDIS.STATUS_SUCCESS else {
    die(String(format: "INITIALIZE failed with status 0x%08x", status))
}
print(String(
    format: "INITIALIZE_CMPLT: maxPacketsPerTransfer=%u maxTransferSize=%u packetAlignment=%u",
    maxPackets, maxTransfer, alignment
))

print("querying OID_802_3_PERMANENT_ADDRESS ...")
try channel.sendEncapsulated(RNDISControl.queryMessage(requestID: 2, oid: RNDIS.OID_802_3_PERMANENT_ADDRESS))
let macReply = try channel.awaitResponse { message in
    if case .queryComplete = message { return true }
    return false
}
guard case let .queryComplete(_, macStatus, info) = macReply else { die("unreachable") }
guard macStatus == RNDIS.STATUS_SUCCESS, info.count >= 6 else {
    die(String(format: "MAC query failed: status 0x%08x, %d info bytes", macStatus, info.count))
}
print("PASS: device-assigned host MAC \(macText(Array(info.prefix(6))))")

dataInterface?.destroy()
controlInterface.destroy()
IOObjectRelease(device)
exit(0)
