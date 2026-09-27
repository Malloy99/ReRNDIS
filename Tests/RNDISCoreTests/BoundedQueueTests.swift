// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
@testable import RNDISCore

private final class LiveCount {
    var value = 0
}

private final class Tracked {
    private let live: LiveCount

    init(_ live: LiveCount) {
        self.live = live
        live.value += 1
    }

    deinit {
        live.value -= 1
    }
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

@Suite struct BoundedQueueTests {
    @Test func emptyQueueHasNothingToGive() {
        let queue = BoundedQueue<Int>(capacity: 4)
        #expect(queue.isEmpty)
        #expect(queue.first == nil)
        #expect(queue.popFirst() == nil)
    }

    @Test func keepsOrderAcrossWraparound() {
        let queue = BoundedQueue<Int>(capacity: 4)
        var produced = 0
        var consumed: [Int] = []
        for _ in 0..<25 {
            for _ in 0..<3 {
                #expect(queue.append(produced))
                produced += 1
            }
            for _ in 0..<3 {
                consumed.append(queue.removeFirst())
            }
        }
        #expect(consumed == Array(0..<produced))
        #expect(queue.isEmpty)
    }

    @Test(arguments: [1, 3, 5, 64])
    func refusesAppendsBeyondExactCapacity(capacity: Int) {
        let queue = BoundedQueue<Int>(capacity: capacity)
        for value in 0..<capacity {
            #expect(queue.append(value))
        }
        #expect(!queue.append(-1))
        #expect(queue.count == capacity)
        #expect(queue.popFirst() == 0)
        #expect(queue.append(capacity))
        #expect(queue.count == capacity)
    }

    @Test func firstPeeksWithoutRemoving() {
        let queue = BoundedQueue<[UInt8]>(capacity: 2)
        #expect(queue.append([1, 2]))
        #expect(queue.append([3]))
        #expect(queue.first == [1, 2])
        #expect(queue.count == 2)
        #expect(queue.removeFirst() == [1, 2])
        #expect(queue.first == [3])
    }

    @Test func releasesEveryElement() {
        let live = LiveCount()
        do {
            let queue = BoundedQueue<Tracked>(capacity: 3)
            for _ in 0..<3 {
                #expect(queue.append(Tracked(live)))
            }
            #expect(!queue.append(Tracked(live)))
            #expect(live.value == 3)
            _ = queue.popFirst()
            #expect(live.value == 2)
            queue.removeAll()
            #expect(live.value == 0)
            #expect(queue.isEmpty)
            #expect(queue.append(Tracked(live)))
            #expect(queue.append(Tracked(live)))
        }
        #expect(live.value == 0)
    }

    @Test(arguments: [1, 2, 3, 7, 8, 9])
    func matchesArrayModel(capacity: Int) {
        var random = SplitMix64(state: UInt64(capacity))
        let queue = BoundedQueue<Int>(capacity: capacity)
        var model: [Int] = []
        for step in 0..<5_000 {
            switch random.next() % 5 {
            case 0, 1:
                let accepted = queue.append(step)
                #expect(accepted == (model.count < capacity))
                if accepted { model.append(step) }
            case 2:
                let expected = model.isEmpty ? nil : model.removeFirst()
                #expect(queue.popFirst() == expected)
            case 3:
                #expect(queue.first == model.first)
            default:
                if random.next() % 50 == 0 {
                    queue.removeAll()
                    model.removeAll()
                }
            }
            #expect(queue.count == model.count)
        }
    }
}
