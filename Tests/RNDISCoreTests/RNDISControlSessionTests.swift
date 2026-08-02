// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import RNDISCore

private func le32(_ values: [UInt32]) -> [UInt8] {
    values.flatMap { value in
        (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) }
    }
}

/// Scripted EP0 transport: pops one read result per readEncapsulated call.
private actor MockTransport: RNDISEncapsulatedTransport {
    private(set) var sentMessages: [[UInt8]] = []
    private var reads: [[UInt8]?]

    init(reads: [[UInt8]?]) {
        self.reads = reads
    }

    func sendEncapsulated(_ message: Data) async throws {
        sentMessages.append([UInt8](message))
    }

    func readEncapsulated() async throws -> [UInt8]? {
        reads.isEmpty ? nil : reads.removeFirst()
    }

    func waitResponseAvailable(timeoutMilliseconds: Int) async {}
}

@Suite struct RNDISControlSessionTests {
    @Test func initializeHappyPath() async throws {
        let initComplete = le32([0x8000_0002, 52, 1, 0, 1, 0, 1, 0, 10, 15800, 0, 0, 0])
        let transport = MockTransport(reads: [initComplete])
        let session = RNDISControlSession(transport: transport)
        let caps = try await session.initialize()
        #expect(caps == .init(maxTransferSize: 15800, maxPacketsPerTransfer: 10, packetAlignmentFactor: 0))
    }

    @Test func deviceFailureStatusThrows() async {
        let failed = le32([0x8000_0002, 52, 1, 0xC000_0001, 1, 0, 1, 0, 1, 4096, 0, 0, 0])
        let session = RNDISControlSession(transport: MockTransport(reads: [failed]))
        await #expect(throws: RNDISSessionError.deviceReportedFailure(status: 0xC000_0001)) {
            _ = try await session.initialize()
        }
    }

    @Test func interleavedKeepaliveGetsRepliedAndCommandStillCompletes() async throws {
        let keepalive = le32([8, 12, 99])
        let setComplete = le32([0x8000_0005, 16, 1, 0])
        let transport = MockTransport(reads: [keepalive, setComplete])
        let session = RNDISControlSession(transport: transport)
        try await session.setPacketFilter(RNDIS.DEFAULT_FILTER)

        let sent = await transport.sentMessages
        #expect(sent.count == 2)
        #expect(sent[1] == le32([0x8000_0008, 16, 99, 0]))
    }

    @Test func indicateStatusYieldsLinkEvent() async throws {
        final class EventBox: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [RNDISControlSession.LinkEvent] = []
            func append(_ event: RNDISControlSession.LinkEvent) {
                lock.lock()
                storage.append(event)
                lock.unlock()
            }
            var events: [RNDISControlSession.LinkEvent] {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
        }

        let disconnect = le32([7, 20, 0x4001_000C, 0, 0])
        let queryComplete = le32([0x8000_0004, 24, 1, 0, 0, 0])
        let box = EventBox()
        let session = RNDISControlSession(
            transport: MockTransport(reads: [disconnect, queryComplete]),
            onLinkEvent: { box.append($0) }
        )
        _ = try await session.query(oid: RNDIS.OID_GEN_MEDIA_CONNECT_STATUS)
        #expect(box.events == [.disconnect])
    }

    @Test func silenceTimesOut() async {
        let session = RNDISControlSession(transport: MockTransport(reads: []))
        await #expect(throws: RNDISSessionError.responseTimeout) {
            _ = try await session.query(oid: RNDIS.OID_802_3_PERMANENT_ADDRESS)
        }
    }

    @Test func requestIDsSkipZeroAndMatchStrictly() async throws {
        // First response carries a stale request id and must be ignored; the
        // correct completion follows.
        let stale = le32([0x8000_0004, 24, 42, 0, 0, 0])
        let macBytes: [UInt8] = [0xC6, 0x82, 0x80, 0x98, 0x38, 0xA1]
        let good = le32([0x8000_0004, 30, 1, 0, 6, 16]) + macBytes
        let session = RNDISControlSession(transport: MockTransport(reads: [stale, good]))
        let mac = try await session.queryPermanentMACAddress()
        #expect(mac == macBytes)
    }

    @Test func resetMatchesWithoutRequestID() async throws {
        let resetComplete = le32([0x8000_0006, 16, 0, 1])
        let session = RNDISControlSession(transport: MockTransport(reads: [resetComplete]))
        try await session.reset()
    }
}
