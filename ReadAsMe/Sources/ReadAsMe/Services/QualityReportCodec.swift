import Foundation

enum QualityReportCodec {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func decodeReport(at url: URL) throws -> AuditReport {
        try decoder.decode(AuditReport.self, from: Data(contentsOf: url))
    }

    static func writeManifest(_ manifest: QualityManifest, to url: URL) throws {
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    static func decodeProgressLine(_ line: String) -> QualityProgressEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? decoder.decode(QualityProgressEvent.self, from: data)
    }
}
