// SPDX-License-Identifier: GPL-2.0-or-later
// The daemon runs the pointer-based codecs; these tests pin them against the
// Data/Array wrappers so both stay byte-identical.

import Foundation
import Testing
@testable import RNDISCore

@Suite struct PointerFramingTests {
    private let frames: [[UInt8]] = [
        Array(repeating: 0x11, count: 101),
        Array(repeating: 0x22, count: 1500),
        Array(repeating: 0x33, count: 60)
    ]

    @Test func rangesMatchCopyingDeaggregation() {
        let (transfer, consumed) = RNDISFraming.aggregateTransfer(
            frames: frames, maxTransferBytes: 8192, maxPackets: 10, alignmentFactor: 2
        )
        #expect(consumed == frames.count)
        let bytes = [UInt8](transfer)
        let copied = RNDISFraming.deaggregate(bytes)
        let ranged: [[UInt8]] = bytes.withUnsafeBytes { raw in
            let (ranges, malformation) = RNDISFraming.deaggregateRanges(raw)
            #expect(malformation == nil)
            return ranges.map { Array(bytes[$0.offset..<($0.offset + $0.length)]) }
        }
        #expect(copied.frames == ranged)
        #expect(ranged == frames)
    }

    @Test func writePacketMessageMatchesDataEncoder() {
        let frame = frames[0]
        var buffer = [UInt8](repeating: 0xEE, count: 44 + frame.count)
        let written = buffer.withUnsafeMutableBytes { out in
            frame.withUnsafeBytes { raw in
                RNDISFraming.writePacketMessage(frame: raw, into: out)
            }
        }
        #expect(written == 44 + frame.count)
        #expect(buffer == [UInt8](RNDISFraming.packetMessage(for: frame)))
    }

    @Test func aggregateIntoMatchesDataAggregator() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let pointerResult = buffer.withUnsafeMutableBytes { out in
            RNDISFraming.aggregateInto(out, frames: frames, maxPackets: 2, alignmentFactor: 3)
        }
        let dataResult = RNDISFraming.aggregateTransfer(
            frames: frames, maxTransferBytes: 4096, maxPackets: 2, alignmentFactor: 3
        )
        #expect(pointerResult.consumed == dataResult.consumedFrames)
        #expect(Array(buffer[0..<pointerResult.written]) == [UInt8](dataResult.transfer))
    }

    @Test func zlpPaddedLengthRules() {
        #expect(RNDISFraming.zlpPaddedLength(1024, maxPacketSize: 512) == 1025)
        #expect(RNDISFraming.zlpPaddedLength(1023, maxPacketSize: 512) == 1023)
        #expect(RNDISFraming.zlpPaddedLength(0, maxPacketSize: 512) == 0)
        #expect(RNDISFraming.zlpPaddedLength(512, maxPacketSize: 0) == 512)
    }

    @Test func emptyTransferYieldsNothing() {
        let empty: [UInt8] = []
        let result = empty.withUnsafeBytes { RNDISFraming.deaggregateRanges($0) }
        #expect(result.ranges.isEmpty)
        #expect(result.malformation == nil)
    }
}
