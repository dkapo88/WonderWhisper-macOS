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
    let vocabularySignature: String?
    
    init(fileSize: UInt64,
         fileMod: TimeInterval,
         provider: String,
         model: String,
         language: String?,
         preprocessing: Bool,
         contentHash: String? = nil,
         vocabularyTerms: [String] = []) {
        self.fileSize = fileSize
        self.fileMod = fileMod
        self.provider = provider
        self.model = model
        self.language = language
        self.preprocessing = preprocessing
        self.contentHash = contentHash
        self.vocabularySignature = Self.signature(for: vocabularyTerms)
    }

    private static func signature(for terms: [String]) -> String? {
        let normalized = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
        guard !normalized.isEmpty else { return nil }
        let data = Data(normalized.joined(separator: "\u{1F}").utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

final class TranscriptionCache {
    static let shared = TranscriptionCache()
    private let cache = LRUCache<TranscriptionCacheKey, String>(capacity: 50, ttl: 900) // Reduced: 50 entries, 15min TTL

    private init() {}

    func key(for fileURL: URL, provider: String, model: String, language: String?, preprocessing: Bool, vocabularyTerms: [String] = []) -> TranscriptionCacheKey? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? NSNumber,
              let mod = attrs[.modificationDate] as? Date else { return nil }
        
        let contentHash = generateContentHash(for: fileURL)
        
        return TranscriptionCacheKey(
            fileSize: size.uint64Value,
            fileMod: mod.timeIntervalSince1970,
            provider: provider,
            model: model,
            language: language,
            preprocessing: preprocessing,
            contentHash: contentHash,
            vocabularyTerms: vocabularyTerms
        )
    }
    
    // Fast content fingerprinting using first and last audio samples
    private func generateContentHash(for fileURL: URL) -> String? {
        // Avoid memory-mapping here; small files are cheap to copy and this
        // prevents rare crashes if the file is still settling.
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return generateContentHash(for: data)
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
        return cache.get(key)
    }

    func store(_ key: TranscriptionCacheKey, result: String) {
        cache.set(key, result)
    }
}
