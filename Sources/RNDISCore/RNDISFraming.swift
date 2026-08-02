// SPDX-License-Identifier: GPL-2.0-or-later
// RNDIS data-plane framing. A bulk transfer carries one or more
// REMOTE_NDIS_PACKET_MSG PDUs; devices aggregate on the IN side, so the host
// must de-aggregate defensively (the payload window bound is the same one the
// kext enforced). The hot paths are pointer-based so the daemon can run
// zero-copy over USB buffers; the Data/Array entry points wrap them for the
// control plane and tests.

import Foundation

public enum RNDISFraming {
    public static let PACKET_HEADER_SIZE = 44

    /// Location of one Ethernet frame inside a bulk transfer.
    public struct FrameRange: Equatable, Sendable {
        public let offset: Int
        public let length: Int

        public init(offset: Int, length: Int) {
            self.offset = offset
            self.length = length
        }
    }

    // MARK: - Little-endian pointer helpers (alignment-safe)

    @inline(__always)
    private static func loadLE32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    @inline(__always)
    private static func storeLE32(_ base: UnsafeMutableRawPointer, _ offset: Int, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { source in
            base.advanced(by: offset).copyMemory(from: source.baseAddress!, byteCount: 4)
        }
    }

    // MARK: - Encoding

    /// Writes one REMOTE_NDIS_PACKET_MSG into `out` and returns the byte count.
    /// DataOffset is relative to the field's own position, which is message
    /// start + 8 (Linux rndis_host layout). `out` must fit header + frame.
    @discardableResult
    public static func writePacketMessage(
        frame: UnsafeRawBufferPointer,
        into out: UnsafeMutableRawBufferPointer
    ) -> Int {
        let total = PACKET_HEADER_SIZE + frame.count
        precondition(out.count >= total, "output buffer too small for packet message")
        let base = out.baseAddress!
        storeLE32(base, 0, RNDIS.MSG_PACKET)
        storeLE32(base, 4, UInt32(total))
        storeLE32(base, 8, UInt32(PACKET_HEADER_SIZE - 8))
        storeLE32(base, 12, UInt32(frame.count))
        base.advanced(by: 16).initializeMemory(as: UInt8.self, repeating: 0, count: PACKET_HEADER_SIZE - 16)
        if let frameBase = frame.baseAddress {
            base.advanced(by: PACKET_HEADER_SIZE).copyMemory(from: frameBase, byteCount: frame.count)
        }
        return total
    }

    public static func packetMessage(for frame: [UInt8]) -> Data {
        var data = Data(count: PACKET_HEADER_SIZE + frame.count)
        data.withUnsafeMutableBytes { out in
            frame.withUnsafeBytes { raw in
                _ = writePacketMessage(frame: raw, into: out)
            }
        }
        return data
    }

    /// A bulk-out transfer that is an exact multiple of the pipe's max packet
    /// size needs one extra pad byte so the device sees a short packet ending
    /// the transfer. msg_len stays unchanged; devices delimit by it.
    public static func zlpPaddedLength(_ length: Int, maxPacketSize: Int) -> Int {
        guard maxPacketSize > 0, length > 0, length % maxPacketSize == 0 else { return length }
        return length + 1
    }

    public static func paddedForShortPacket(_ transfer: Data, maxPacketSize: Int) -> Data {
        guard zlpPaddedLength(transfer.count, maxPacketSize: maxPacketSize) != transfer.count else {
            return transfer
        }
        var padded = transfer
        padded.append(0)
        return padded
    }

    /// Packs frames into `out` within the device's INITIALIZE_CMPLT limits and
    /// returns bytes written plus how many frames were consumed. The first
    /// frame always fits by precondition (callers size buffers to the transfer
    /// budget). Each PDU after the first starts on a 2^alignmentFactor
    /// boundary; pad bytes sit between messages and the preceding msg_len
    /// grows to cover them, which is how peers walk the chain.
    public static func aggregateInto(
        _ out: UnsafeMutableRawBufferPointer,
        frames: [[UInt8]],
        maxPackets: Int,
        alignmentFactor: Int
    ) -> (written: Int, consumed: Int) {
        let alignment = 1 << min(max(alignmentFactor, 0), 10)
        let base = out.baseAddress!
        var written = 0
        var consumed = 0
        var previousMessageStart = 0
        for frame in frames {
            guard consumed < max(1, maxPackets) else { break }
            let padding = consumed == 0 ? 0 : (alignment - (written % alignment)) % alignment
            let needed = padding + PACKET_HEADER_SIZE + frame.count
            if consumed > 0, written + needed > out.count { break }
            if padding > 0 {
                base.advanced(by: written).initializeMemory(as: UInt8.self, repeating: 0, count: padding)
                let previousLength = loadLE32(UnsafeRawBufferPointer(out), previousMessageStart + 4)
                storeLE32(base, previousMessageStart + 4, previousLength + UInt32(padding))
            }
            let start = written + padding
            frame.withUnsafeBytes { raw in
                _ = writePacketMessage(frame: raw, into: UnsafeMutableRawBufferPointer(rebasing: out[start...]))
            }
            previousMessageStart = start
            written = start + PACKET_HEADER_SIZE + frame.count
            consumed += 1
        }
        return (written, consumed)
    }

    public static func aggregateTransfer(
        frames: [[UInt8]],
        maxTransferBytes: Int,
        maxPackets: Int,
        alignmentFactor: Int
    ) -> (transfer: Data, consumedFrames: Int) {
        guard let first = frames.first else { return (Data(), 0) }
        let capacity = max(maxTransferBytes, PACKET_HEADER_SIZE + first.count)
        var data = Data(count: capacity)
        let result = data.withUnsafeMutableBytes { out in
            aggregateInto(
                UnsafeMutableRawBufferPointer(rebasing: out[0..<min(maxTransferBytes, capacity)]),
                frames: frames,
                maxPackets: maxPackets,
                alignmentFactor: alignmentFactor
            )
        }
        data.removeSubrange(result.written..<capacity)
        return (data, result.consumed)
    }

    // MARK: - Decoding

    /// Zero-copy split of one bulk-in transfer into frame ranges, appended to a
    /// caller-owned array so hot paths can reuse one allocation. On the first
    /// malformed PDU the rest of the transfer is abandoned and the reason
    /// returned.
    public static func deaggregateRanges(
        _ bytes: UnsafeRawBufferPointer,
        into ranges: inout [FrameRange]
    ) -> String? {
        ranges.removeAll(keepingCapacity: true)
        var base = 0
        while bytes.count - base >= PACKET_HEADER_SIZE {
            let type = loadLE32(bytes, base)
            let messageLength = loadLE32(bytes, base + 4)
            let dataOffset = loadLE32(bytes, base + 8)
            let dataLength = loadLE32(bytes, base + 12)
            guard type == RNDIS.MSG_PACKET else {
                return "unexpected message type 0x\(String(type, radix: 16)) at \(base)"
            }
            guard messageLength >= UInt32(PACKET_HEADER_SIZE), Int(messageLength) <= bytes.count - base else {
                return "message length \(messageLength) escapes transfer at \(base)"
            }
            guard Int(dataOffset) + Int(dataLength) + 8 <= Int(messageLength) else {
                return "data window escapes message at \(base)"
            }
            if dataLength > 0 {
                ranges.append(FrameRange(offset: base + 8 + Int(dataOffset), length: Int(dataLength)))
            }
            base += Int(messageLength)
        }
        return nil
    }

    public static func deaggregateRanges(
        _ bytes: UnsafeRawBufferPointer
    ) -> (ranges: [FrameRange], malformation: String?) {
        var ranges: [FrameRange] = []
        let malformation = deaggregateRanges(bytes, into: &ranges)
        return (ranges, malformation)
    }

    public struct DeaggregationResult: Equatable, Sendable {
        public var frames: [[UInt8]]
        public var malformation: String?

        public init(frames: [[UInt8]], malformation: String? = nil) {
            self.frames = frames
            self.malformation = malformation
        }
    }

    public static func deaggregate(_ bytes: [UInt8]) -> DeaggregationResult {
        bytes.withUnsafeBytes { raw in
            let (ranges, malformation) = deaggregateRanges(raw)
            return DeaggregationResult(
                frames: ranges.map { Array(bytes[$0.offset..<($0.offset + $0.length)]) },
                malformation: malformation
            )
        }
    }
}
