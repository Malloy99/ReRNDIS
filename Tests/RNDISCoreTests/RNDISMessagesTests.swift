// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import RNDISCore

private func le32(_ values: [UInt32]) -> [UInt8] {
    values.flatMap { value in
        (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) }
    }
}

@Suite struct MessageBuilderTests {
    @Test func initializeMessageLayout() {
        let message = [UInt8](RNDISControl.initializeMessage(requestID: 0x0000_0007))
        #expect(message == le32([0x0000_0002, 24, 7, 1, 0, 16384]))
    }

    @Test func queryWithoutPayloadUsesZeroOffset() {
        let message = [UInt8](RNDISControl.queryMessage(requestID: 3, oid: RNDIS.OID_802_3_PERMANENT_ADDRESS))
        #expect(message == le32([0x0000_0004, 28, 3, 0x0101_0101, 0, 0, 0]))
    }

    @Test func setPacketFilterLayout() {
        let message = [UInt8](RNDISControl.setPacketFilterMessage(requestID: 4, filter: RNDIS.DEFAULT_FILTER))
        #expect(message == le32([0x0000_0005, 32, 4, 0x0001_010E, 4, 20, 0, 0x0000_002D]))
    }

    @Test func defaultFilterMatchesKextValue() {
        #expect(RNDIS.DEFAULT_FILTER == 0x2D)
    }

    @Test func keepaliveCompleteEchoesRequestID() {
        let message = [UInt8](RNDISControl.keepaliveCompleteMessage(requestID: 0xDEAD_BEEF))
        #expect(message == le32([0x8000_0008, 16, 0xDEAD_BEEF, 0]))
    }

    @Test func haltAndResetLayout() {
        #expect([UInt8](RNDISControl.haltMessage(requestID: 9)) == le32([3, 12, 9]))
        #expect([UInt8](RNDISControl.resetMessage()) == le32([6, 12, 0]))
    }
}

@Suite struct MessageParserTests {
    @Test func parsesInitializeComplete() throws {
        let bytes = le32([
            0x8000_0002, 52, 1, 0,
            1, 0, 0x0000_0001, 0x0000_0000,
            1, 16384, 0, 0, 0
        ])
        let message = try RNDISControlMessage.parse(bytes)
        #expect(message == .initializeComplete(
            requestID: 1, status: 0, maxPacketsPerTransfer: 1, maxTransferSize: 16384, packetAlignmentFactor: 0
        ))
    }

    @Test func parsesQueryCompleteInfoWindow() throws {
        var bytes = le32([0x8000_0004, 30, 2, 0, 6, 16])
        bytes += [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        let message = try RNDISControlMessage.parse(bytes)
        #expect(message == .queryComplete(requestID: 2, status: 0, info: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
    }

    @Test func rejectsQueryInfoWindowEscapingMessage() {
        // Claims 6 info bytes at an offset that runs past the claimed message length.
        let bytes = le32([0x8000_0004, 30, 2, 0, 6, 40]) + [UInt8](repeating: 0, count: 8)
        #expect(throws: RNDISParseError.malformedOffsets) {
            _ = try RNDISControlMessage.parse(bytes)
        }
    }

    @Test func rejectsLengthBeyondBuffer() {
        let bytes = le32([0x8000_0004, 200, 2, 0])
        #expect(throws: RNDISParseError.lengthMismatch(claimed: 200, available: 16)) {
            _ = try RNDISControlMessage.parse(bytes)
        }
    }

    @Test func distinguishesKeepaliveFromIndicate() throws {
        // The kext's message switch tested INDICATE twice and never saw KEEPALIVE.
        let keepalive = try RNDISControlMessage.parse(le32([8, 12, 77]))
        #expect(keepalive == .keepalive(requestID: 77))
        let indicate = try RNDISControlMessage.parse(le32([7, 20, 0x4001_000B, 0, 0]))
        #expect(indicate == .indicateStatus(status: RNDIS.STATUS_MEDIA_CONNECT))
    }

    @Test func resetCompleteHasNoRequestID() throws {
        let message = try RNDISControlMessage.parse(le32([0x8000_0006, 16, 0, 1]))
        #expect(message == .resetComplete(status: 0, addressingReset: 1))
    }

    @Test func truncatedBufferThrows() {
        #expect(throws: RNDISParseError.tooShort) {
            _ = try RNDISControlMessage.parse([0x02, 0x00, 0x00])
        }
    }
}
