import Foundation

struct SourceTextSuggestion: Codable, Identifiable, Hashable {
    let id: String
    let kind: String
    let offset: Int
    let length: Int
    let original: String
    let replacement: String
    let message: String
    var accepted: Bool
}

struct SourceTextReviewPayload: Codable {
    let schemaVersion: Int
    let source: String
    let text: String
    var suggestions: [SourceTextSuggestion]
}
