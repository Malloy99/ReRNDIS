// SPDX-License-Identifier: GPL-2.0-or-later
import ArgumentParser
import Foundation
import ReRNDISShared
import Synchronization

@main
struct Horndisctl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rerndisctl",
        abstract: "Query and control the ReRNDIS daemon.",
        subcommands: [Status.self, Logs.self, Enable.self, Disable.self, Config.self, Bench.self],
        defaultSubcommand: Status.self
    )
}

private func fail(_ message: String) {
    FileHandle.standardError.write(Data("rerndisctl: \(message)\n".utf8))
}

/// Runs one proxy call and waits for its reply. Reply blocks arrive on XPC
/// queues, hence the Sendable box for the exit code.
private func withDaemon(
    timeout: TimeInterval = 5,
    _ call: (ReRNDISDaemonXPC, @escaping @Sendable (Int32) -> Void) -> Void
) throws {
    let semaphore = DispatchSemaphore(value: 0)
    let exitCode = Mutex<Int32>(0)
    let connection = ReRNDISXPCClient.makeConnection()
    defer { connection.invalidate() }

    let finish: @Sendable (Int32) -> Void = { code in
        exitCode.withLock { $0 = code }
        semaphore.signal()
    }
    // The error block runs on an XPC queue: it must not inherit MainActor
    // isolation or the runtime executor check traps.
    let proxyObject = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
        fail("daemon unreachable: \(error.localizedDescription)")
        finish(2)
    }
    guard let proxy = proxyObject as? ReRNDISDaemonXPC else {
        throw ValidationError("XPC proxy creation failed")
    }

    call(proxy, finish)

    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        fail("request timed out")
        throw ExitCode(2)
    }
    let code = exitCode.withLock { $0 }
    if code != 0 {
        throw ExitCode(code)
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show daemon and device state (default).")

    func run() throws {
        try withDaemon { proxy, finish in
            proxy.fetchStatus { data in
                guard let data, let status = try? JSONDecoder().decode(DaemonStatus.self, from: data) else {
                    FileHandle.standardError.write(Data("rerndisctl: bad status payload\n".utf8))
                    finish(3)
                    return
                }
                print("rerndisd \(status.version) [\(status.enabled ? "enabled" : "disabled")]")
                if status.devices.isEmpty {
                    print("no RNDIS devices attached")
                }
                for device in status.devices {
                    let interface = device.interfaceName.map { " on \($0)" } ?? ""
                    let link = device.linkUp ? "up" : "down"
                    print("\(device.name): \(device.phase)\(interface), MAC \(device.macAddress), "
                        + "link \(link), rx \(device.rxBytes)B tx \(device.txBytes)B")
                }
                finish(0)
            }
        }
    }
}

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the daemon's recent log tail.")

    @Argument(help: "Number of lines to fetch.")
    var count: Int = 200

    func run() throws {
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        try withDaemon { proxy, finish in
            proxy.fetchRecentLogs(limit: count) { data in
                guard let data, let lines = try? JSONDecoder().decode([LogLine].self, from: data) else {
                    FileHandle.standardError.write(Data("rerndisctl: bad log payload\n".utf8))
                    finish(3)
                    return
                }
                for line in lines {
                    print("\(line.timestamp.formatted(format)) [\(line.category)] \(line.level): \(line.message)")
                }
                finish(0)
            }
        }
    }
}

private func setEnabled(_ enabled: Bool) throws {
    try withDaemon { proxy, finish in
        proxy.setEnabled(enabled) { ok, error in
            if ok {
                print("ok")
                finish(0)
            } else {
                FileHandle.standardError.write(Data("rerndisctl: \(error ?? "request denied")\n".utf8))
                finish(4)
            }
        }
    }
}

struct Enable: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resume claiming RNDIS devices.")

    func run() throws {
        try setEnabled(true)
    }
}

extension DaemonConfiguration.TXMode: ExpressibleByArgument {}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or change the daemon configuration."
    )

    @Option(help: "TX mode: ordered, balanced, pipelined, or throughput.")
    var txMode: DaemonConfiguration.TXMode?

    @Option(help: "RX reader thread count (1-8).")
    var rxReaders: Int?

    @Option(help: "Claim devices automatically after boot (true/false).")
    var autoStart: Bool?

    @Option(help: "Serial of the device that owns the default route ('none' to clear).")
    var preferredDevice: String?

    func run() throws {
        let fetched = Mutex<DaemonConfiguration?>(nil)
        try withDaemon { proxy, finish in
            proxy.fetchConfiguration { data in
                let decoded = data.flatMap { try? JSONDecoder().decode(DaemonConfiguration.self, from: $0) }
                fetched.withLock { $0 = decoded }
                finish(decoded == nil ? 3 : 0)
            }
        }
        guard var config = fetched.withLock({ $0 }) else {
            throw ExitCode(3)
        }

        guard txMode != nil || rxReaders != nil || autoStart != nil || preferredDevice != nil else {
            if config.usesAsyncPlane {
                print("txMode \(config.txMode.rawValue) (async ordered plane)")
            } else {
                print("txMode \(config.txMode.rawValue) (\(config.txWriters) writers"
                    + (config.txFlowSteering ? ", flow-steered)" : ")"))
            }
            print("rxReaders \(config.rxReaders)")
            print("autoStart \(config.autoStartsOnBoot)")
            print("preferredDevice \(config.preferredDevice ?? "none")")
            return
        }

        if let txMode { config.txMode = txMode }
        if let rxReaders { config.rxReaders = rxReaders }
        if let autoStart { config.autoStartsOnBoot = autoStart }
        if let preferredDevice { config.preferredDevice = preferredDevice == "none" ? nil : preferredDevice }
        let payload = try JSONEncoder().encode(config.clamped())
        try withDaemon { proxy, finish in
            proxy.applyConfiguration(payload) { ok, error in
                if ok {
                    print("ok (active sessions restart)")
                    finish(0)
                } else {
                    fail(error ?? "request denied")
                    finish(4)
                }
            }
        }
    }
}

struct Bench: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Measure the USB TX limit and gateway response time."
    )

    @Option(help: "Serial or session id of the device to measure.")
    var device: String?

    func run() throws {
        try withDaemon(timeout: 30) { proxy, finish in
            proxy.runBenchmark(deviceID: device) { data in
                guard let data, let result = try? JSONDecoder().decode(BenchmarkResult.self, from: data) else {
                    fail("bad benchmark payload")
                    finish(3)
                    return
                }
                if let reason = result.failureReason {
                    fail(reason)
                    finish(4)
                    return
                }
                if let rate = result.txBytesPerSecond {
                    print(String(format: "USB TX limit: %.1f MB/s", rate / 1e6))
                }
                if let p50 = result.rttMillisP50, let p95 = result.rttMillisP95 {
                    print(String(format: "gateway RTT: p50 %.1f ms, p95 %.1f ms", p50, p95))
                }
                finish(0)
            }
        }
    }
}

struct Disable: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Tear down sessions and ignore devices.")

    func run() throws {
        try setEnabled(false)
    }
}
