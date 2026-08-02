// SPDX-License-Identifier: GPL-2.0-or-later
// HACK: async IOUSBHost completion delivery has wedged on this hardware, so
// RX and the default TX paths use synchronous, blocking calls; overlap comes
// from thread count. The XHCI transfer ring completes transfers in submission
// order, so RX never reorders regardless of reader count.
//
// An async ordered TX submitter exists behind RERNDIS_TX_ASYNC=1, but mixing
// it with the synchronous IN readers on one user client froze or wedged
// transfers on real hardware, the same hazard the EP0 transport documented.
// The pipelined mode (the default) runs the fully async data plane instead:
// with BOTH directions async (a re-arm thread keeps reads enqueued,
// completions only move buffers), no sync call ever touches the data
// interface, so a single flow parallelizes without reordering. The other
// modes keep the synchronous paths.

import DequeModule
import Foundation
@preconcurrency import IOUSBHost
import ReRNDISShared
import RNDISCore
import Synchronization

final class BulkDataPath: @unchecked Sendable {
    struct Statistics {
        let rxBytes: UInt64
        let txBytes: UInt64
        let drops: Int
    }

    private static let urgentFrameLimit = 64
    private static let bulkFrameLimit = 256
    private static let rxStallThreshold: Duration = .seconds(10)
    private static let txStallThreshold: Duration = .seconds(8)
    /// Idle multicast noise must not count as "outbound flowing": kicking the
    /// IN pipe on a quiet link pokes fragile gadgets into not-responding.
    private static let rxKickTXBytes: UInt64 = 512_000

    private struct PumpState {
        var running = false
        var dropCount = 0
        var aggregatedCount = 0
        var txWriteSince: [Int: ContinuousClock.Instant] = [:]
        var asyncEnqueues: [Int: ContinuousClock.Instant] = [:]
        var asyncNeedsStallClear = false
        var rxNeedsStallClear = false
        var lastRXReturn = ContinuousClock.now
        var lastTXActivity = ContinuousClock.now
        var txBytesAtLastRX: UInt64 = 0
        var onFatalError: (@Sendable (String) -> Void)?
    }

    private let dataInterface: IOUSBHostInterface
    private let inPipe: IOUSBHostPipe
    private let outPipe: IOUSBHostPipe
    private let outMaxPacketSize: Int
    private let outTransferBudget: Int
    private let outMaxPacketsPerTransfer: Int
    private let outAlignmentFactor: Int
    private let backend: any NICBackend
    private let rxReaderCount: Int
    private let txWriterCount: Int
    private let txSteersFlows: Bool
    private let txUsesAsyncSubmitter: Bool
    private let usesAsyncPlane: Bool
    private let rxSlots: DispatchSemaphore

    private static let asyncDepth = 3
    private let asyncSlots = DispatchSemaphore(value: BulkDataPath.asyncDepth)
    private let rxEnqueued = Atomic<Int>(0)
    private let rxCompleted = Atomic<Int>(0)
    private let txEnqueued = Atomic<Int>(0)
    private let txCompleted = Atomic<Int>(0)
    private let asyncPoolLock = NSLock()
    private var asyncPool: [NSMutableData] = []

    private let rxCondition = NSCondition()
    private var rxFree: [NSMutableData] = []
    private var rxFilled = Deque<(buffer: NSMutableData, length: Int)>()

    private let txCondition = NSCondition()
    private var txUrgent = Deque<[UInt8]>()
    private var txLanes: [Deque<[UInt8]>]

    private let state = Mutex(PumpState())
    private let rxBytes = Atomic<UInt64>(0)
    private let txBytes = Atomic<UInt64>(0)
    private let threadExited = DispatchSemaphore(value: 0)
    private var threadCount = 0
    private var watchdog: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "be.zvz.rerndis.bulk-watchdog")

    init(
        dataInterface: IOUSBHostInterface,
        interfaceNumber: UInt8,
        configurationDescriptor: [UInt8],
        capabilities: RNDISControlSession.DeviceCapabilities,
        backend: any NICBackend,
        configuration: DaemonConfiguration
    ) throws {
        guard let endpoints = USBDescriptors.bulkPair(
            forInterface: interfaceNumber,
            inConfigurationDescriptor: configurationDescriptor
        ) else {
            throw FethError(operation: "bulk endpoint discovery on interface \(interfaceNumber)", code: ENOENT)
        }
        self.dataInterface = dataInterface
        self.inPipe = try dataInterface.copyPipe(withAddress: Int(endpoints.input.address))
        self.outPipe = try dataInterface.copyPipe(withAddress: Int(endpoints.output.address))
        self.outMaxPacketSize = endpoints.output.maxPacketSize
        self.outTransferBudget = min(max(capabilities.maxTransferSize, 2048), Int(RNDIS.HOST_MAX_TRANSFER_SIZE))
        self.outMaxPacketsPerTransfer = capabilities.maxPacketsPerTransfer
        self.outAlignmentFactor = capabilities.packetAlignmentFactor
        self.backend = backend

        let environment = ProcessInfo.processInfo.environment
        let writers = Int(environment["RERNDIS_TX_WRITERS"] ?? "") ?? configuration.txWriters
        let readers = Int(environment["RERNDIS_RX_READERS"] ?? "") ?? configuration.rxReaders
        self.txWriterCount = min(max(writers, 1), 4)
        self.rxReaderCount = min(max(readers, 1), 8)
        let asyncPlane = environment["RERNDIS_ASYNC_PLANE"].map { $0 == "1" } ?? configuration.usesAsyncPlane
        self.usesAsyncPlane = asyncPlane
        self.rxSlots = DispatchSemaphore(value: min(max(readers, 1), 8))
        let steering = environment["RERNDIS_TX_STEERING"].map { $0 != "0" } ?? configuration.txFlowSteering
        self.txSteersFlows = steering && txWriterCount > 1 && !asyncPlane
        self.txLanes = Array(repeating: Deque(), count: txSteersFlows ? txWriterCount : 1)
        self.txUsesAsyncSubmitter = asyncPlane
            || (configuration.txMode == .throughput
                && environment["RERNDIS_TX_ASYNC"] == "1"
                && environment["RERNDIS_TX_WRITERS"] == nil)
    }

    func start(onFatalError: @escaping @Sendable (String) -> Void) {
        state.withLock {
            $0 = PumpState(running: true, onFatalError: onFatalError)
        }

        rxCondition.lock()
        rxFree = (0..<(rxReaderCount + 2)).compactMap { _ in makeInboundBuffer() }
        rxFilled.removeAll()
        rxCondition.unlock()

        txCondition.lock()
        txUrgent.removeAll()
        for index in txLanes.indices {
            txLanes[index].removeAll()
        }
        txCondition.unlock()

        var threads: [Thread] = []
        if usesAsyncPlane {
            threads.append(pipelineThread(named: "rerndisd.bulk-rx-pump") { [weak self] in self?.rxPumpLoop() })
        } else {
            threads += (0..<rxReaderCount).map { index in
                pipelineThread(named: "rerndisd.bulk-rx\(index)") { [weak self] in self?.rxReaderLoop() }
            }
        }
        threads.append(pipelineThread(named: "rerndisd.bulk-inject") { [weak self] in self?.rxInjectorLoop() })
        if txUsesAsyncSubmitter {
            threads.append(pipelineThread(named: "rerndisd.bulk-tx-async") { [weak self] in self?.txAsyncLoop() })
        } else {
            threads += (0..<txWriterCount).map { index in
                pipelineThread(named: "rerndisd.bulk-tx\(index)") { [weak self] in self?.txLoop(writerIndex: index) }
            }
        }
        threadCount = threads.count
        threads.forEach { $0.start() }

        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.runWatchdog() }
        timer.resume()
        watchdog = timer
        let rxDescription = usesAsyncPlane ? "async RX depth \(rxReaderCount)" : "\(rxReaderCount) RX readers"
        let txDescription = txUsesAsyncSubmitter
            ? "async ordered TX depth \(Self.asyncDepth)"
            : "\(txWriterCount) TX writers" + (txSteersFlows ? ", flow-steered" : "")
        DaemonLog.debug(.rndis, "data plane started (\(rxDescription), \(txDescription))")
    }

    private func pipelineThread(named name: String, _ body: @escaping @Sendable () -> Void) -> Thread {
        let thread = Thread(block: body)
        thread.name = name
        thread.qualityOfService = .userInteractive
        return thread
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        let wasRunning = state.withLock { pump in
            let was = pump.running
            pump.running = false
            return was
        }
        guard wasRunning else { return }
        for condition in [rxCondition, txCondition] {
            condition.lock()
            condition.broadcast()
            condition.unlock()
        }
        try? inPipe.__abort(with: .synchronous)
        try? outPipe.__abort(with: .synchronous)
        if txUsesAsyncSubmitter {
            for _ in 0..<Self.asyncDepth {
                asyncSlots.signal()
            }
        }
        if usesAsyncPlane {
            for _ in 0..<rxReaderCount {
                rxSlots.signal()
            }
        }
        for _ in 0..<threadCount {
            _ = threadExited.wait(timeout: .now() + 2)
        }
        threadCount = 0
    }

    func statistics() -> Statistics {
        Statistics(
            rxBytes: rxBytes.load(ordering: .relaxed),
            txBytes: txBytes.load(ordering: .relaxed),
            drops: state.withLock { $0.dropCount }
        )
    }

    var txBacklogDepth: Int {
        txCondition.lock()
        defer { txCondition.unlock() }
        return txLanes.reduce(txUrgent.count) { $0 + $1.count }
    }

    private var isRunning: Bool {
        state.withLock { $0.running }
    }

}

// MARK: - Buffers

extension BulkDataPath {

    private func makeInboundBuffer() -> NSMutableData? {
        let capacity = Int(RNDIS.HOST_MAX_TRANSFER_SIZE)
        if ProcessInfo.processInfo.environment["RERNDIS_NO_IODATA"] == nil,
           let ioData = try? dataInterface.ioData(withCapacity: capacity),
           ioData.length == capacity {
            return ioData
        }
        return NSMutableData(length: capacity)
    }

    private func makeOutboundScratch() -> NSMutableData? {
        let size = outTransferBudget + 1
        guard let raw = malloc(size) else { return nil }
        return NSMutableData(bytesNoCopy: raw, length: size, freeWhenDone: true)
    }

}

// MARK: - RX pipeline

extension BulkDataPath {

    private func rxReaderLoop() {
        defer { threadExited.signal() }
        while isRunning {
            rxCondition.lock()
            while rxFree.isEmpty && isRunning {
                rxCondition.wait()
            }
            guard isRunning, let buffer = rxFree.popLast() else {
                rxCondition.unlock()
                break
            }
            rxCondition.unlock()

            var transferred: UInt = 0
            var failure: IOReturn?
            do {
                try inPipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: 0)
            } catch {
                failure = usbStatus(of: error)
            }
            let sent = txBytes.load(ordering: .relaxed)
            state.withLock {
                $0.lastRXReturn = .now
                $0.txBytesAtLastRX = sent
            }

            if let failure {
                recycle(buffer)
                switch failure {
                case kUSBHostReturnPipeStalledValue:
                    try? inPipe.clearStall()
                case kIOReturnAbortedValue:
                    break
                default:
                    if isRunning {
                        reportFatal(String(format: "bulk-in ended: IOReturn 0x%08x", failure))
                    }
                    return
                }
                continue
            }

            rxCondition.lock()
            if transferred > 0 {
                rxFilled.append((buffer, Int(transferred)))
            } else {
                rxFree.append(buffer)
            }
            rxCondition.broadcast()
            rxCondition.unlock()
        }
    }

    /// Keeps up to `rxReaderCount` reads enqueued. Completions only move
    /// buffers between queues; enqueueing from the completion handler would
    /// deadlock delivery on the interface queue.
    private func rxPumpLoop() {
        defer { threadExited.signal() }
        while isRunning {
            rxSlots.wait()
            guard isRunning else { return }
            rxCondition.lock()
            while rxFree.isEmpty && isRunning {
                rxCondition.wait()
            }
            guard isRunning, let popped = rxFree.popLast() else {
                rxCondition.unlock()
                return
            }
            rxCondition.unlock()
            nonisolated(unsafe) let buffer = popped

            let clearStall = state.withLock { pump in
                let needed = pump.rxNeedsStallClear
                pump.rxNeedsStallClear = false
                return needed
            }
            if clearStall {
                try? inPipe.clearStall()
            }
            do {
                rxEnqueued.wrappingAdd(1, ordering: .relaxed)
                try inPipe.enqueueIORequest(
                    with: buffer,
                    completionTimeout: 0
                ) { [weak self] (status: IOReturn, transferred: Int) in
                    guard let self else { return }
                    self.rxCompleted.wrappingAdd(1, ordering: .relaxed)
                    let sent = self.txBytes.load(ordering: .relaxed)
                    self.state.withLock {
                        $0.lastRXReturn = .now
                        $0.txBytesAtLastRX = sent
                    }
                    if status == 0, transferred > 0 {
                        self.rxCondition.lock()
                        self.rxFilled.append((buffer, transferred))
                        self.rxCondition.broadcast()
                        self.rxCondition.unlock()
                    } else {
                        if status == kUSBHostReturnPipeStalledValue {
                            self.state.withLock { $0.rxNeedsStallClear = true }
                        } else if status != 0, status != kIOReturnAbortedValue, self.isRunning {
                            self.reportFatal(String(format: "bulk-in ended: IOReturn 0x%08x", status))
                        }
                        self.recycle(buffer)
                    }
                    self.rxSlots.signal()
                }
            } catch {
                recycle(buffer)
                rxSlots.signal()
                rxEnqueued.wrappingSubtract(1, ordering: .relaxed)
                switch usbStatus(of: error) {
                case kUSBHostReturnPipeStalledValue:
                    try? inPipe.clearStall()
                case let status:
                    DaemonLog.debug(.rndis, String(format: "bulk-in enqueue failed: IOReturn 0x%08x", status))
                }
                usleep(2000)
            }
        }
    }

    private func recycle(_ buffer: NSMutableData) {
        rxCondition.lock()
        rxFree.append(buffer)
        rxCondition.broadcast()
        rxCondition.unlock()
    }

    private func rxInjectorLoop() {
        defer { threadExited.signal() }
        var ranges: [RNDISFraming.FrameRange] = []
        ranges.reserveCapacity(max(outMaxPacketsPerTransfer, 16))
        while true {
            rxCondition.lock()
            while rxFilled.isEmpty && isRunning {
                rxCondition.wait()
            }
            guard let item = rxFilled.popFirst() else {
                rxCondition.unlock()
                return
            }
            rxCondition.unlock()

            let raw = UnsafeRawBufferPointer(start: item.buffer.bytes, count: item.length)
            if let malformation = RNDISFraming.deaggregateRanges(raw, into: &ranges) {
                DaemonLog.debug(.rndis, "bulk-in malformation: \(malformation)")
            }
            if !ranges.isEmpty {
                backend.inject(transfer: raw, frames: ranges)
            }
            rxBytes.wrappingAdd(UInt64(item.length), ordering: .relaxed)
            recycle(item.buffer)
        }
    }

}

// MARK: - TX pipeline

extension BulkDataPath {

    func sendFrame(_ frame: UnsafeRawBufferPointer) {
        guard !frame.isEmpty else { return }
        let urgent = FrameClassifier.isLatencyCritical(frame)
        let lane = txSteersFlows && !urgent ? FrameClassifier.flowLane(frame, laneCount: txLanes.count) : 0
        let copy = [UInt8](frame)

        var dropped = false
        txCondition.lock()
        if urgent {
            if txUrgent.count < Self.urgentFrameLimit {
                txUrgent.append(copy)
            } else {
                dropped = true
            }
        } else if txLanes[lane].count < Self.bulkFrameLimit {
            txLanes[lane].append(copy)
        } else {
            dropped = true
        }
        // Steered writers wait for their own lane, so a signal() could wake
        // the wrong one and strand the frame.
        if txSteersFlows {
            txCondition.broadcast()
        } else {
            txCondition.signal()
        }
        txCondition.unlock()

        guard dropped else { return }
        let total = state.withLock { pump -> Int in
            pump.dropCount += 1
            return pump.dropCount
        }
        if total % 512 == 1 {
            DaemonLog.debug(.rndis, "outbound drops \(total) (backlog full)")
        }
    }

    private func nextBatch(lane: Int) -> [[UInt8]]? {
        txCondition.lock()
        defer { txCondition.unlock() }
        while txUrgent.isEmpty && txLanes[lane].isEmpty && isRunning {
            txCondition.wait()
        }
        guard isRunning else { return nil }

        var batch: [[UInt8]] = []
        var projected = 0
        let alignment = 1 << min(max(outAlignmentFactor, 0), 10)
        while batch.count < outMaxPacketsPerTransfer {
            guard let next = txUrgent.first ?? txLanes[lane].first else { break }
            let padding = batch.isEmpty ? 0 : (alignment - projected % alignment) % alignment
            let needed = padding + RNDISFraming.PACKET_HEADER_SIZE + next.count
            if !batch.isEmpty, projected + needed > outTransferBudget { break }
            projected += needed
            batch.append(next)
            if txUrgent.isEmpty {
                txLanes[lane].removeFirst()
            } else {
                txUrgent.removeFirst()
            }
        }
        return batch
    }

    private func buildTransfer(_ batch: [[UInt8]], into scratch: NSMutableData, capacity: Int) {
        scratch.length = capacity
        let out = UnsafeMutableRawBufferPointer(start: scratch.mutableBytes, count: capacity)
        let built = RNDISFraming.aggregateInto(
            UnsafeMutableRawBufferPointer(rebasing: out[0..<outTransferBudget]),
            frames: batch,
            maxPackets: outMaxPacketsPerTransfer,
            alignmentFactor: outAlignmentFactor
        )
        let length = RNDISFraming.zlpPaddedLength(built.written, maxPacketSize: outMaxPacketSize)
        if length != built.written {
            out[built.written] = 0
        }
        scratch.length = length
        if built.consumed > 1 {
            state.withLock { $0.aggregatedCount += 1 }
        }
    }

    private func txLoop(writerIndex: Int) {
        defer { threadExited.signal() }
        guard let scratch = makeOutboundScratch() else {
            reportFatal("outbound scratch allocation failed")
            return
        }
        let lane = txSteersFlows ? writerIndex : 0
        let capacity = outTransferBudget + 1
        while true {
            guard let batch = nextBatch(lane: lane) else { return }
            guard !batch.isEmpty else { continue }
            buildTransfer(batch, into: scratch, capacity: capacity)

            state.withLock {
                $0.txWriteSince[writerIndex] = .now
                $0.lastTXActivity = .now
            }
            var transferred: UInt = 0
            do {
                try outPipe.__sendIORequest(with: scratch, bytesTransferred: &transferred, completionTimeout: 5.0)
                txBytes.wrappingAdd(UInt64(transferred), ordering: .relaxed)
            } catch {
                switch usbStatus(of: error) {
                case kUSBHostReturnPipeStalledValue:
                    try? outPipe.clearStall()
                case kIOReturnAbortedValue:
                    break
                case let status:
                    if isRunning {
                        DaemonLog.debug(.rndis, String(format: "bulk-out error: IOReturn 0x%08x", status))
                    }
                }
            }
            state.withLock { $0.txWriteSince[writerIndex] = nil }
        }
    }

    /// Single submitter: enqueues are ordered by construction, and up to
    /// `asyncDepth` transfers ride the ring concurrently.
    private func txAsyncLoop() {
        defer { threadExited.signal() }
        asyncPoolLock.withLock {
            asyncPool = (0..<Self.asyncDepth).compactMap { _ in makeOutboundScratch() }
        }
        guard asyncPoolLock.withLock({ asyncPool.count }) == Self.asyncDepth else {
            reportFatal("outbound scratch allocation failed")
            return
        }
        let capacity = outTransferBudget + 1
        var nextSlot = 0
        while true {
            asyncSlots.wait()
            guard let batch = nextBatch(lane: 0) else { return }
            guard !batch.isEmpty, let popped = asyncPoolLock.withLock({ asyncPool.popLast() }) else {
                asyncSlots.signal()
                continue
            }
            // The buffer hops thread contexts (submitter, kernel, IO queue)
            // but only ever has one owner at a time.
            nonisolated(unsafe) let scratch = popped
            let clearStall = state.withLock { pump in
                let needed = pump.asyncNeedsStallClear
                pump.asyncNeedsStallClear = false
                return needed
            }
            if clearStall {
                try? outPipe.clearStall()
            }
            buildTransfer(batch, into: scratch, capacity: capacity)

            let slot = nextSlot
            nextSlot += 1
            state.withLock {
                $0.asyncEnqueues[slot] = .now
                $0.lastTXActivity = .now
            }
            do {
                txEnqueued.wrappingAdd(1, ordering: .relaxed)
                try outPipe.enqueueIORequest(
                    with: scratch,
                    completionTimeout: 5.0
                ) { [weak self] (status: IOReturn, transferred: Int) in
                    guard let self else { return }
                    self.txCompleted.wrappingAdd(1, ordering: .relaxed)
                    if status == 0 {
                        self.txBytes.wrappingAdd(UInt64(max(transferred, 0)), ordering: .relaxed)
                    } else if status == kUSBHostReturnPipeStalledValue {
                        self.state.withLock { $0.asyncNeedsStallClear = true }
                    } else if status != kIOReturnAbortedValue, self.isRunning {
                        DaemonLog.debug(.rndis, String(format: "bulk-out async completion: IOReturn 0x%08x", status))
                    }
                    self.state.withLock { $0.asyncEnqueues[slot] = nil }
                    self.asyncPoolLock.withLock { self.asyncPool.append(scratch) }
                    self.asyncSlots.signal()
                }
            } catch {
                abandonEnqueue(slot: slot, buffer: scratch)
                switch usbStatus(of: error) {
                case kUSBHostReturnPipeStalledValue:
                    try? outPipe.clearStall()
                case kIOReturnAbortedValue:
                    break
                case let status:
                    if isRunning {
                        DaemonLog.debug(.rndis, String(format: "bulk-out enqueue failed: IOReturn 0x%08x", status))
                    }
                }
            }
        }
    }

    private func abandonEnqueue(slot: Int, buffer: NSMutableData) {
        state.withLock { $0.asyncEnqueues[slot] = nil }
        asyncPoolLock.withLock { asyncPool.append(buffer) }
        asyncSlots.signal()
    }

}

// MARK: - Watchdog

extension BulkDataPath {

    /// Synchronous calls have no completion channel, so a wedged endpoint
    /// blocks its thread forever; aborting from here makes the blocked call
    /// return as aborted and the loop re-issue.
    private func runWatchdog() {
        let now = ContinuousClock.now
        if usesAsyncPlane {
            DaemonLog.debug(.rndis, "async plane: rx \(rxCompleted.load(ordering: .relaxed))/\(rxEnqueued.load(ordering: .relaxed)), "
                + "tx \(txCompleted.load(ordering: .relaxed))/\(txEnqueued.load(ordering: .relaxed)), backlog \(txBacklogDepth)")
        }
        let sent = txBytes.load(ordering: .relaxed)
        let verdict = state.withLock { pump -> (abortRX: Bool, abortTX: Bool) in
            guard pump.running else { return (false, false) }
            let rxBlocked = now - pump.lastRXReturn > Self.rxStallThreshold
            let txDemandsRX = sent &- pump.txBytesAtLastRX > Self.rxKickTXBytes
            let txStuck = pump.txWriteSince.values.contains { now - $0 > Self.txStallThreshold }
                || pump.asyncEnqueues.values.contains { now - $0 > Self.txStallThreshold }
            return (rxBlocked && txDemandsRX, txStuck)
        }
        if verdict.abortRX {
            DaemonLog.error(.rndis, "bulk-in watchdog: outbound flowing but nothing received; kicking the IN pipe")
            state.withLock { $0.lastRXReturn = .now }
            try? inPipe.__abort(with: .synchronous)
            try? inPipe.clearStall()
        }
        if verdict.abortTX {
            DaemonLog.error(.rndis, "bulk-out watchdog: write blocked past \(Self.txStallThreshold); kicking the OUT pipe")
            try? outPipe.__abort(with: .synchronous)
            try? outPipe.clearStall()
        }
    }

    private func usbStatus(of error: Error) -> IOReturn {
        IOReturn(truncatingIfNeeded: (error as NSError).code)
    }

    private func reportFatal(_ message: String) {
        let handler = state.withLock { pump -> (@Sendable (String) -> Void)? in
            let handler = pump.onFatalError
            pump.onFatalError = nil
            return handler
        }
        handler?(message)
    }
}
