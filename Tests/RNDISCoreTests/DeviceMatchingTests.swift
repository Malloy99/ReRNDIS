// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
@testable import RNDISCore

private struct IfSpec {
    let number: UInt8
    let cls: UInt8
    let sub: UInt8
    let proto: UInt8

    init(_ number: UInt8, _ cls: UInt8, _ sub: UInt8, _ proto: UInt8) {
        self.number = number
        self.cls = cls
        self.sub = sub
        self.proto = proto
    }
}

private func configDescriptor(value: UInt8, interfaces: [IfSpec]) -> [UInt8] {
    var body: [UInt8] = []
    for spec in interfaces {
        let (number, cls, sub, proto) = (spec.number, spec.cls, spec.sub, spec.proto)
        body += [9, 4, number, 0, 0, cls, sub, proto, 0]
        // One dummy bulk endpoint so the blob is shaped like the real thing.
        body += [7, 5, 0x81, 0x02, 0x00, 0x02, 0x00]
    }
    let total = UInt16(9 + body.count)
    let header: [UInt8] = [9, 2, UInt8(total & 0xFF), UInt8(total >> 8), UInt8(interfaces.count), value, 0, 0xC0, 0]
    return header + body
}

@Suite struct DeviceMatchingTests {
    @Test func matchesStockAndroidPair() {
        let blob = configDescriptor(value: 1, interfaces: [
            IfSpec(0, 224, 1, 3),
            IfSpec(1, 10, 0, 0)
        ])
        let pairs = RNDISMatching.findPairs(inConfigurationDescriptor: blob)
        #expect(pairs == [RNDISMatching.InterfacePair(
            configurationValue: 1,
            controlInterfaceNumber: 0,
            controlTriple: USBInterfaceTriple(224, 1, 3)
        )])
    }

    @Test func matchesLinuxGadgetAndNokiaShapes() {
        let gadget = configDescriptor(value: 1, interfaces: [IfSpec(0, 2, 2, 255), IfSpec(1, 10, 0, 0)])
        #expect(RNDISMatching.findPairs(inConfigurationDescriptor: gadget).count == 1)
        let nokia = configDescriptor(value: 1, interfaces: [IfSpec(0, 239, 4, 1), IfSpec(1, 10, 0, 0)])
        #expect(RNDISMatching.findPairs(inConfigurationDescriptor: nokia).count == 1)
    }

    @Test func requiresDataSiblingAtPlusOne() {
        let missingData = configDescriptor(value: 1, interfaces: [IfSpec(0, 224, 1, 3), IfSpec(2, 10, 0, 0)])
        #expect(RNDISMatching.findPairs(inConfigurationDescriptor: missingData).isEmpty)
        let wrongClass = configDescriptor(value: 1, interfaces: [IfSpec(0, 224, 1, 3), IfSpec(1, 8, 6, 80)])
        #expect(RNDISMatching.findPairs(inConfigurationDescriptor: wrongClass).isEmpty)
    }

    @Test func skipsUnrelatedInterfacesAndFindsLaterPair() {
        // Phone-style composite: MTP, ADB, then RNDIS at 2/3.
        let blob = configDescriptor(value: 1, interfaces: [
            IfSpec(0, 6, 1, 1),
            IfSpec(1, 255, 66, 1),
            IfSpec(2, 224, 1, 3),
            IfSpec(3, 10, 0, 0)
        ])
        let pairs = RNDISMatching.findPairs(inConfigurationDescriptor: blob)
        #expect(pairs.count == 1)
        #expect(pairs.first?.controlInterfaceNumber == 2)
    }

    @Test func findsMultiplePairsInOneConfiguration() {
        let blob = configDescriptor(value: 3, interfaces: [
            IfSpec(0, 224, 1, 3), IfSpec(1, 10, 0, 0),
            IfSpec(2, 2, 2, 255), IfSpec(3, 10, 0, 0)
        ])
        let pairs = RNDISMatching.findPairs(inConfigurationDescriptor: blob)
        #expect(pairs.count == 2)
        #expect(pairs.map(\.configurationValue) == [3, 3])
    }

    @Test func toleratesTruncatedBlob() {
        let blob = configDescriptor(value: 1, interfaces: [IfSpec(0, 224, 1, 3), IfSpec(1, 10, 0, 0)])
        #expect(RNDISMatching.findPairs(inConfigurationDescriptor: Array(blob.prefix(11))).isEmpty)
    }

    @Test func deviceLevelCandidateRule() {
        #expect(RNDISMatching.isDeviceLevelCandidate(deviceClass: 224, deviceSubclass: 0, deviceProtocol: 0))
        #expect(!RNDISMatching.isDeviceLevelCandidate(deviceClass: 224, deviceSubclass: 1, deviceProtocol: 3))
    }
}
