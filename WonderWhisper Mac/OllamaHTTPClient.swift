import Foundation
import OSLog

struct OllamaHTTPClient {
    static let spLog = OSLog(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "Network-SP")
    
    static let session: URLSession = {
        let cfg = NetworkConfiguration.createConfiguration(timeout: 60, maxConnections: 4)
        cfg.timeoutIntervalForResource = 120
        return URLSession(configuration: cfg)
    }()
    
    struct ChatRequest: Encodable {
        struct Message: Encodable {
            struct ContentBlock: Encodable {
                struct ImageURL: Encodable {
                    let url: String
                }
                let type: String
                let text: String?
                let image_url: ImageURL?
            }
            
            enum Content: Encodable {
                case text(String)
                case blocks([ContentBlock])
                
                func encode(to encoder: Encoder) throws {
                    var container = encoder.singleValueContainer()
                    switch self {
                    case .text(let text):
                        try container.encode(text)
                    case .blocks(let blocks):
                        try container.encode(blocks)
                    }
                }
            }
            
            let role: String
            let content: Content
            
            init(role: String, text: String, attachment: LLMImageAttachment?) {
                self.role = role
                if let attachment {
                    var items: [ContentBlock] = []
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        items.append(.init(type: "text", text: text, image_url: nil))
                    }
                    let base64 = attachment.data.base64EncodedString()
                    let url = "data:\(attachment.mimeType);base64,\(base64)"
                    items.append(.init(type: "image_url", text: nil, image_url: .init(url: url)))
                    self.content = .blocks(items)
                } else {
                    self.content = .text(text)
                }
            }
        }
        
        let model: String
        let messages: [Message]
        let temperature: Double?
        let stream: Bool?
        let options: Options?
        
        struct Options: Encodable {
            let temperature: Double?
            let num_predict: Int?
        }
    }
    
    struct ChatResponse: Decodable {
        struct Message: Decodable {
            let role: String
            let content: String
        }
        let model: String?
        let created_at: String?
        let message: Message
        let done: Bool
        let done_reason: String?
        let total_duration: Int?
        let load_duration: Int?
        let prompt_eval_count: Int?
        let prompt_eval_duration: Int?
        let eval_count: Int?
        let eval_duration: Int?
    }
    
    func postChat(to url: URL, body: ChatRequest, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(body)
        request.httpBody = jsonData
        
        AppLog.network.log("Ollama chat request to \(url.absoluteString)")
        
        let (data, response) = try await Self.session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }
        
        guard httpResponse.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw ProviderError.http(status: httpResponse.statusCode, body: bodyStr)
        }
        
        return data
    }
    
    func postChatStream(to url: URL, body: ChatRequest, timeout: TimeInterval) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(body)
        request.httpBody = jsonData
        
        AppLog.network.log("Ollama streaming chat request to \(url.absoluteString)")
        
        let (bytes, response) = try await Self.session.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }
        
        guard httpResponse.statusCode == 200 else {
            throw ProviderError.http(status: httpResponse.statusCode, body: "Streaming request failed")
        }
        
        var aggregated = ""
        let decoder = JSONDecoder()
        
        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }
            
            if let data = line.data(using: .utf8),
               let chunk = try? decoder.decode(ChatResponse.self, from: data) {
                aggregated += chunk.message.content
                if chunk.done {
                    break
                }
            }
        }
        
        return aggregated
    }
    
    // Fetch locally installed Ollama models
    func fetchLocalModels() async throws -> [String] {
        let tagsURL = URL(string: "http://localhost:11434/api/tags")!
        var request = URLRequest(url: tagsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        
        let (data, response) = try await Self.session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }
        
        guard httpResponse.statusCode == 200 else {
            throw ProviderError.http(status: httpResponse.statusCode, body: "Failed to fetch models")
        }
        
        struct TagsResponse: Decodable {
            struct Model: Decodable {
                let name: String
                let modified_at: String?
                let size: Int?
            }
            let models: [Model]
        }
        
        let decoder = JSONDecoder()
        let tagsResponse = try decoder.decode(TagsResponse.self, from: data)
        return tagsResponse.models.map { $0.name }
    }
}
