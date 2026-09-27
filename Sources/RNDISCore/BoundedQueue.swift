// SPDX-License-Identifier: GPL-2.0-or-later

public final class BoundedQueue<Element> {
    @usableFromInline
    struct Positions {
        @usableFromInline var head = 0
        @usableFromInline var tail = 0
    }

    public let capacity: Int
    @usableFromInline let mask: Int
    @usableFromInline let slots: UnsafeMutablePointer<Element>
    @usableFromInline let positions: UnsafeMutablePointer<Positions>

    public init(capacity: Int) {
        precondition(capacity > 0, "BoundedQueue capacity must be positive")
        let slotCount = 1 << (Int.bitWidth - (capacity - 1).leadingZeroBitCount)
        self.capacity = capacity
        mask = slotCount - 1
        slots = .allocate(capacity: slotCount)
        positions = .allocate(capacity: 1)
        positions.initialize(to: Positions())
    }

    deinit {
        removeAll()
        positions.deallocate()
        slots.deallocate()
    }

    @inlinable
    public var count: Int {
        positions.pointee.tail &- positions.pointee.head
    }

    @inlinable
    public var isEmpty: Bool {
        positions.pointee.head == positions.pointee.tail
    }

    @inlinable
    public var first: Element? {
        isEmpty ? nil : slots[positions.pointee.head & mask]
    }

    @inlinable
    public func append(_ element: consuming Element) -> Bool {
        let tail = positions.pointee.tail
        guard tail &- positions.pointee.head < capacity else { return false }
        (slots + (tail & mask)).initialize(to: element)
        positions.pointee.tail = tail &+ 1
        return true
    }

    @inlinable
    public func popFirst() -> Element? {
        let head = positions.pointee.head
        guard head != positions.pointee.tail else { return nil }
        positions.pointee.head = head &+ 1
        return (slots + (head & mask)).move()
    }

    @inlinable
    @discardableResult
    public func removeFirst() -> Element {
        guard let element = popFirst() else {
            preconditionFailure("removeFirst() on an empty BoundedQueue")
        }
        return element
    }

    @inlinable
    public func removeAll() {
        var head = positions.pointee.head
        let tail = positions.pointee.tail
        while head != tail {
            (slots + (head & mask)).deinitialize(count: 1)
            head &+= 1
        }
        positions.pointee.head = head
    }
}
