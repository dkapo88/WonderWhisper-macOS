import Foundation

final class LRUCache<Key: Hashable, Value> {
    private struct Entry {
        let key: Key
        var value: Value
        var timestamp: Date
    }

    private let capacity: Int
    private let ttl: TimeInterval
    private var dict: [Key: LinkedList<Entry>.Node] = [:]
    private var list = LinkedList<Entry>()
    private let lock = NSLock()

    init(capacity: Int, ttl: TimeInterval) {
        self.capacity = max(1, capacity)
        self.ttl = max(0, ttl)
    }
    
    // Get the current number of entries in the cache
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return dict.count
    }

    func get(_ key: Key) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let node = dict[key] else { return nil }
        // TTL check
        if ttl > 0, Date().timeIntervalSince(node.value.timestamp) > ttl {
            list.remove(node)
            dict[key] = nil
            return nil
        }
        list.moveToFront(node)
        return node.value.value
    }

    func set(_ key: Key, _ value: Value) {
        lock.lock(); defer { lock.unlock() }
        if let node = dict[key] {
            node.value.value = value
            node.value.timestamp = Date()
            list.moveToFront(node)
            return
        }
        let entry = Entry(key: key, value: value, timestamp: Date())
        let node = list.pushFront(entry)
        dict[key] = node
        if dict.count > capacity, let tail = list.popBack() {
            dict[tail.key] = nil
        }
    }
    
    // Remove expired entries from the cache
    func clearExpired() {
        lock.lock(); defer { lock.unlock() }
        guard ttl > 0 else { return }
        
        var nodesToRemove: [LinkedList<Entry>.Node] = []
        var currentNode = list.head
        
        while let node = currentNode {
            if Date().timeIntervalSince(node.value.timestamp) > ttl {
                nodesToRemove.append(node)
            }
            currentNode = node.next
        }
        
        for node in nodesToRemove {
            dict[node.value.key] = nil
            list.remove(node)
        }
    }
}

// Minimal doubly linked list
final class LinkedList<T> {
    final class Node {
        var value: T
        var prev: Node?
        var next: Node?
        init(_ value: T) { self.value = value }
    }
    private(set) var head: Node?
    private(set) var tail: Node?

    @discardableResult
    func pushFront(_ value: T) -> Node {
        let node = Node(value)
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
        return node
    }

    func moveToFront(_ node: Node) {
        guard head !== node else { return }
        // detach
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if tail === node { tail = node.prev }
        // attach front
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
    }

    @discardableResult
    func popBack() -> T? {
        guard let t = tail else { return nil }
        let val = t.value
        tail = t.prev
        tail?.next = nil
        if tail == nil { head = nil }
        return val
    }

    func remove(_ node: Node) {
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
        node.prev?.next = node.next
        node.next?.prev = node.prev
        node.prev = nil
        node.next = nil
    }
}


