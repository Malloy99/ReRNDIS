// SPDX-License-Identifier: GPL-2.0-or-later
// Golden vector captured from a real Samsung Android phone (04e8:6864) in RNDIS
// tethering mode via the M0a spike: RNDIS control (0) + CDC Data (1) + ADB (2).

import Testing
@testable import RNDISCore

private let samsungRNDISConfigHex =
    "0902620003010480fa080b0002e00103070904000001e001030505240010" +
    "0105240100010424020005240600010705820308000909040100020a0000" +
    "0607058102000200070501020002000904020002ff420109070502020002" +
    "0007058302000200"

private func bytes(fromHex hex: String) -> [UInt8] {
    var result: [UInt8] = []
    var iterator = hex.makeIterator()
    while let high = iterator.next(), let low = iterator.next() {
        result.append(UInt8(String([high, low]), radix: 16)!)
    }
    return result
}

@Suite struct CapturedDescriptorTests {
    private let blob = bytes(fromHex: samsungRNDISConfigHex)

    @Test func blobIsIntact() {
        #expect(blob.count == 98)
        #expect(Int(blob[2]) | Int(blob[3]) << 8 == 98)
    }

    @Test func findsExactlyTheRNDISPair() {
        let pairs = RNDISMatching.findPairs(inConfigurationDescriptor: blob)
        #expect(pairs == [RNDISMatching.InterfacePair(
            configurationValue: 1,
            controlInterfaceNumber: 0,
            controlTriple: USBInterfaceTriple(224, 1, 3)
        )])
    }

    @Test func controlInterfaceHasNotificationEndpoint() {
        let interrupt = USBDescriptors.interruptInput(forInterface: 0, inConfigurationDescriptor: blob)
        #expect(interrupt == USBEndpoint(address: 0x82, attributes: 0x03, maxPacketSize: 8))
    }

    @Test func dataInterfaceHasBulkPair() throws {
        let pair = try #require(USBDescriptors.bulkPair(forInterface: 1, inConfigurationDescriptor: blob))
        #expect(pair.input == USBEndpoint(address: 0x81, attributes: 0x02, maxPacketSize: 512))
        #expect(pair.output == USBEndpoint(address: 0x01, attributes: 0x02, maxPacketSize: 512))
    }

    @Test func adbInterfaceIsNotMistakenForRNDIS() {
        // Interface 2 is ADB (255/66/1) with its own bulk pair; the matcher must
        // not pair it and the endpoint walker must keep interfaces separate.
        let endpoints = USBDescriptors.endpoints(forInterface: 2, inConfigurationDescriptor: blob)
        #expect(endpoints.count == 2)
        #expect(USBDescriptors.interruptInput(forInterface: 2, inConfigurationDescriptor: blob) == nil)
    }
}
