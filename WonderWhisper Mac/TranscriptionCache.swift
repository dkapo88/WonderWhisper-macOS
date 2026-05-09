import Foundation
import CryptoKit

struct TranscriptionCacheKey: Hashable {
    let fileSize: UInt64
    let fileMod: TimeInterval
    let provider: String
    let model: String
    let language: String?
    let preprocessing: Bool
    let contentHash: String? // Audio content fingerprint for better deduplication
    
    init(fileSize: UInt64, fileMod: TimeInterval, provider: String, model: String, language: String?, preprocessing: Bool, contentHash: String? = nil) {
        self.fileSize = fileSize
        self.fileMod = fileMod
        self.provider = provider
        self.model = model
        self.language = language
        self.preprocessing = preprocessing
        self.contentHash = contentHash
    }
}

final class TranscriptionCache {
    static let shared = TranscriptionCache()
    private let cache = LRUCache<TranscriptionCacheKey, String>(capacity: 50, ttl: 900) // Reduced: 50 entries, 15min TTL
    private let backgroundQueue = DispatchQueue(label: "com.wonderwhisper.transcriptioncache", qos: .utility)
    private var lastCleanupTime = Date()
    private let cleanupInterval: TimeInterval = 600 // 10 minutes
    
    // Cache statistics
    private var hitCount: Int = 0
    private var missCount: Int = 0
    private var totalSizeEstimate: Int = 0
    private let statsLock = NSLock()

    private init() {
        // Schedule periodic cleanup
        Timer.scheduledTimer(withTimeInterval: cleanupInterval, repeats: true) { [weak self] _ in
            self?.performPeriodicCleanup()
        }
    }

    func key(for fileURL: URL, provider: String, model: String, language: String?, preprocessing: Bool) -> TranscriptionCacheKey? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? NSNumber,
              let mod = attrs[.modificationDate] as? Date else { return nil }
        
        // Generate content hash asynchronously to avoid blocking
        let contentHash = generateContentHashAsync(for: fileURL)
        
        return TranscriptionCacheKey(
            fileSize: size.uint64Value,
            fileMod: mod.timeIntervalSince1970,
            provider: provider,
            model: model,
            language: language,
            preprocessing: preprocessing,
            contentHash: contentHash
        )
    }
    
    // Create cache key from raw audio data
    func key(for audioData: Data, filename: String, provider: String, model: String, language: String?, preprocessing: Bool) -> TranscriptionCacheKey {
        let contentHash = generateContentHash(for: audioData)
        
        return TranscriptionCacheKey(
            fileSize: UInt64(audioData.count),
            fileMod: Date().timeIntervalSince1970, // Current time for in-memory data
            provider: provider,
            model: model,
            language: language,
            preprocessing: preprocessing,
            contentHash: contentHash
        )
    }
    
    // Fast content fingerprinting using first and last audio samples
    private func generateContentHash(for fileURL: URL) -> String? {
        // Avoid memory-mapping here; small files are cheap to copy and this
        // prevents rare crashes if the file is still settling.
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return generateContentHash(for: data)
    }
    
    // Asynchronous content hash generation to avoid blocking
    private func generateContentHashAsync(for fileURL: URL) -> String? {
        // For now, use synchronous but with smaller sample size for better performance
        // In a future optimization, this could be fully async
        return generateContentHash(for: fileURL)
    }
    
    private func generateContentHash(for data: Data) -> String {
        // Reduced sample size for better performance
        let sampleSize = min(128, data.count / 4) // Reduced from 256 to 128
        var hashData = Data()
        
        // Beginning samples
        if data.count > sampleSize {
            hashData.append(data.prefix(sampleSize))
        }
        
        // Middle samples
        if data.count > sampleSize * 2 {
            let midPoint = data.count / 2
            let midStart = max(0, midPoint - sampleSize / 2)
            let midEnd = min(data.count, midPoint + sampleSize / 2)
            hashData.append(data[midStart..<midEnd])
        }
        
        // End samples  
        if data.count > sampleSize {
            hashData.append(data.suffix(sampleSize))
        } else {
            hashData.append(data) // Small files: hash entire content
        }
        
        let digest = SHA256.hash(data: hashData)
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description // 16-char hex
    }

    func lookup(_ key: TranscriptionCacheKey) -> String? {
        if let result = cache.get(key) {
            statsLock.lock()
            hitCount += 1
            statsLock.unlock()
            return result
        } else {
            statsLock.lock()
            missCount += 1
            statsLock.unlock()
            return nil
        }
    }
    
    // Enhanced lookup that can find similar content by hash
    func lookupByContent(contentHash: String, provider: String, model: String) -> String? {
        // This is a simplified implementation - in practice, you'd maintain a separate hash->key mapping
        // For now, we rely on the content hash being part of the key equality
        return nil // Would need additional indexing to implement efficiently
    }

    func store(_ key: TranscriptionCacheKey, result: String) {
        cache.set(key, result)
        // Update size estimate (rough approximation)
        statsLock.lock()
        totalSizeEstimate = cache.count * (result.count + 200) // 200 bytes overhead per entry
        statsLock.unlock()
    }
    
    // Cache performance statistics
    var cacheStatistics: (hitCount: Int, missCount: Int, totalSize: Int) {
        statsLock.lock()
        defer { statsLock.unlock() }
        return (hitCount: hitCount, missCount: missCount, totalSize: totalSizeEstimate)
    }
    
    // Clear expired entries manually (LRU cache handles this automatically)
    func clearExpired() {
        cache.clearExpired()
    }
    
    // Perform periodic cleanup
    private func performPeriodicCleanup() {
        let now = Date()
        guard now.timeIntervalSince(lastCleanupTime) >= cleanupInterval else { return }
        
        lastCleanupTime = now
        backgroundQueue.async { [weak self] in
            self?.clearExpired()
        }
    }
    
    // Reset cache statistics
    func resetStatistics() {
        statsLock.lock()
        hitCount = 0
        missCount = 0
        totalSizeEstimate = 0
        statsLock.unlock()
    }
}
