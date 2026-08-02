// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import RNDISCore

private func le32(_ values: [UInt32]) -> [UInt8] {
    values.flatMap { value in
        (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) }
    }
}

private func packet(_ frame: [UInt8]) -> [UInt8] {
    le32([1, UInt32(44 + frame.count), 36, UInt32(frame.count), 0, 0, 0, 0, 0, 0, 0]) + frame
}

@Suite struct FramingTests {
    @Test func packetMessageLayout() {
        let frame: [UInt8] = [0xDE, 0xAD, 0xBE]
        #expect([UInt8](RNDISFraming.packetMessage(for: frame)) == packet(frame))
    }

    @Test func shortPacketPaddingOnlyOnExactMultiple() {
        let exact = Data(repeating: 0xAB, count: 1024)
        #expect(RNDISFraming.paddedForShortPacket(exact, maxPacketSize: 512).count == 1025)
        let inexact = Data(repeating: 0xAB, count: 1023)
        #expect(RNDISFraming.paddedForShortPacket(inexact, maxPacketSize: 512).count == 1023)
        #expect(RNDISFraming.paddedForShortPacket(Data(), maxPacketSize: 512).isEmpty)
    }

    @Test func deaggregatesMultiplePDUs() {
        let first: [UInt8] = Array(repeating: 0x11, count: 60)
        let second: [UInt8] = Array(repeating: 0x22, count: 14)
        let result = RNDISFraming.deaggregate(packet(first) + packet(second))
        #expect(result.malformation == nil)
        #expect(result.frames == [first, second])
    }

    @Test func ignoresTrailingPadBytes() {
        // A device may pad the tail short of a full header; the remainder is ignored.
        let frame: [UInt8] = Array(repeating: 0x33, count: 20)
        let result = RNDISFraming.deaggregate(packet(frame) + [0, 0, 0])
        #expect(result.malformation == nil)
        #expect(result.frames == [frame])
    }

    @Test func stopsAtUnexpectedMessageType() {
        let frame: [UInt8] = Array(repeating: 0x44, count: 20)
        let bogus = le32([7, 44, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let result = RNDISFraming.deaggregate(packet(frame) + bogus)
        #expect(result.frames == [frame])
        #expect(result.malformation != nil)
    }

    @Test func rejectsMessageLengthEscapingTransfer() {
        var bytes = packet(Array(repeating: 0x55, count: 20))
        // Inflate msg_len beyond the actual transfer.
        bytes.replaceSubrange(4..<8, with: le32([4096]))
        let result = RNDISFraming.deaggregate(bytes)
        #expect(result.frames.isEmpty)
        #expect(result.malformation != nil)
    }

    @Test func rejectsDataWindowEscapingMessage() {
        var bytes = packet(Array(repeating: 0x66, count: 20))
        // data_offset pushed so offset + length + 8 > msg_len.
        bytes.replaceSubrange(8..<12, with: le32([48]))
        let result = RNDISFraming.deaggregate(bytes)
        #expect(result.frames.isEmpty)
        #expect(result.malformation != nil)
    }

    @Test func roundTripsThroughOwnEncoder() {
        let frame: [UInt8] = (0..<1500).map { UInt8($0 & 0xFF) }
        let result = RNDISFraming.deaggregate([UInt8](RNDISFraming.packetMessage(for: frame)))
        #expect(result.malformation == nil)
        #expect(result.frames == [frame])
    }
}
