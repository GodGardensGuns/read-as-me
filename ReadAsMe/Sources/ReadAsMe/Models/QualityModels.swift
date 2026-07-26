import Foundation

enum WorkflowMode: String, CaseIterable, Identifiable, Codable {
    case generate = "Generate Audiobook"
    case auditExisting = "Audit Existing"

    var id: String { rawValue }
}

enum QualityProfile: String, CaseIterable, Identifiable, Codable {
    case natural = "Natural"
    case acx = "ACX Technical"

    var id: String { rawValue }
}

enum AuditState: Equatable {
    case idle
    case preparingAuditRuntime
    case transcribing
    case analyzing
    case repairing
    case verifying
    case complete
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Idle"
        case .preparingAuditRuntime: "Preparing Audit"
        case .transcribing: "Transcribing"
        case .analyzing: "Analyzing"
        case .repairing: "Repairing"
        case .verifying: "Verifying"
        case .complete: "Complete"
        case .failed: "Failed"
        }
    }

    var isBusy: Bool {
        switch self {
        case .preparingAuditRuntime, .transcribing, .analyzing, .repairing, .verifying:
            true
        case .idle, .complete, .failed:
            false
        }
    }
}

enum FindingKind: String, Codable, CaseIterable {
    case longPause = "long_pause"
    case shortPause = "short_pause"
    case loudnessSpike = "loudness_spike"
    case quietRegion = "quiet_region"
    case clipping
    case missingSpeech = "missing_speech"
    case extraSpeech = "extra_speech"
    case substitution
    case repeatedSpeech = "repeated_speech"
    case unintelligible
    case sourceTypo = "source_typo"
    case formatCompliance = "format_compliance"

    var title: String {
        switch self {
        case .longPause: "Long pause"
        case .shortPause: "Short pause"
        case .loudnessSpike: "Volume spike"
        case .quietRegion: "Quiet area"
        case .clipping: "Clipping"
        case .missingSpeech: "Missing speech"
        case .extraSpeech: "Extra speech"
        case .substitution: "Incorrect word"
        case .repeatedSpeech: "Repeated speech"
        case .unintelligible: "Unclear speech"
        case .sourceTypo: "Source text issue"
        case .formatCompliance: "Format issue"
        }
    }
}

enum FindingSeverity: String, Codable, CaseIterable {
    case info
    case warning
    case critical
}

enum RepairSafety: String, Codable, CaseIterable {
    case safe
    case review
    case unrepairable
}

enum RepairStatus: String, Codable {
    case pending
    case selected
    case repaired
    case rolledBack = "rolled_back"
    case skipped
    case failed
}

enum RepairSelection {
    case ids(Set<String>)
    case allSafe
    case all
}

struct AuditTimeRange: Codable, Hashable {
    let start: Double
    let end: Double
}

struct AuditEvidence: Codable, Hashable {
    var summary: String
    var metrics: [String: Double]

    init(summary: String = "", metrics: [String: Double] = [:]) {
        self.summary = summary
        self.metrics = metrics
    }
}

struct AuditFinding: Codable, Identifiable, Hashable {
    let id: String
    let type: FindingKind
    let severity: FindingSeverity
    let confidence: Double
    let timeRange: AuditTimeRange
    let message: String
    let expectedText: String?
    let observedText: String?
    let evidence: AuditEvidence
    let sourceOffset: Int?
    let sourceLength: Int?
    let sourceChunk: Int?
    let repairSafety: RepairSafety
    let repairAction: String?
    var repairStatus: RepairStatus
    let beforeVerification: [String: Double]?
    var afterVerification: [String: Double]?
}

struct AuditSummary: Codable, Hashable {
    let status: String
    let durationSeconds: Double
    let findingCount: Int
    let criticalCount: Int
    let warningCount: Int
    let repairedCount: Int
}

struct AuditReport: Codable, Hashable {
    let schemaVersion: Int
    let reportId: String
    let createdAt: String
    let inputAudio: String
    let expectedText: String?
    let qualityProfile: QualityProfile
    let language: String?
    let incomplete: Bool
    let summary: AuditSummary
    let globalMetrics: [String: Double]
    var findings: [AuditFinding]
    let outputFiles: [String: String]
    let timelineMap: [TimelineMapEntry]?

}

struct TimelineMapEntry: Codable, Hashable {
    let originalStart: Double
    let originalEnd: Double
    let repairedStart: Double
    let repairedEnd: Double
}

struct QualityManifest: Codable {
    let schemaVersion: Int
    let sessionID: String
    let inputAudio: String
    let expectedText: String?
    let generatedChunks: String?
    let voiceReference: String?
    let voiceTranscript: String?
    let qualityProfile: String
    let language: String
    let outputDirectory: String
    let outputSameFormat: Bool
    let ffmpeg: String
    let ffprobe: String
    let qwenPython: String?
    let converter: String?
    let repairFindingIDs: [String]?
    let repairMode: String?
    let reportPath: String?
}

struct QualityProgressEvent: Codable {
    let event: String
    let phase: String?
    let progress: Double?
    let message: String?
    let report: String?
    let output: String?
}

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
