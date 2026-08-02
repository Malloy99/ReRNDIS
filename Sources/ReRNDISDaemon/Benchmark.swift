// SPDX-License-Identifier: GPL-2.0-or-later
// Self-contained link benchmark: TX capacity from generated frames addressed
// to the limited-broadcast discard port (received over USB, dropped by the
// phone's stack, never NAT-forwarded to cellular), and RTT from DNS queries to
// the phone's own resolver. The RX limit needs a sender on the phone and is
// deliberately out of scope.

import Darwin
import Foundation
import ReRNDISShared
import RNDISCore
import Synchronization

struct BenchmarkContext: Sendable {
    let dataPath: BulkDataPath
    let sourceMAC: [UInt8]
    let interfaceName: String
    let router: String?
}

enum TetherBenchmark {
    private static let running = Atomic<Bool>(false)
    private static let flowCount = 16
    private static let backlogPauseThreshold = 192

    static func run(_ context: BenchmarkContext) -> BenchmarkResult {
        guard running.compareExchange(expected: false, desired: true, ordering: .sequentiallyConsistent).exchanged else {
            return .failure("benchmark already running")
        }
        defer { running.store(false, ordering: .sequentiallyConsistent) }

        let rtt = measureRTT(context)
        let txRate = measureTXCapacity(context)
        return BenchmarkResult(
            txBytesPerSecond: txRate,
            rttMillisP50: rtt?.p50,
            rttMillisP95: rtt?.p95
        )
    }

    // MARK: - TX capacity

    private static func measureTXCapacity(_ context: BenchmarkContext, duration: Duration = .seconds(2)) -> Double? {
        let frames = (0..<flowCount).map {
            discardFrame(sourceMAC: context.sourceMAC, sourcePort: UInt16(40_000 + $0))
        }
        let clock = ContinuousClock()
        let begin = clock.now
        let startBytes = context.dataPath.statistics().txBytes
        let deadline = begin + duration

        var index = 0
        while clock.now < deadline {
            frames[index % frames.count].withUnsafeBytes { context.dataPath.sendFrame($0) }
            index += 1
            if index % 64 == 0 {
                while context.dataPath.txBacklogDepth > backlogPauseThreshold, clock.now < deadline {
                    usleep(200)
                }
            }
        }
        let drainDeadline = clock.now + .milliseconds(400)
        while context.dataPath.txBacklogDepth > 0, clock.now < drainDeadline {
            usleep(1000)
        }

        let bytes = context.dataPath.statistics().txBytes &- startBytes
        let elapsed = seconds(clock.now - begin)
        guard bytes > 0, elapsed > 0.5 else { return nil }
        return Double(bytes) / elapsed
    }

    /// Ethernet + IPv4 + UDP to 255.255.255.255:9, MTU-sized. The source port
    /// varies per flow so steered writer lanes all participate.
    private static func discardFrame(sourceMAC: [UInt8], sourcePort: UInt16) -> [UInt8] {
        let ipLength = 1500
        let udpLength = ipLength - 20

        var header = [UInt8](repeating: 0, count: 20)
        header[0] = 0x45
        header[2] = UInt8(ipLength >> 8)
        header[3] = UInt8(ipLength & 0xFF)
        header[8] = 64
        header[9] = 17
        header[16...19] = [255, 255, 255, 255]
        let checksum = ipChecksum(header)
        header[10] = UInt8(checksum >> 8)
        header[11] = UInt8(checksum & 0xFF)

        var frame = [UInt8](repeating: 0xFF, count: 6)
        frame += sourceMAC
        frame += [0x08, 0x00]
        frame += header
        frame += [
            UInt8(sourcePort >> 8), UInt8(sourcePort & 0xFF),
            0, 9,
            UInt8(udpLength >> 8), UInt8(udpLength & 0xFF),
            0, 0
        ]
        frame += [UInt8](repeating: 0, count: udpLength - 8)
        return frame
    }

    private static func ipChecksum(_ header: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for index in stride(from: 0, to: header.count, by: 2) {
            sum &+= UInt32(header[index]) << 8 | UInt32(header[index + 1])
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(truncatingIfNeeded: sum)
    }

    // MARK: - RTT

    private static func measureRTT(_ context: BenchmarkContext) -> (p50: Double, p95: Double)? {
        guard let router = context.router else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var interfaceIndex = if_nametoindex(context.interfaceName)
        guard interfaceIndex != 0 else { return nil }
        _ = setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &interfaceIndex, socklen_t(MemoryLayout<UInt32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(53).bigEndian
        guard inet_pton(AF_INET, router, &address.sin_addr) == 1 else { return nil }

        let clock = ContinuousClock()
        var samples: [Double] = []
        for query in 1...25 {
            let packet = dnsQuery(id: UInt16(query))
            let sent = clock.now
            let wrote = packet.withUnsafeBytes { raw in
                withUnsafePointer(to: address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                        sendto(fd, raw.baseAddress, raw.count, 0, generic, socklen_t(address.sin_len))
                    }
                }
            }
            guard wrote == packet.count else { continue }
            var reply = [UInt8](repeating: 0, count: 512)
            guard recv(fd, &reply, reply.count, 0) > 0 else { continue }
            samples.append(seconds(clock.now - sent) * 1000)
            usleep(20_000)
        }

        guard samples.count >= 5 else { return nil }
        let sorted = samples.sorted()
        func percentile(_ q: Double) -> Double {
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
        }
        return (percentile(0.5), percentile(0.95))
    }

    private static func dnsQuery(id: UInt16) -> [UInt8] {
        var packet: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in ["example", "com"] {
            packet.append(UInt8(label.utf8.count))
            packet.append(contentsOf: label.utf8)
        }
        packet += [0, 0, 1, 0, 1]
        return packet
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }
}
