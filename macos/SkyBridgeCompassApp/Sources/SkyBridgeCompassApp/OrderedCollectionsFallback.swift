// Minimal fallback for OrderedCollections when the Swift package is unavailable.
#if !canImport(OrderedCollections)
public struct OrderedDictionary<Key: Hashable, Value> {
    private var order: [Key] = []
    private var dict: [Key: Value] = [:]

    public init() {}

    public var count: Int { order.count }

    public subscript(key: Key) -> Value? {
        get { dict[key] }
        set {
            if let v = newValue {
                if dict[key] == nil { order.append(key) }
                dict[key] = v
            } else {
                dict.removeValue(forKey: key)
                order.removeAll { $0 == key }
            }
        }
    }

    public mutating func removeFirst() {
        if let first = order.first {
            order.removeFirst()
            dict.removeValue(forKey: first)
        }
    }

    public mutating func removeAll() {
        order.removeAll()
        dict.removeAll()
    }

    public typealias Element = (key: Key, value: Value)

    public func elements() -> [Element] {
        order.compactMap { k in dict[k].map { (key: k, value: $0) } }
    }

    public func sorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        elements().sorted(by: areInIncreasingOrder)
    }

    public func map<T>(_ transform: (Element) throws -> T) rethrows -> [T] {
        try elements().map(transform)
    }
}

extension OrderedDictionary: Sequence {
    public func makeIterator() -> IndexingIterator<[Element]> { elements().makeIterator() }
}

extension OrderedDictionary: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (Key, Value)...) {
        self.init()
        for (k, v) in elements {
            self[k] = v
        }
    }
}
#endif