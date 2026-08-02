// SPDX-License-Identifier: GPL-2.0-or-later
// feth (if_fake) pair management via ioctls. The peering request struct is
// carried in CFeth because the macOS SDK does not ship if_fake_var.h.

import CFeth
import Darwin
import Foundation

struct FethError: Error, CustomStringConvertible {
    let operation: String
    let code: Int32

    var description: String {
        "\(operation) failed: \(String(cString: strerror(code)))"
    }

    static func current(_ operation: String) -> FethError {
        FethError(operation: operation, code: errno)
    }
}

enum FethIoctl {
    static func makeIfreq(_ name: String) throws -> ifreq {
        var request = ifreq()
        guard name.utf8.count < 16 else {
            throw FethError(operation: "interface name \(name)", code: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &request.ifr_name) { buffer in
            var index = 0
            for byte in name.utf8 {
                buffer[index] = byte
                index += 1
            }
        }
        return request
    }

    static func name(of request: ifreq) -> String {
        var copy = request
        return withUnsafeBytes(of: &copy.ifr_name) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

/// Immutable names plus a control socket; creation and destruction are
/// serialized by the owning backend, so crossing isolation regions is safe.
final class FethPair: @unchecked Sendable {
    /// Stack-facing side: gets the MAC, DHCP, and routes.
    let systemSide: String
    /// IO side: BPF binds here; frames written appear as RX on the system side.
    let ioSide: String
    private let ctl: Int32

    static func fethSupported() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("net.link.fake.max_mtu", &value, &size, nil, 0) == 0
    }

    static func create() throws -> FethPair {
        guard fethSupported() else {
            throw FethError(operation: "net.link.fake.max_mtu sysctl (feth unsupported on this macOS)", code: ENOTSUP)
        }
        let ctl = socket(AF_INET, SOCK_DGRAM, 0)
        guard ctl >= 0 else { throw FethError.current("control socket") }

        func createOne() throws -> String {
            // Wildcard name: the kernel assigns the lowest free unit, avoiding
            // collisions with other feth users such as ZeroTier.
            var request = try FethIoctl.makeIfreq("feth")
            guard cfeth_ioctl(ctl, CFETH_SIOCIFCREATE, &request) == 0 else {
                throw FethError.current("SIOCIFCREATE")
            }
            return FethIoctl.name(of: request)
        }

        let system: String
        let io: String
        do {
            system = try createOne()
        } catch {
            close(ctl)
            throw error
        }
        do {
            io = try createOne()
            var request = cfeth_if_fake_request()
            withUnsafeMutableBytes(of: &request.iffr_u.iffru_peer_name) { buffer in
                var index = 0
                for byte in system.utf8 {
                    buffer[index] = byte
                    index += 1
                }
            }
            var driver = cfeth_ifdrv()
            var ioName = try FethIoctl.makeIfreq(io)
            withUnsafeBytes(of: &ioName.ifr_name) { source in
                withUnsafeMutableBytes(of: &driver.ifd_name) { target in
                    target.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(16)))
                }
            }
            driver.ifd_cmd = UInt(CFETH_IF_FAKE_S_CMD_SET_PEER)
            driver.ifd_len = MemoryLayout<cfeth_if_fake_request>.size
            let peered = withUnsafeMutablePointer(to: &request) { pointer -> Bool in
                driver.ifd_data = UnsafeMutableRawPointer(pointer)
                return cfeth_ioctl(ctl, CFETH_SIOCSDRVSPEC, &driver) == 0
            }
            guard peered else { throw FethError.current("IF_FAKE_S_CMD_SET_PEER") }
        } catch {
            Self.destroyInterface(named: system, using: ctl)
            close(ctl)
            throw error
        }
        return FethPair(systemSide: system, ioSide: io, ctl: ctl)
    }

    private init(systemSide: String, ioSide: String, ctl: Int32) {
        self.systemSide = systemSide
        self.ioSide = ioSide
        self.ctl = ctl
    }

    func configure(macAddress: [UInt8], mtu: Int32) throws {
        var mac = try FethIoctl.makeIfreq(systemSide)
        mac.ifr_ifru.ifru_addr.sa_len = UInt8(macAddress.count)
        mac.ifr_ifru.ifru_addr.sa_family = sa_family_t(AF_LINK)
        withUnsafeMutableBytes(of: &mac.ifr_ifru.ifru_addr.sa_data) { buffer in
            for (index, byte) in macAddress.enumerated() {
                buffer[index] = byte
            }
        }
        guard cfeth_ioctl(ctl, CFETH_SIOCSIFLLADDR, &mac) == 0 else {
            throw FethError.current("SIOCSIFLLADDR(\(systemSide))")
        }
        for name in [systemSide, ioSide] {
            var request = try FethIoctl.makeIfreq(name)
            request.ifr_ifru.ifru_mtu = mtu
            guard cfeth_ioctl(ctl, CFETH_SIOCSIFMTU, &request) == 0 else {
                throw FethError.current("SIOCSIFMTU(\(name))")
            }
            var flags = try FethIoctl.makeIfreq(name)
            guard cfeth_ioctl(ctl, CFETH_SIOCGIFFLAGS, &flags) == 0 else {
                throw FethError.current("SIOCGIFFLAGS(\(name))")
            }
            flags.ifr_ifru.ifru_flags |= Int16(truncatingIfNeeded: IFF_UP)
            guard cfeth_ioctl(ctl, CFETH_SIOCSIFFLAGS, &flags) == 0 else {
                throw FethError.current("SIOCSIFFLAGS(\(name))")
            }
        }
    }

    /// Current IPv4 address of the system side, if a lease has landed.
    func systemSideIPv4() -> String? {
        guard var request = try? FethIoctl.makeIfreq(systemSide) else { return nil }
        guard cfeth_ioctl(ctl, CFETH_SIOCGIFADDR, &request) == 0 else { return nil }
        var address = request.ifr_ifru.ifru_addr
        guard address.sa_family == sa_family_t(AF_INET) else { return nil }
        return withUnsafeBytes(of: &address) { raw -> String? in
            let sin = raw.load(as: sockaddr_in.self)
            var addr = sin.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &text, socklen_t(text.count)) != nil else { return nil }
            return String(cString: text)
        }
    }

    func destroy() {
        Self.destroyInterface(named: ioSide, using: ctl)
        Self.destroyInterface(named: systemSide, using: ctl)
        close(ctl)
    }

    static func destroyInterface(named name: String) {
        let ctl = socket(AF_INET, SOCK_DGRAM, 0)
        guard ctl >= 0 else { return }
        destroyInterface(named: name, using: ctl)
        close(ctl)
    }

    private static func destroyInterface(named name: String, using ctl: Int32) {
        guard var request = try? FethIoctl.makeIfreq(name) else { return }
        if cfeth_ioctl(ctl, CFETH_SIOCIFDESTROY, &request) != 0, errno != ENXIO {
            DaemonLog.error(.net, "SIOCIFDESTROY(\(name)) failed: \(String(cString: strerror(errno)))")
        }
    }
}
