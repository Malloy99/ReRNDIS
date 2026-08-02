// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
@testable import RNDISCore

private func ethernet(type: UInt16, payload: [UInt8]) -> [UInt8] {
    var frame = [UInt8](repeating: 0x11, count: 12)
    frame.append(UInt8(type >> 8))
    frame.append(UInt8(type & 0xFF))
    frame.append(contentsOf: payload)
    return frame
}

private func ipv4(proto: UInt8, tcpDataOffset: Int = 5, payloadBytes: Int) -> [UInt8] {
    let ihl = 20
    let l4Header = proto == 6 ? tcpDataOffset * 4 : 8
    let total = ihl + l4Header + payloadBytes
    var packet = [UInt8](repeating: 0, count: total)
    packet[0] = 0x45
    packet[2] = UInt8(total >> 8)
    packet[3] = UInt8(total & 0xFF)
    packet[9] = proto
    if proto == 6 {
        packet[ihl + 12] = UInt8(tcpDataOffset << 4)
    }
    return packet
}

private func classify(_ frame: [UInt8]) -> Bool {
    frame.withUnsafeBytes { FrameClassifier.isLatencyCritical($0) }
}

@Suite struct FrameClassifierTests {
    @Test func arpAndICMPAreUrgent() {
        #expect(classify(ethernet(type: 0x0806, payload: [UInt8](repeating: 0, count: 28))))
        #expect(classify(ethernet(type: 0x0800, payload: ipv4(proto: 1, payloadBytes: 40))))
    }

    @Test func smallUDPIsUrgentLargeUDPIsBulk() {
        #expect(classify(ethernet(type: 0x0800, payload: ipv4(proto: 17, payloadBytes: 120))))
        #expect(!classify(ethernet(type: 0x0800, payload: ipv4(proto: 17, payloadBytes: 1200))))
    }

    @Test func bareTCPAckIsUrgentDataSegmentIsBulk() {
        #expect(classify(ethernet(type: 0x0800, payload: ipv4(proto: 6, payloadBytes: 0))))
        #expect(classify(ethernet(type: 0x0800, payload: ipv4(proto: 6, tcpDataOffset: 8, payloadBytes: 0))))
        #expect(!classify(ethernet(type: 0x0800, payload: ipv4(proto: 6, payloadBytes: 1000))))
        #expect(!classify(ethernet(type: 0x0800, payload: ipv4(proto: 6, payloadBytes: 1))))
    }

    @Test func ipv6Variants() {
        var v6 = [UInt8](repeating: 0, count: 40 + 20)
        v6[4] = 0
        v6[5] = 20
        v6[6] = 6
        v6[40 + 12] = 5 << 4
        #expect(classify(ethernet(type: 0x86DD, payload: v6)))
        v6[5] = 120
        #expect(!classify(ethernet(type: 0x86DD, payload: v6 + [UInt8](repeating: 0, count: 100))))
        var icmp6 = [UInt8](repeating: 0, count: 48)
        icmp6[6] = 58
        #expect(classify(ethernet(type: 0x86DD, payload: icmp6)))
    }

    @Test func shortAndUnknownFrames() {
        #expect(classify([0x00, 0x01, 0x02]))
        #expect(classify(ethernet(type: 0x9999, payload: [UInt8](repeating: 0, count: 40))))
        #expect(!classify(ethernet(type: 0x9999, payload: [UInt8](repeating: 0, count: 400))))
    }
}

@Suite struct FlowLaneTests {
    private func frame(proto: UInt8, srcPort: UInt16, dstPort: UInt16) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: 54)
        frame[12] = 0x08
        frame[14] = 0x45
        frame[16] = 0x01
        frame[23] = proto
        frame[26...29] = ArraySlice([10, 0, 0, 1])
        frame[30...33] = ArraySlice([10, 0, 0, 2])
        frame[34] = UInt8(srcPort >> 8); frame[35] = UInt8(srcPort & 0xFF)
        frame[36] = UInt8(dstPort >> 8); frame[37] = UInt8(dstPort & 0xFF)
        return frame
    }

    @Test func sameFlowAlwaysHashesToTheSameLane() {
        let sample = frame(proto: 6, srcPort: 5000, dstPort: 443)
        let lanes = Set((0..<10).map { _ in
            sample.withUnsafeBytes { FrameClassifier.flowLane($0, laneCount: 4) }
        })
        #expect(lanes.count == 1)
    }

    @Test func distinctFlowsSpreadAcrossLanes() {
        var seen = Set<Int>()
        for port in 0..<64 {
            let sample = frame(proto: 6, srcPort: UInt16(30_000 + port), dstPort: 443)
            seen.insert(sample.withUnsafeBytes { FrameClassifier.flowLane($0, laneCount: 4) })
        }
        #expect(seen.count == 4)
    }

    @Test func nonIPAndSingleLaneFallBackToLaneZero() {
        var arp = [UInt8](repeating: 0, count: 60)
        arp[12] = 0x08; arp[13] = 0x06
        #expect(arp.withUnsafeBytes { FrameClassifier.flowLane($0, laneCount: 4) } == 0)
        let udp = frame(proto: 17, srcPort: 1234, dstPort: 53)
        #expect(udp.withUnsafeBytes { FrameClassifier.flowLane($0, laneCount: 1) } == 0)
    }
}
