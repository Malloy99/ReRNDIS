// SPDX-License-Identifier: GPL-2.0-or-later
// Payloads are JSON-encoded Codable values: ad-hoc signing rules out
// class-based NSSecureCoding whitelisting across differently-signed binaries.

import Foundation

public let rerndisMachServiceName = "be.zvz.rerndis.xpc"

public struct DaemonStatus: Codable, Sendable {
    public struct Device: Codable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let serial: String?
        public let phase: String
        public let macAddress: String
        public let linkUp: Bool
        public let interfaceName: String?
        public let rxBytes: UInt64
        public let txBytes: UInt64

        public init(
            id: String,
            name: String,
            serial: String? = nil,
            phase: String,
            macAddress: String,
            linkUp: Bool,
            interfaceName: String?,
            rxBytes: UInt64,
            txBytes: UInt64
        ) {
            self.id = id
            self.name = name
            self.serial = serial
            self.phase = phase
            self.macAddress = macAddress
            self.linkUp = linkUp
            self.interfaceName = interfaceName
            self.rxBytes = rxBytes
            self.txBytes = txBytes
        }
    }

    public let version: String
    public let enabled: Bool
    public let devices: [Device]

    public init(version: String, enabled: Bool, devices: [Device]) {
        self.version = version
        self.enabled = enabled
        self.devices = devices
    }
}

public struct LogLine: Codable, Sendable {
    public let timestamp: Date
    public let level: String
    public let category: String
    public let message: String

    public init(timestamp: Date, level: String, category: String, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

public struct DaemonConfiguration: Codable, Sendable, Equatable {
    public enum TXMode: String, Codable, Sendable, CaseIterable {
        case ordered
        case balanced
        case pipelined
        case throughput
    }

    public var txMode: TXMode
    public var rxReaders: Int
    public var autoStartsOnBoot: Bool
    public var preferredDevice: String?

    public static let `default` = DaemonConfiguration(txMode: .pipelined, rxReaders: 3)
    public static let rxReaderRange = 1...8

    public init(
        txMode: TXMode,
        rxReaders: Int,
        autoStartsOnBoot: Bool = true,
        preferredDevice: String? = nil
    ) {
        self.txMode = txMode
        self.rxReaders = rxReaders
        self.autoStartsOnBoot = autoStartsOnBoot
        self.preferredDevice = preferredDevice
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.txMode = try container.decode(TXMode.self, forKey: .txMode)
        self.rxReaders = try container.decode(Int.self, forKey: .rxReaders)
        self.autoStartsOnBoot = try container.decodeIfPresent(Bool.self, forKey: .autoStartsOnBoot) ?? true
        self.preferredDevice = try container.decodeIfPresent(String.self, forKey: .preferredDevice)
    }

    private enum CodingKeys: String, CodingKey {
        case txMode
        case rxReaders
        case autoStartsOnBoot
        case preferredDevice
    }

    public var txWriters: Int {
        switch txMode {
        case .ordered: 1
        case .balanced, .pipelined: 2
        case .throughput: 4
        }
    }

    /// Balanced pins each flow to one writer: parallel across flows, ordered
    /// within each. Throughput lets writers race for a single flow as well.
    /// Pipelined's writer count only matters as its fallback shape.
    public var txFlowSteering: Bool { txMode == .balanced || txMode == .pipelined }

    /// Pipelined runs the fully async data plane: one submitter keeps several
    /// transfers on the ring, so even a single flow parallelizes in order.
    public var usesAsyncPlane: Bool { txMode == .pipelined }

    public func clamped() -> DaemonConfiguration {
        DaemonConfiguration(
            txMode: txMode,
            rxReaders: min(max(rxReaders, Self.rxReaderRange.lowerBound), Self.rxReaderRange.upperBound),
            autoStartsOnBoot: autoStartsOnBoot,
            preferredDevice: preferredDevice
        )
    }

    public func sharesDataPlane(with other: DaemonConfiguration) -> Bool {
        txMode == other.txMode && rxReaders == other.rxReaders
    }
}

public struct BenchmarkResult: Codable, Sendable {
    public let txBytesPerSecond: Double?
    public let rttMillisP50: Double?
    public let rttMillisP95: Double?
    public let failureReason: String?

    public init(
        txBytesPerSecond: Double?,
        rttMillisP50: Double?,
        rttMillisP95: Double?,
        failureReason: String? = nil
    ) {
        self.txBytesPerSecond = txBytesPerSecond
        self.rttMillisP50 = rttMillisP50
        self.rttMillisP95 = rttMillisP95
        self.failureReason = failureReason
    }

    public static func failure(_ reason: String) -> BenchmarkResult {
        BenchmarkResult(txBytesPerSecond: nil, rttMillisP50: nil, rttMillisP95: nil, failureReason: reason)
    }
}

@objc public protocol ReRNDISDaemonXPC {
    func fetchStatus(reply: @escaping @Sendable (Data?) -> Void)
    func fetchRecentLogs(limit: Int, reply: @escaping @Sendable (Data?) -> Void)
    func setEnabled(_ enabled: Bool, reply: @escaping @Sendable (Bool, String?) -> Void)
    func fetchConfiguration(reply: @escaping @Sendable (Data?) -> Void)
    func applyConfiguration(_ data: Data, reply: @escaping @Sendable (Bool, String?) -> Void)
    func runBenchmark(deviceID: String?, reply: @escaping @Sendable (Data?) -> Void)
}

public enum ReRNDISXPCClient {
    public static func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: rerndisMachServiceName, options: [.privileged])
        connection.remoteObjectInterface = NSXPCInterface(with: ReRNDISDaemonXPC.self)
        connection.resume()
        return connection
    }
}
