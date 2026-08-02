// SPDX-License-Identifier: GPL-2.0-or-later
// The urgent lane may only overtake frames of OTHER flows or payload-free
// segments of its own flow; both are safe to reorder by design of TCP/QUIC.

public enum FrameClassifier {
    /// Small UDP covers game traffic, DNS, and QUIC control; larger UDP is
    /// bulk QUIC data and stays in order with its stream.
    public static let urgentUDPLimit = 512

    public static func isLatencyCritical(_ frame: UnsafeRawBufferPointer) -> Bool {
        guard frame.count >= 14 else { return true }
        let etherType = UInt16(frame[12]) << 8 | UInt16(frame[13])
        switch etherType {
        case 0x0806:
            return true
        case 0x0800:
            return isCriticalIPv4(frame)
        case 0x86DD:
            return isCriticalIPv6(frame)
        default:
            return frame.count <= 128
        }
    }

    private static func isCriticalIPv4(_ frame: UnsafeRawBufferPointer) -> Bool {
        guard frame.count >= 34 else { return true }
        let headerLength = Int(frame[14] & 0x0F) * 4
        switch frame[23] {
        case 1:
            return true
        case 17:
            return frame.count <= urgentUDPLimit
        case 6:
            let totalLength = Int(frame[16]) << 8 | Int(frame[17])
            let tcpStart = 14 + headerLength
            guard frame.count >= tcpStart + 13 else { return true }
            let dataOffset = Int(frame[tcpStart + 12] >> 4) * 4
            return totalLength - headerLength - dataOffset == 0
        default:
            return false
        }
    }

    /// Stable lane assignment for one flow, so a steered TX path never
    /// reorders frames within a flow. Non-IP and short frames share lane 0.
    public static func flowLane(_ frame: UnsafeRawBufferPointer, laneCount: Int) -> Int {
        guard laneCount > 1, frame.count >= 14 else { return 0 }
        var hash: UInt32 = 2_166_136_261
        func mix(_ range: Range<Int>) {
            for index in range {
                hash = (hash ^ UInt32(frame[index])) &* 16_777_619
            }
        }

        let etherType = UInt16(frame[12]) << 8 | UInt16(frame[13])
        switch etherType {
        case 0x0800:
            guard frame.count >= 34 else { return 0 }
            mix(23..<24)
            mix(26..<34)
            let l4Start = 14 + Int(frame[14] & 0x0F) * 4
            if frame[23] == 6 || frame[23] == 17, frame.count >= l4Start + 4 {
                mix(l4Start..<(l4Start + 4))
            }
        case 0x86DD:
            guard frame.count >= 54 else { return 0 }
            mix(20..<21)
            mix(22..<54)
            if frame[20] == 6 || frame[20] == 17, frame.count >= 58 {
                mix(54..<58)
            }
        default:
            return 0
        }
        return Int(hash % UInt32(laneCount))
    }

    private static func isCriticalIPv6(_ frame: UnsafeRawBufferPointer) -> Bool {
        guard frame.count >= 54 else { return true }
        let payloadLength = Int(frame[18]) << 8 | Int(frame[19])
        switch frame[20] {
        case 58:
            return true
        case 17:
            return frame.count <= urgentUDPLimit
        case 6:
            guard frame.count >= 67 else { return true }
            let dataOffset = Int(frame[54 + 12] >> 4) * 4
            return payloadLength - dataOffset == 0
        default:
            // Extension headers are rare on TCP/UDP paths; treat as bulk.
            return false
        }
    }
}
