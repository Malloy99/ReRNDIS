// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import RNDISCore

@Suite struct AggregationTests {
    private let frameA: [UInt8] = Array(repeating: 0xAA, count: 100)
    private let frameB: [UInt8] = Array(repeating: 0xBB, count: 60)
    private let frameC: [UInt8] = Array(repeating: 0xCC, count: 1500)

    @Test func packsMultipleFramesAndRoundTrips() {
        let (transfer, consumed) = RNDISFraming.aggregateTransfer(
            frames: [frameA, frameB],
            maxTransferBytes: 4096,
            maxPackets: 10,
            alignmentFactor: 0
        )
        #expect(consumed == 2)
        let result = RNDISFraming.deaggregate([UInt8](transfer))
        #expect(result.malformation == nil)
        #expect(result.frames == [frameA, frameB])
    }

    @Test func respectsMaxPackets() {
        let (_, consumed) = RNDISFraming.aggregateTransfer(
            frames: [frameA, frameA, frameA],
            maxTransferBytes: 65536,
            maxPackets: 2,
            alignmentFactor: 0
        )
        #expect(consumed == 2)
    }

    @Test func respectsByteBudgetButAlwaysTakesOneFrame() {
        let (transfer, consumed) = RNDISFraming.aggregateTransfer(
            frames: [frameC, frameC],
            maxTransferBytes: 1600,
            maxPackets: 10,
            alignmentFactor: 0
        )
        #expect(consumed == 1)
        #expect(transfer.count == 44 + frameC.count)
    }

    @Test func alignmentPaddingRoundTrips() {
        // 100-byte frame gives a 144-byte first PDU; factor 3 pads to 8-byte
        // boundaries between PDUs and the previous msg_len must absorb the pad.
        let odd: [UInt8] = Array(repeating: 0xDD, count: 101)
        let (transfer, consumed) = RNDISFraming.aggregateTransfer(
            frames: [odd, frameB, odd],
            maxTransferBytes: 4096,
            maxPackets: 10,
            alignmentFactor: 3
        )
        #expect(consumed == 3)
        let result = RNDISFraming.deaggregate([UInt8](transfer))
        #expect(result.malformation == nil)
        #expect(result.frames == [odd, frameB, odd])
    }
}
