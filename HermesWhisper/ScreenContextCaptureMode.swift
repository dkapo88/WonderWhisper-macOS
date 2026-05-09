import Foundation

enum ScreenContextCaptureMode: String, Codable, CaseIterable, Identifiable {
    case image
    case text

    static var allCases: [ScreenContextCaptureMode] { [.image, .text] }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "Text"
        case .image: return "Image"
        }
    }
}
