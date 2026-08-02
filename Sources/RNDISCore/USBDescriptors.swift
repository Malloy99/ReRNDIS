// SPDX-License-Identifier: GPL-2.0-or-later
// Minimal configuration-descriptor walking for the pieces the daemon needs:
// which endpoints belong to an interface's alternate setting 0.

public struct USBEndpoint: Equatable, Sendable {
    public static let transferTypeBulk: UInt8 = 2
    public static let transferTypeInterrupt: UInt8 = 3

    public let address: UInt8
    public let attributes: UInt8
    public let maxPacketSize: Int

    public init(address: UInt8, attributes: UInt8, maxPacketSize: Int) {
        self.address = address
        self.attributes = attributes
        self.maxPacketSize = maxPacketSize
    }

    public var isInput: Bool { address & 0x80 != 0 }
    public var transferType: UInt8 { attributes & 0x03 }
}

public enum USBDescriptors {
    /// Endpoints declared for interface `number`, alternate setting 0, in a raw
    /// configuration-descriptor blob.
    public static func endpoints(forInterface number: UInt8, inConfigurationDescriptor bytes: [UInt8]) -> [USBEndpoint] {
        var endpoints: [USBEndpoint] = []
        var currentInterface: (number: UInt8, alternate: UInt8)?

        var offset = 0
        while offset + 2 <= bytes.count {
            let length = Int(bytes[offset])
            let descriptorType = bytes[offset + 1]
            guard length >= 2, offset + length <= bytes.count else { break }
            if descriptorType == 4, length >= 9 {
                currentInterface = (bytes[offset + 2], bytes[offset + 3])
            } else if descriptorType == 5, length >= 7,
                      let current = currentInterface,
                      current.number == number, current.alternate == 0 {
                let maxPacket = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8
                endpoints.append(USBEndpoint(
                    address: bytes[offset + 2],
                    attributes: bytes[offset + 3],
                    maxPacketSize: maxPacket
                ))
            }
            offset += length
        }
        return endpoints
    }

    public static func interruptInput(forInterface number: UInt8, inConfigurationDescriptor bytes: [UInt8]) -> USBEndpoint? {
        endpoints(forInterface: number, inConfigurationDescriptor: bytes)
            .first { $0.isInput && $0.transferType == USBEndpoint.transferTypeInterrupt }
    }

    public static func bulkPair(
        forInterface number: UInt8,
        inConfigurationDescriptor bytes: [UInt8]
    ) -> (input: USBEndpoint, output: USBEndpoint)? {
        let all = endpoints(forInterface: number, inConfigurationDescriptor: bytes)
        guard
            let input = all.first(where: { $0.isInput && $0.transferType == USBEndpoint.transferTypeBulk }),
            let output = all.first(where: { !$0.isInput && $0.transferType == USBEndpoint.transferTypeBulk })
        else { return nil }
        return (input, output)
    }
}
