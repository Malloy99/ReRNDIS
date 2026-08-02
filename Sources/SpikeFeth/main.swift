// SPDX-License-Identifier: GPL-2.0-or-later
// M0b spike: prove the virtual-NIC path without any USB involvement.
// Creates a feth pair, binds BPF to the IO side, asks IPConfiguration for DHCP on
// the system side, and verifies the stack's DHCP DISCOVER shows up on BPF.
// Requires root. Pass criteria and sequencing follow the project plan.

import CFeth
import Darwin
import Foundation

let spikeMAC: [UInt8] = [0x02, 0x52, 0x4E, 0x44, 0x49, 0x53]

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("spike-feth: " + message + "\n").utf8))
    exit(1)
}

func errnoText() -> String {
    String(cString: strerror(errno))
}

func makeIfreq(_ name: String) -> ifreq {
    var ifr = ifreq()
    guard name.utf8.count < 16 else { die("interface name too long: \(name)") }
    withUnsafeMutableBytes(of: &ifr.ifr_name) { buffer in
        var index = 0
        for byte in name.utf8 {
            buffer[index] = byte
            index += 1
        }
    }
    return ifr
}

func ifreqName(_ ifr: ifreq) -> String {
    var copy = ifr
    return withUnsafeBytes(of: &copy.ifr_name) { buffer in
        String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

func createFeth(_ ctl: Int32) -> String {
    // Wildcard name: the kernel assigns the lowest free unit and writes it back,
    // which also avoids colliding with other feth users like ZeroTier.
    var ifr = makeIfreq("feth")
    guard cfeth_ioctl(ctl, CFETH_SIOCIFCREATE, &ifr) == 0 else {
        die("SIOCIFCREATE failed: \(errnoText()) (root required)")
    }
    let assigned = ifreqName(ifr)
    guard assigned.count > "feth".count else {
        die("kernel did not assign a feth unit (got \(assigned))")
    }
    return assigned
}

func destroyFeth(_ ctl: Int32, _ name: String) {
    var ifr = makeIfreq(name)
    if cfeth_ioctl(ctl, CFETH_SIOCIFDESTROY, &ifr) != 0 {
        FileHandle.standardError.write(Data("spike-feth: SIOCIFDESTROY(\(name)) failed: \(errnoText())\n".utf8))
    }
}

func peerFeth(_ ctl: Int32, ioSide: String, systemSide: String) {
    var request = cfeth_if_fake_request()
    withUnsafeMutableBytes(of: &request.iffr_u.iffru_peer_name) { buffer in
        var index = 0
        for byte in systemSide.utf8 {
            buffer[index] = byte
            index += 1
        }
    }
    var drv = cfeth_ifdrv()
    withUnsafeMutableBytes(of: &drv.ifd_name) { buffer in
        var index = 0
        for byte in ioSide.utf8 {
            buffer[index] = byte
            index += 1
        }
    }
    drv.ifd_cmd = UInt(CFETH_IF_FAKE_S_CMD_SET_PEER)
    drv.ifd_len = MemoryLayout<cfeth_if_fake_request>.size
    let result = withUnsafeMutablePointer(to: &request) { pointer -> Int32 in
        drv.ifd_data = UnsafeMutableRawPointer(pointer)
        return cfeth_ioctl(ctl, CFETH_SIOCSDRVSPEC, &drv)
    }
    guard result == 0 else { die("IF_FAKE_S_CMD_SET_PEER failed: \(errnoText())") }
}

func setLinkAddress(_ ctl: Int32, _ name: String, _ mac: [UInt8]) {
    var ifr = makeIfreq(name)
    ifr.ifr_ifru.ifru_addr.sa_len = UInt8(mac.count)
    ifr.ifr_ifru.ifru_addr.sa_family = sa_family_t(AF_LINK)
    withUnsafeMutableBytes(of: &ifr.ifr_ifru.ifru_addr.sa_data) { buffer in
        for (index, byte) in mac.enumerated() {
            buffer[index] = byte
        }
    }
    guard cfeth_ioctl(ctl, CFETH_SIOCSIFLLADDR, &ifr) == 0 else {
        die("SIOCSIFLLADDR(\(name)) failed: \(errnoText())")
    }
}

func setMTU(_ ctl: Int32, _ name: String, _ mtu: Int32) {
    var ifr = makeIfreq(name)
    ifr.ifr_ifru.ifru_mtu = mtu
    guard cfeth_ioctl(ctl, CFETH_SIOCSIFMTU, &ifr) == 0 else {
        die("SIOCSIFMTU(\(name)) failed: \(errnoText())")
    }
}

func bringUp(_ ctl: Int32, _ name: String) {
    var ifr = makeIfreq(name)
    guard cfeth_ioctl(ctl, CFETH_SIOCGIFFLAGS, &ifr) == 0 else {
        die("SIOCGIFFLAGS(\(name)) failed: \(errnoText())")
    }
    ifr.ifr_ifru.ifru_flags |= Int16(truncatingIfNeeded: IFF_UP)
    guard cfeth_ioctl(ctl, CFETH_SIOCSIFFLAGS, &ifr) == 0 else {
        die("SIOCSIFFLAGS(\(name)) failed: \(errnoText())")
    }
}

func openBPF(boundTo name: String, requestedBufferSize: UInt32) -> (fd: Int32, bufferSize: Int) {
    for unit in 0..<256 {
        let fd = open("/dev/bpf\(unit)", O_RDWR)
        if fd < 0 {
            if errno == EBUSY { continue }
            if errno == ENOENT { break }
            continue
        }
        // Order matters: buffer length must be set before BIOCSETIF.
        var bufferLength = requestedBufferSize
        guard cfeth_ioctl(fd, CFETH_BIOCSBLEN, &bufferLength) == 0 else { die("BIOCSBLEN failed: \(errnoText())") }
        var enable: UInt32 = 1
        guard cfeth_ioctl(fd, CFETH_BIOCSHDRCMPLT, &enable) == 0 else { die("BIOCSHDRCMPLT failed: \(errnoText())") }
        var ifr = makeIfreq(name)
        guard cfeth_ioctl(fd, CFETH_BIOCSETIF, &ifr) == 0 else { die("BIOCSETIF(\(name)) failed: \(errnoText())") }
        var dlt: UInt32 = 0
        guard cfeth_ioctl(fd, CFETH_BIOCGDLT, &dlt) == 0, dlt == UInt32(DLT_EN10MB) else {
            die("unexpected data-link type \(dlt), wanted DLT_EN10MB")
        }
        enable = 1
        guard cfeth_ioctl(fd, CFETH_BIOCIMMEDIATE, &enable) == 0 else { die("BIOCIMMEDIATE failed: \(errnoText())") }
        var disable: UInt32 = 0
        guard cfeth_ioctl(fd, CFETH_BIOCSSEESENT, &disable) == 0 else { die("BIOCSSEESENT failed: \(errnoText())") }
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        guard cfeth_ioctl(fd, CFETH_BIOCSRTIMEOUT, &timeout) == 0 else { die("BIOCSRTIMEOUT failed: \(errnoText())") }
        return (fd, Int(bufferLength))
    }
    die("no available /dev/bpf device")
}

func runIpconfig(_ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
    process.arguments = arguments
    do {
        try process.run()
    } catch {
        die("failed to run ipconfig \(arguments.joined(separator: " ")): \(error)")
    }
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        FileHandle.standardError.write(
            Data("spike-feth: ipconfig \(arguments.joined(separator: " ")) exited \(process.terminationStatus)\n".utf8)
        )
    }
}

func macText(_ bytes: ArraySlice<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
}

func isDHCPClientFrame(_ frame: [UInt8]) -> Bool {
    guard frame.count >= 42 else { return false }
    guard frame[12] == 0x08, frame[13] == 0x00 else { return false }
    let headerLength = Int(frame[14] & 0x0F) * 4
    guard frame.count >= 14 + headerLength + 8 else { return false }
    guard frame[23] == 17 else { return false }
    let sourcePort = Int(frame[14 + headerLength]) << 8 | Int(frame[14 + headerLength + 1])
    let destinationPort = Int(frame[14 + headerLength + 2]) << 8 | Int(frame[14 + headerLength + 3])
    return sourcePort == 68 && destinationPort == 67
}

func scanForDHCP(fd: Int32, bufferSize: Int, seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    var frameCount = 0
    while Date() < deadline {
        let readCount = read(fd, &buffer, bufferSize)
        guard readCount > 0 else { continue }
        var offset = 0
        while offset + MemoryLayout<bpf_hdr>.size <= readCount {
            // bh_hdrlen is authoritative: the kernel writes 18 while the padded struct is 20.
            let (headerLength, capturedLength) = buffer.withUnsafeBytes { raw -> (Int, Int) in
                let header = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: bpf_hdr.self)
                return (Int(header.pointee.bh_hdrlen), Int(header.pointee.bh_caplen))
            }
            guard headerLength > 0, offset + headerLength + capturedLength <= readCount else { break }
            let frame = Array(buffer[(offset + headerLength)..<(offset + headerLength + capturedLength)])
            frameCount += 1
            if isDHCPClientFrame(frame) {
                print("observed DHCP client frame #\(frameCount): src \(macText(frame[6..<12])) -> dst \(macText(frame[0..<6])), \(frame.count) bytes")
                return true
            }
            offset += cfeth_bpf_wordalign(headerLength + capturedLength)
        }
    }
    print("no DHCP client frame observed (saw \(frameCount) other frames)")
    return false
}

func injectionSmokeTest(fd: Int32) {
    // Gratuitous ARP from a made-up gateway. Acceptance by write(2) proves the
    // injection direction; full end-to-end injection is exercised in M3.
    let sender: [UInt8] = [0x02, 0x00, 0x5E, 0x00, 0x00, 0x01]
    var frame = [UInt8]()
    frame += [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    frame += sender
    frame += [0x08, 0x06]
    frame += [0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x02]
    frame += sender
    frame += [192, 168, 42, 129]
    frame += sender
    frame += [192, 168, 42, 129]
    frame += [UInt8](repeating: 0, count: 18)
    let written = frame.withUnsafeBytes { raw in
        write(fd, raw.baseAddress, raw.count)
    }
    if written == frame.count {
        print("injection smoke test: write() accepted \(written) bytes")
    } else {
        print("injection smoke test FAILED: write() returned \(written) (\(errnoText()))")
    }
}

// MARK: - Main flow

guard geteuid() == 0 else { die("run with sudo") }

var maxMTU: Int32 = 0
var maxMTUSize = MemoryLayout<Int32>.size
guard sysctlbyname("net.link.fake.max_mtu", &maxMTU, &maxMTUSize, nil, 0) == 0 else {
    die("net.link.fake.max_mtu sysctl missing: feth is unavailable on this macOS")
}
print("net.link.fake.max_mtu = \(maxMTU)")

let ctl = socket(AF_INET, SOCK_DGRAM, 0)
guard ctl >= 0 else { die("control socket failed: \(errnoText())") }

let systemSide = createFeth(ctl)
let ioSide = createFeth(ctl)
print("created \(systemSide) (system side) and \(ioSide) (io side)")

var cleanedUp = false
@MainActor
func cleanup() {
    guard !cleanedUp else { return }
    cleanedUp = true
    runIpconfig(["set", systemSide, "NONE"])
    destroyFeth(ctl, ioSide)
    destroyFeth(ctl, systemSide)
    close(ctl)
}

peerFeth(ctl, ioSide: ioSide, systemSide: systemSide)
print("peered \(ioSide) <-> \(systemSide)")

setLinkAddress(ctl, systemSide, spikeMAC)
setMTU(ctl, systemSide, 1500)
setMTU(ctl, ioSide, 1500)
bringUp(ctl, systemSide)
bringUp(ctl, ioSide)
print("configured MAC \(macText(spikeMAC[...])) mtu 1500, both up")

let (bpfFd, bpfBufferSize) = openBPF(boundTo: ioSide, requestedBufferSize: 131_072)
print("BPF bound to \(ioSide), buffer \(bpfBufferSize) bytes")

runIpconfig(["set", systemSide, "DHCP"])
print("requested DHCP on \(systemSide), watching \(ioSide) for DISCOVER ...")

let sawDiscover = scanForDHCP(fd: bpfFd, bufferSize: bpfBufferSize, seconds: 8)
if sawDiscover {
    injectionSmokeTest(fd: bpfFd)
}

close(bpfFd)
cleanup()

if sawDiscover {
    print("PASS: stack TX reaches BPF and the system DHCP client engaged on \(systemSide)")
    exit(0)
} else {
    print("FAIL: DHCP DISCOVER never appeared on \(ioSide)")
    exit(1)
}
