import Foundation

/// Small thread-safe cache with TTL expiry and least-recently-used eviction.
final class LRUCache<Key: Hashable, Value> {
  private struct Entry {
    var value: Value
    var lastAccessed: Date
  }

  private let capacity: Int
  private let ttl: TimeInterval
  private var entries: [Key: Entry] = [:]
  private let lock = NSLock()

  init(capacity: Int, ttl: TimeInterval) {
    self.capacity = max(1, capacity)
    self.ttl = max(0, ttl)
  }

  func get(_ key: Key) -> Value? {
    lock.lock()
    defer { lock.unlock() }
    guard var entry = entries[key] else { return nil }
    if ttl > 0, Date().timeIntervalSince(entry.lastAccessed) > ttl {
      entries.removeValue(forKey: key)
      return nil
    }
    entry.lastAccessed = Date()
    entries[key] = entry
    return entry.value
  }

  func set(_ key: Key, _ value: Value) {
    lock.lock()
    defer { lock.unlock() }
    let now = Date()
    entries[key] = Entry(value: value, lastAccessed: now)
    if entries.count > capacity,
       let leastRecentKey = entries.min(by: {
         $0.value.lastAccessed < $1.value.lastAccessed
       })?.key {
      entries.removeValue(forKey: leastRecentKey)
    }
  }
}
