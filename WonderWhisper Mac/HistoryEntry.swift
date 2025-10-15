import Foundation

struct HistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var date: Date
    var appName: String?
    var bundleID: String?
    var transcript: String
    var output: String
    // Only store filenames in JSON; resolve to URLs via HistoryStore
    var audioFilename: String?
    // Additional context
    var screenContext: String?
    // How screen context was captured: "AX", "Image-Window", "Image-Display"
    var screenContextMethod: String?
    var screenImageFilename: String?
    var screenImageMimeType: String?
    var screenImageWidth: Int?
    var screenImageHeight: Int?
    var selectedText: String?
    // LLM prompts captured at time of processing (for transparency)
    var llmSystemMessage: String?
    var llmUserMessage: String?
    // Models
    var transcriptionModel: String?
    var llmModel: String?
    // Performance (seconds)
    var transcriptionSeconds: Double?
    var llmSeconds: Double?
    var totalSeconds: Double?
}
