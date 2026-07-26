import AppKit
import Foundation

@MainActor
extension AudiobookController {
    func finishSourceTextReview(applySelected: Bool) {
        guard let continuation = sourceReviewContinuation else { return }
        sourceReviewContinuation = nil
        isShowingSourceReview = false
        continuation.resume(returning: applySelected ? sourceTextSuggestions : [])
    }

    func setSourceSuggestion(_ id: String, accepted: Bool) {
        guard let index = sourceTextSuggestions.firstIndex(where: { $0.id == id }) else { return }
        sourceTextSuggestions[index].accepted = accepted
    }

    func acceptAllSourceSuggestions() {
        for index in sourceTextSuggestions.indices {
            sourceTextSuggestions[index].accepted = true
        }
    }

    func clearAllSourceSuggestions() {
        for index in sourceTextSuggestions.indices {
            sourceTextSuggestions[index].accepted = false
        }
    }

    func reviewSourceText(_ source: URL, in runDirectory: URL) async throws -> SourceTextReviewPayload {
        let output = runDirectory.appendingPathComponent("source-review.json")
        setProgress(fraction: 0.09, title: "Reviewing Source Text", detail: "Checking repeated words and punctuation.")
        let status = try await withCheckedThrowingContinuation { continuation in
            do {
                sourceReviewProcess = try ProcessRunner.start(
                    executable: AppPaths.python,
                    arguments: [
                        AppPaths.qualityEngine.path,
                        "review-source",
                        "--source",
                        source.path,
                        "--output",
                        output.path,
                    ],
                    workingDirectory: runDirectory,
                    environment: AppPaths.converterEnvironment,
                    onOutput: { [weak self] text in self?.appendSourceReviewLog(text) },
                    onTermination: { [weak self] status in
                        self?.sourceReviewProcess = nil
                        continuation.resume(returning: status)
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            throw AppError.message("Source-text review exited with status \(status).")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var payload = try decoder.decode(SourceTextReviewPayload.self, from: Data(contentsOf: output))
        payload.suggestions.append(contentsOf: spellingSuggestions(in: payload.text, excluding: payload.suggestions))
        payload.suggestions.sort { $0.offset < $1.offset }
        return payload
    }

    func waitForSourceTextReview(_ suggestions: [SourceTextSuggestion]) async -> [SourceTextSuggestion] {
        sourceTextSuggestions = suggestions
        isShowingSourceReview = true
        return await withCheckedContinuation { continuation in
            sourceReviewContinuation = continuation
        }
    }

    func applySourceSuggestions(_ suggestions: [SourceTextSuggestion], to text: String) throws -> String {
        let result = NSMutableString(string: text)
        for suggestion in suggestions.sorted(by: { $0.offset > $1.offset }) {
            let range = NSRange(location: suggestion.offset, length: suggestion.length)
            guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= result.length else {
                throw AppError.message("A source-text correction no longer matches the staged book.")
            }
            result.replaceCharacters(in: range, with: suggestion.replacement)
        }
        return result as String
    }

    private func spellingSuggestions(
        in text: String,
        excluding existing: [SourceTextSuggestion]
    ) -> [SourceTextSuggestion] {
        let checker = NSSpellChecker.shared
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var cursor = 0
        var results: [SourceTextSuggestion] = []
        let occupied = existing.map { NSRange(location: $0.offset, length: $0.length) }
        while cursor < fullRange.length, results.count < 100 {
            let range = checker.checkSpelling(
                of: text,
                startingAt: cursor,
                language: nil,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            )
            if range.location == NSNotFound || range.length == 0 { break }
            cursor = range.location + range.length
            if occupied.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }
            let word = nsText.substring(with: range)
            guard word.count > 2,
                  word.first?.isUppercase != true,
                  let replacement = checker.guesses(forWordRange: range, in: text, language: nil, inSpellDocumentWithTag: 0)?.first,
                  replacement.caseInsensitiveCompare(word) != .orderedSame
            else { continue }
            results.append(
                SourceTextSuggestion(
                    id: "spelling-\(range.location)-\(word.lowercased())",
                    kind: "spelling",
                    offset: range.location,
                    length: range.length,
                    original: word,
                    replacement: replacement,
                    message: "Possible spelling mistake.",
                    accepted: false
                )
            )
        }
        return results
    }

    private func appendSourceReviewLog(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        logText += "[\(DateFormatter.logStamp.string(from: Date()))] \(cleaned)\n"
    }
}
