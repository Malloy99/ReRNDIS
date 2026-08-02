// SPDX-License-Identifier: GPL-2.0-or-later
// Fixed-capacity in-memory log ring. os.log stays the primary sink; this ring
// exists so the daemon can serve a recent-log tail over IPC without touching
// the unified log store.

import Foundation

public enum RingLogLevel: String, Sendable, Equatable, Codable {
    case debug
    case info
    case error
}

public struct RingLogEntry: Sendable, Equatable, Codable {
    public let timestamp: Date
    public let level: RingLogLevel
    public let category: String
    public let message: String

    public init(timestamp: Date, level: RingLogLevel, category: String, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

public struct RingLog: Sendable {
    private var entries: [RingLogEntry?]
    private var nextIndex = 0
    private var count = 0

    public let capacity: Int

    public init(capacity: Int = 2000) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.entries = Array(repeating: nil, count: capacity)
    }

    public mutating func append(_ entry: RingLogEntry) {
        entries[nextIndex] = entry
        nextIndex = (nextIndex + 1) % capacity
        count = min(count + 1, capacity)
    }

    /// Most recent entries in chronological order, capped at `limit`.
    public func tail(_ limit: Int) -> [RingLogEntry] {
        let wanted = min(max(limit, 0), count)
        guard wanted > 0 else { return [] }
        var result: [RingLogEntry] = []
        result.reserveCapacity(wanted)
        var index = (nextIndex - wanted + capacity * 2) % capacity
        for _ in 0..<wanted {
            if let entry = entries[index] {
                result.append(entry)
            }
            index = (index + 1) % capacity
        }
        return result
    }
}
