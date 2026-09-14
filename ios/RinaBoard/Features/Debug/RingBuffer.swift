import Foundation

/// Fixed-capacity ring buffer with O(1) append. Once `capacity` elements have
/// been appended, the oldest element is silently dropped to make room for the
/// newest — used by the Debug comms log / serial monitor (C10) so a busy
/// firmware log stream doesn't force an O(n) `removeFirst` on every line.
struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    private var count = 0
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    /// Number of elements currently stored (`<= capacity`).
    var elementCount: Int { count }
    var isEmpty: Bool { count == 0 }
    var isFull: Bool { count == capacity }

    /// Appends `element`, evicting the oldest element if already at capacity.
    mutating func append(_ element: Element) {
        let writeIndex = (head + count) % capacity
        storage[writeIndex] = element
        if count == capacity {
            head = (head + 1) % capacity
        } else {
            count += 1
        }
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
    }

    /// Elements in insertion order, oldest first.
    var elements: [Element] {
        guard count > 0 else { return [] }
        var result: [Element] = []
        result.reserveCapacity(count)
        for offset in 0..<count {
            let index = (head + offset) % capacity
            if let value = storage[index] {
                result.append(value)
            }
        }
        return result
    }
}

extension RingBuffer: Sequence {
    func makeIterator() -> IndexingIterator<[Element]> {
        elements.makeIterator()
    }
}
