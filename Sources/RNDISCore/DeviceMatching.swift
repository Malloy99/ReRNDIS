// SPDX-License-Identifier: GPL-2.0-or-later
// USB matching rules ported from the kext's four IOKit personalities, expressed
// as pure functions over raw configuration-descriptor bytes so they are testable
// without hardware.

public struct USBInterfaceTriple: Equatable, Sendable {
    public let interfaceClass: UInt8
    public let interfaceSubclass: UInt8
    public let interfaceProtocol: UInt8

    public init(_ interfaceClass: UInt8, _ interfaceSubclass: UInt8, _ interfaceProtocol: UInt8) {
        self.interfaceClass = interfaceClass
        self.interfaceSubclass = interfaceSubclass
        self.interfaceProtocol = interfaceProtocol
    }
}

public enum RNDISMatching {
    /// Stock Android (Wireless Controller / RF / RNDIS), Nokia 7 Plus style
    /// "RNDIS over Ethernet" (Miscellaneous / 4 / 1), and the Linux gadget
    /// f_rndis used by BeagleBone and Raspberry Pi (2 / 2 / 255).
    public static let controlTriples: [USBInterfaceTriple] = [
        USBInterfaceTriple(224, 1, 3),
        USBInterfaceTriple(239, 4, 1),
        USBInterfaceTriple(2, 2, 255)
    ]

    /// CDC Data class carried by every RNDIS data interface.
    public static let dataInterfaceClass: UInt8 = 10

    /// Samsung S7 Edge style devices declare the RNDIS shape at the device level
    /// (bDeviceClass 224) and need a configuration walk to find the interfaces.
    public static func isDeviceLevelCandidate(deviceClass: UInt8, deviceSubclass: UInt8, deviceProtocol: UInt8) -> Bool {
        deviceClass == 224 && deviceSubclass == 0 && deviceProtocol == 0
    }

    public static func isControlTriple(_ triple: USBInterfaceTriple) -> Bool {
        controlTriples.contains(triple)
    }

    public struct InterfacePair: Equatable, Sendable {
        public let configurationValue: UInt8
        public let controlInterfaceNumber: UInt8
        public let controlTriple: USBInterfaceTriple

        public init(configurationValue: UInt8, controlInterfaceNumber: UInt8, controlTriple: USBInterfaceTriple) {
            self.configurationValue = configurationValue
            self.controlInterfaceNumber = controlInterfaceNumber
            self.controlTriple = controlTriple
        }
    }

    /// Walks one configuration-descriptor blob and returns every RNDIS
    /// control/data pair: the data interface sits at control number + 1 and
    /// carries the CDC Data class.
    public static func findPairs(inConfigurationDescriptor bytes: [UInt8]) -> [InterfacePair] {
        struct InterfaceDescriptor {
            let number: UInt8
            let alternateSetting: UInt8
            let triple: USBInterfaceTriple
        }
        var configurationValue: UInt8 = 0
        var interfaces: [InterfaceDescriptor] = []

        var offset = 0
        while offset + 2 <= bytes.count {
            let length = Int(bytes[offset])
            let descriptorType = bytes[offset + 1]
            guard length >= 2, offset + length <= bytes.count else { break }
            if descriptorType == 2, length >= 9 {
                configurationValue = bytes[offset + 5]
            } else if descriptorType == 4, length >= 9 {
                interfaces.append(InterfaceDescriptor(
                    number: bytes[offset + 2],
                    alternateSetting: bytes[offset + 3],
                    triple: USBInterfaceTriple(bytes[offset + 5], bytes[offset + 6], bytes[offset + 7])
                ))
            }
            offset += length
        }

        var pairs: [InterfacePair] = []
        for interface in interfaces where interface.alternateSetting == 0 && isControlTriple(interface.triple) {
            let hasDataSibling = interfaces.contains { candidate in
                candidate.number == interface.number + 1 && candidate.triple.interfaceClass == dataInterfaceClass
            }
            guard hasDataSibling else { continue }
            pairs.append(InterfacePair(
                configurationValue: configurationValue,
                controlInterfaceNumber: interface.number,
                controlTriple: interface.triple
            ))
        }
        return pairs
    }
}
