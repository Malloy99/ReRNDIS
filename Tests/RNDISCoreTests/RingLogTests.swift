// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
@testable import RNDISCore

private func entry(_ index: Int) -> RingLogEntry {
    RingLogEntry(
        timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
        level: .info,
        category: "test",
        message: "entry \(index)"
    )
}

@Suite struct RingLogTests {
    @Test func tailReturnsChronologicalOrder() {
        var log = RingLog(capacity: 10)
        for index in 0..<5 { log.append(entry(index)) }
        #expect(log.tail(3).map(\.message) == ["entry 2", "entry 3", "entry 4"])
    }

    @Test func overwritesOldestWhenFull() {
        var log = RingLog(capacity: 4)
        for index in 0..<9 { log.append(entry(index)) }
        #expect(log.tail(10).map(\.message) == ["entry 5", "entry 6", "entry 7", "entry 8"])
    }

    @Test func tailOnEmptyAndZeroLimit() {
        var log = RingLog(capacity: 4)
        #expect(log.tail(5).isEmpty)
        log.append(entry(1))
        #expect(log.tail(0).isEmpty)
    }
}
