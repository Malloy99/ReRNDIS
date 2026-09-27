// SPDX-License-Identifier: GPL-2.0-or-later
// RNDIS control-plane wire format, host side. Ported from the HoRNDIS kext and
// linux/drivers/net/usb/rndis_host.c. All wire fields are little-endian.
// Buffer offsets inside QUERY/SET messages are relative to the RequestID field,
// which sits 8 bytes into the message.

import Foundation

public enum RNDIS {
    public static let MSG_PACKET: UInt32 = 0x0000_0001
    public static let MSG_INITIALIZE: UInt32 = 0x0000_0002
    public static let MSG_HALT: UInt32 = 0x0000_0003
    public static let MSG_QUERY: UInt32 = 0x0000_0004
    public static let MSG_SET: UInt32 = 0x0000_0005
    public static let MSG_RESET: UInt32 = 0x0000_0006
    public static let MSG_INDICATE_STATUS: UInt32 = 0x0000_0007
    public static let MSG_KEEPALIVE: UInt32 = 0x0000_0008
    public static let MSG_COMPLETION_FLAG: UInt32 = 0x8000_0000

    public static let STATUS_SUCCESS: UInt32 = 0x0000_0000
    public static let STATUS_FAILURE: UInt32 = 0xC000_0001
    public static let STATUS_NOT_SUPPORTED: UInt32 = 0xC000_00BB
    public static let STATUS_MEDIA_CONNECT: UInt32 = 0x4001_000B
    public static let STATUS_MEDIA_DISCONNECT: UInt32 = 0x4001_000C

    public static let OID_802_3_PERMANENT_ADDRESS: UInt32 = 0x0101_0101
    public static let OID_GEN_CURRENT_PACKET_FILTER: UInt32 = 0x0001_010E
    public static let OID_GEN_MEDIA_CONNECT_STATUS: UInt32 = 0x0001_0114

    public static let FILTER_DIRECTED: UInt32 = 0x0001
    public static let FILTER_MULTICAST: UInt32 = 0x0002
    public static let FILTER_ALL_MULTICAST: UInt32 = 0x0004
    public static let FILTER_BROADCAST: UInt32 = 0x0008
    public static let FILTER_PROMISCUOUS: UInt32 = 0x0020

    /// Android gadgets ignore finer-grained filtering; always ask for everything.
    public static let DEFAULT_FILTER: UInt32 =
        FILTER_DIRECTED | FILTER_BROADCAST | FILTER_ALL_MULTICAST | FILTER_PROMISCUOUS

    public static let VERSION_MAJOR: UInt32 = 1
    public static let VERSION_MINOR: UInt32 = 0

    /// EP0 encapsulated-response buffer size (kext RNDIS_CMD_BUF_SZ).
    public static let CONTROL_BUFFER_SIZE = 1024

    /// Do not raise: 64 KiB collapses SuperSpeed throughput on Samsung
    /// gadgets, and Pixel 2 era devices send up to 16 KiB regardless of the
    /// negotiated limit.
    public static let HOST_MAX_TRANSFER_SIZE: UInt32 = 16384
}

// MARK: - Little-endian helpers

struct LEWriter {
    private(set) var data = Data()

    mutating func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func bytes(_ payload: [UInt8]) {
        data.append(contentsOf: payload)
    }
}

struct LEReader {
    private let buffer: UnsafeRawBufferPointer
    private var offset = 0

    init(_ buffer: UnsafeRawBufferPointer) {
        self.buffer = buffer
    }

    mutating func u32() throws(RNDISParseError) -> UInt32 {
        guard buffer.count - offset >= 4 else { throw .tooShort }
        let value = buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        offset += 4
        return UInt32(littleEndian: value)
    }

    mutating func skip(_ byteCount: Int) throws(RNDISParseError) {
        guard byteCount >= 0, buffer.count - offset >= byteCount else { throw .tooShort }
        offset += byteCount
    }

    mutating func bytes(_ byteCount: Int) throws(RNDISParseError) -> [UInt8] {
        let start = offset
        try skip(byteCount)
        return Array(UnsafeRawBufferPointer(rebasing: buffer[start..<offset]))
    }
}

// MARK: - Host-to-device control messages

public enum RNDISControl {
    public static func initializeMessage(
        requestID: UInt32,
        maxTransferSize: UInt32 = RNDIS.HOST_MAX_TRANSFER_SIZE
    ) -> Data {
        var w = LEWriter()
        w.u32(RNDIS.MSG_INITIALIZE)
        w.u32(24)
        w.u32(requestID)
        w.u32(RNDIS.VERSION_MAJOR)
        w.u32(RNDIS.VERSION_MINOR)
        w.u32(maxTransferSize)
        return w.data
    }

    public static func queryMessage(requestID: UInt32, oid: UInt32, payload: [UInt8] = []) -> Data {
        var w = LEWriter()
        w.u32(RNDIS.MSG_QUERY)
        w.u32(UInt32(28 + payload.count))
        w.u32(requestID)
        w.u32(oid)
        w.u32(UInt32(payload.count))
        w.u32(payload.isEmpty ? 0 : 20)
        w.u32(0)
        w.bytes(payload)
        return w.data
    }

    public static func setMessage(requestID: UInt32, oid: UInt32, payload: [UInt8]) -> Data {
        var w = LEWriter()
        w.u32(RNDIS.MSG_SET)
        w.u32(UInt32(28 + payload.count))
        w.u32(requestID)
        w.u32(oid)
        w.u32(UInt32(payload.count))
        w.u32(20)
        w.u32(0)
        w.bytes(payload)
        return w.data
    }

    public static func setPacketFilterMessage(requestID: UInt32, filter: UInt32) -> Data {
        var payload = [UInt8]()
        withUnsafeBytes(of: filter.littleEndian) { payload.append(contentsOf: $0) }
        return setMessage(requestID: requestID, oid: RNDIS.OID_GEN_CURRENT_PACKET_FILTER, payload: payload)
    }

    public static func haltMessage(requestID: UInt32) -> Data {
        var w = LEWriter()
        w.u32(RNDIS.MSG_HALT)
        w.u32(12)
        w.u32(requestID)
        return w.data
    }

    public static func resetMessage() -> Data {
        var w = LEWriter()
        w.u32(RNDIS.MSG_RESET)
        w.u32(12)
        w.u32(0)
        return w.data
    }

    /// Reply to a device-initiated KEEPALIVE.
    public static func keepaliveCompleteMessage(requestID: UInt32) -> Data {
        var w = LEWriter()
        w.u32(RNDIS.MSG_KEEPALIVE | RNDIS.MSG_COMPLETION_FLAG)
        w.u32(16)
        w.u32(requestID)
        w.u32(RNDIS.STATUS_SUCCESS)
        return w.data
    }
}

// MARK: - Device-to-host control messages

public enum RNDISParseError: Error, Equatable {
    case tooShort
    case lengthMismatch(claimed: UInt32, available: Int)
    case malformedOffsets
}

public enum RNDISControlMessage: Equatable, Sendable {
    case initializeComplete(
        requestID: UInt32,
        status: UInt32,
        maxPacketsPerTransfer: UInt32,
        maxTransferSize: UInt32,
        packetAlignmentFactor: UInt32
    )
    case queryComplete(requestID: UInt32, status: UInt32, info: [UInt8])
    case setComplete(requestID: UInt32, status: UInt32)
    case resetComplete(status: UInt32, addressingReset: UInt32)
    case keepalive(requestID: UInt32)
    case keepaliveComplete(requestID: UInt32, status: UInt32)
    case indicateStatus(status: UInt32)
    case unknown(type: UInt32)

    public static func parse(_ bytes: [UInt8]) throws -> RNDISControlMessage {
        try bytes.withUnsafeBytes { raw in
            try parseMessage(raw)
        }
    }

    private static func parseMessage(_ raw: UnsafeRawBufferPointer) throws(RNDISParseError) -> RNDISControlMessage {
        var header = LEReader(raw)
        let type = try header.u32()
        let claimedLength = try header.u32()
        guard claimedLength >= 12, Int(claimedLength) <= raw.count else {
            throw .lengthMismatch(claimed: claimedLength, available: raw.count)
        }
        // Every later read is bounded by the message's own claimed length,
        // never by whatever trailing bytes the transfer happened to carry.
        var body = LEReader(UnsafeRawBufferPointer(rebasing: raw[8..<Int(claimedLength)]))

        switch type {
        case RNDIS.MSG_INITIALIZE | RNDIS.MSG_COMPLETION_FLAG:
            let requestID = try body.u32()
            let status = try body.u32()
            try body.skip(16)  // major, minor, device flags, medium
            return .initializeComplete(
                requestID: requestID,
                status: status,
                maxPacketsPerTransfer: try body.u32(),
                maxTransferSize: try body.u32(),
                packetAlignmentFactor: try body.u32()
            )

        case RNDIS.MSG_QUERY | RNDIS.MSG_COMPLETION_FLAG:
            let requestID = try body.u32()
            let status = try body.u32()
            let infoLength = try body.u32()
            let infoOffset = try body.u32()
            guard infoLength > 0 else {
                return .queryComplete(requestID: requestID, status: status, info: [])
            }
            // Offset is relative to the RequestID field (message start + 8).
            let start = 8 + Int(infoOffset)
            guard start >= 24, start + Int(infoLength) <= Int(claimedLength) else {
                throw .malformedOffsets
            }
            try body.skip(start - 24)
            return .queryComplete(requestID: requestID, status: status, info: try body.bytes(Int(infoLength)))

        case RNDIS.MSG_SET | RNDIS.MSG_COMPLETION_FLAG:
            return .setComplete(requestID: try body.u32(), status: try body.u32())

        case RNDIS.MSG_RESET | RNDIS.MSG_COMPLETION_FLAG:
            // RESET_C carries no RequestID: fields are status, addressing reset.
            return .resetComplete(status: try body.u32(), addressingReset: try body.u32())

        case RNDIS.MSG_KEEPALIVE:
            return .keepalive(requestID: try body.u32())

        case RNDIS.MSG_KEEPALIVE | RNDIS.MSG_COMPLETION_FLAG:
            return .keepaliveComplete(requestID: try body.u32(), status: try body.u32())

        case RNDIS.MSG_INDICATE_STATUS:
            return .indicateStatus(status: try body.u32())

        default:
            return .unknown(type: type)
        }
    }
}
