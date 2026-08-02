// SPDX-License-Identifier: GPL-2.0-or-later
// BPF bound to the feth IO side: one fd carries both directions. write(2)
// injects toward the stack (batched into one syscall per USB transfer when the
// kernel supports BIOCSBATCHWRITE); a blocking reader thread drains stack TX
// and hands out zero-copy frame views.

import CFeth
import Darwin
import Foundation
import Synchronization

final class BPFLink: @unchecked Sendable {
    private struct LinkState {
        var running = false
        var onFrame: (@Sendable (UnsafeRawBufferPointer) -> Void)?
    }

    private let fd: Int32
    let bufferSize: Int
    /// Whether the kernel accepted batch-write mode (macOS 14+ private ioctl).
    let supportsBatchWrite: Bool
    private let interfaceName: String

    private let state = Mutex(LinkState())
    private let readerExited = DispatchSemaphore(value: 0)

    init(interfaceName: String, requestedBufferSize: UInt32 = 131_072) throws {
        self.interfaceName = interfaceName
        var openedFd: Int32 = -1
        for unit in 0..<256 {
            let candidate = open("/dev/bpf\(unit)", O_RDWR | O_CLOEXEC)
            if candidate >= 0 {
                openedFd = candidate
                break
            }
            if errno == ENOENT { break }
        }
        guard openedFd >= 0 else { throw FethError(operation: "open /dev/bpf*", code: EBUSY) }

        // Order matters: the buffer length must precede BIOCSETIF, and header
        // completion must precede the batch-write enable.
        var bufferLength = requestedBufferSize
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        var dlt: UInt32 = 0
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        var bound = try FethIoctl.makeIfreq(interfaceName)

        func configure(_ operation: String, _ result: Int32) throws {
            guard result == 0 else {
                close(openedFd)
                throw FethError.current(operation)
            }
        }
        try configure("BIOCSBLEN", cfeth_ioctl(openedFd, CFETH_BIOCSBLEN, &bufferLength))
        try configure("BIOCSHDRCMPLT", cfeth_ioctl(openedFd, CFETH_BIOCSHDRCMPLT, &enable))
        try configure("BIOCSETIF(\(interfaceName))", cfeth_ioctl(openedFd, CFETH_BIOCSETIF, &bound))
        try configure("BIOCGDLT", cfeth_ioctl(openedFd, CFETH_BIOCGDLT, &dlt))
        guard dlt == UInt32(DLT_EN10MB) else {
            close(openedFd)
            throw FethError(operation: "unexpected BPF data-link type \(dlt)", code: EINVAL)
        }
        try configure("BIOCIMMEDIATE", cfeth_ioctl(openedFd, CFETH_BIOCIMMEDIATE, &enable))
        try configure("BIOCSSEESENT", cfeth_ioctl(openedFd, CFETH_BIOCSSEESENT, &disable))
        try configure("BIOCSRTIMEOUT", cfeth_ioctl(openedFd, CFETH_BIOCSRTIMEOUT, &timeout))

        if ProcessInfo.processInfo.environment["RERNDIS_NO_BATCH_INJECT"] != nil {
            self.supportsBatchWrite = false
        } else {
            var batchEnable: Int32 = 1
            self.supportsBatchWrite = cfeth_ioctl(openedFd, CFETH_BIOCSBATCHWRITE, &batchEnable) == 0
        }

        self.fd = openedFd
        self.bufferSize = Int(bufferLength)
    }

    /// Turns batch mode back off. While the flag is set the kernel parses every
    /// write as batch records, so raw single-frame writes only work after this.
    func disableBatchWrite() {
        var disableBatch: Int32 = 0
        _ = cfeth_ioctl(fd, CFETH_BIOCSBATCHWRITE, &disableBatch)
    }

    func start(onFrame: @escaping @Sendable (UnsafeRawBufferPointer) -> Void) {
        state.withLock {
            $0.onFrame = onFrame
            $0.running = true
        }
        let thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread.name = "rerndisd.bpf.\(interfaceName)"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Raw write toward the stack: one frame, or one batch-mode payload of
    /// [bpf_hdr + frame + pad] records. Safe from any thread.
    @discardableResult
    func writeRaw(_ bytes: UnsafeRawBufferPointer) -> Bool {
        write(fd, bytes.baseAddress, bytes.count) == bytes.count
    }

    func shutdown() {
        let wasRunning = state.withLock { state in
            let was = state.running
            state.running = false
            return was
        }
        if wasRunning {
            // The 250ms read timeout bounds how long the reader can linger.
            _ = readerExited.wait(timeout: .now() + 2)
        }
        close(fd)
    }

    private func readLoop() {
        defer { readerExited.signal() }
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let snapshot = state.withLock { ($0.running, $0.onFrame) }
            guard snapshot.0 else { break }
            let readCount = read(fd, &buffer, bufferSize)
            guard readCount > 0 else { continue }
            buffer.withUnsafeBytes { raw in
                var offset = 0
                while offset + MemoryLayout<bpf_hdr>.size <= readCount {
                    // bh_hdrlen is authoritative: the kernel writes 18, sizeof is 20.
                    let header = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: bpf_hdr.self)
                    let headerLength = Int(header.pointee.bh_hdrlen)
                    let capturedLength = Int(header.pointee.bh_caplen)
                    guard headerLength > 0, offset + headerLength + capturedLength <= readCount else { break }
                    let start = offset + headerLength
                    snapshot.1?(UnsafeRawBufferPointer(rebasing: raw[start..<(start + capturedLength)]))
                    offset += cfeth_bpf_wordalign(headerLength + capturedLength)
                }
            }
        }
    }
}
