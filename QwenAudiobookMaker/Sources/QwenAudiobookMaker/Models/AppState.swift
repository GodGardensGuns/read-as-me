import Foundation

enum ServerState: String {
    case stopped = "Stopped"
    case starting = "Starting"
    case running = "Running"
    case external = "External"
}

enum ConversionState: Equatable {
    case idle
    case preparing
    case converting
    case complete(URL)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "Idle"
        case .preparing:
            return "Preparing"
        case .converting:
            return "Converting"
        case .complete:
            return "Complete"
        case .failed:
            return "Failed"
        }
    }

    var isBusy: Bool {
        switch self {
        case .preparing, .converting:
            return true
        case .idle, .complete, .failed:
            return false
        }
    }
}

enum TranscriptInputMode: String, CaseIterable, Identifiable {
    case file = "File"
    case text = "Text"

    var id: String { rawValue }
}
