// SPDX-License-Identifier: GPL-2.0-or-later
// Logging rides swift-log: one Logger per category, fanned out by a multiplex
// handler to os.log (unified log), stderr (foreground view and launchd's
// StandardErrorPath; debug lines gated by RERNDIS_DEBUG), and the in-memory
// ring served over XPC.

import Foundation
import Logging
import os
import RNDISCore
import Synchronization

enum LogCategory: String, CaseIterable {
    case usb
    case rndis
    case net
    case xpc
    case lifecycle
}

enum DaemonLog {
    static let subsystem = "be.zvz.rerndis"

    private static let loggers: [LogCategory: Logging.Logger] = {
        let stderrDebug = ProcessInfo.processInfo.environment["RERNDIS_DEBUG"] != nil
        LoggingSystem.bootstrap { label in
            let category = label.components(separatedBy: ".").last ?? label
            var stderrHandler = StreamLogHandler.standardError(label: label)
            stderrHandler.logLevel = stderrDebug ? .debug : .info
            var multiplex = MultiplexLogHandler([
                OSLogHandler(subsystem: subsystem, category: category),
                RingLogHandler(category: category),
                stderrHandler
            ])
            multiplex.logLevel = .debug
            return multiplex
        }
        return Dictionary(uniqueKeysWithValues: LogCategory.allCases.map {
            ($0, Logging.Logger(label: subsystem + "." + $0.rawValue))
        })
    }()

    static func info(_ category: LogCategory, _ message: String) {
        loggers[category]?.info("\(message)")
    }

    static func error(_ category: LogCategory, _ message: String) {
        loggers[category]?.error("\(message)")
    }

    static func debug(_ category: LogCategory, _ message: String) {
        loggers[category]?.debug("\(message)")
    }
}

/// swift-log backend writing to the unified log.
struct OSLogHandler: LogHandler {
    private let osLogger: os.Logger
    var logLevel: Logging.Logger.Level = .debug
    var metadata: Logging.Logger.Metadata = [:]

    init(subsystem: String, category: String) {
        self.osLogger = os.Logger(subsystem: subsystem, category: category)
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let text = event.message.description
        switch event.level {
        case .trace, .debug:
            osLogger.debug("\(text, privacy: .public)")
        case .info, .notice:
            osLogger.info("\(text, privacy: .public)")
        case .warning:
            osLogger.warning("\(text, privacy: .public)")
        case .error, .critical:
            osLogger.error("\(text, privacy: .public)")
        }
    }
}

/// swift-log backend feeding the XPC-served ring.
struct RingLogHandler: LogHandler {
    let category: String
    var logLevel: Logging.Logger.Level = .debug
    var metadata: Logging.Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let mapped: RingLogLevel
        switch event.level {
        case .trace, .debug:
            mapped = .debug
        case .info, .notice:
            mapped = .info
        case .warning, .error, .critical:
            mapped = .error
        }
        LogRing.shared.append(RingLogEntry(
            timestamp: Date(),
            level: mapped,
            category: category,
            message: event.message.description
        ))
    }
}

/// Lock-based rather than an actor: appends happen on hot paths and must not
/// spawn a task per line.
final class LogRing: Sendable {
    static let shared = LogRing()
    private let ring = Mutex(RingLog(capacity: 2000))

    func append(_ entry: RingLogEntry) {
        ring.withLock { $0.append(entry) }
    }

    func tail(_ limit: Int) -> [RingLogEntry] {
        ring.withLock { $0.tail(limit) }
    }
}
