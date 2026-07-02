import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AudiobookController: ObservableObject {
    @Published var selectedBookURL: URL?
    @Published var outputFolderURL: URL = QwenPaths.defaultOutput
    @Published var voiceSampleURL: URL?
    @Published var voiceTranscriptURL: URL?
    @Published var voiceTranscriptMode: TranscriptInputMode = .file
    @Published var voiceTranscriptText: String = ""
    @Published var latestOutputURL: URL?
    @Published var serverState: ServerState = .stopped
    @Published var conversionState: ConversionState = .idle
    @Published var logText: String = ""
    @Published var progressFraction: Double = 0
    @Published var progressTitle: String = "Ready"
    @Published var progressDetail: String = "Choose a book to convert."
    @Published var completedChunks: Int = 0
    @Published var totalChunks: Int = 0

    private var serverProcess: RunningProcess?
    private var converterProcess: RunningProcess?
    private var bootstrapProcess: RunningProcess?
    private var diagnosticsLogged = false

    var canConvert: Bool {
        selectedBookURL != nil
            && hasVoiceSample
            && hasUsableTranscript
            && !conversionState.isBusy
    }

    private var hasVoiceSample: Bool {
        guard let voiceSampleURL else { return false }
        return FileManager.default.fileExists(atPath: voiceSampleURL.path)
    }

    private var hasUsableTranscript: Bool {
        switch voiceTranscriptMode {
        case .file:
            guard let voiceTranscriptURL else { return false }
            return FileManager.default.fileExists(atPath: voiceTranscriptURL.path)
        case .text:
            return !voiceTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    init() {
        loadDefaultTranscriptText()
        appendLog("Ready.")
        appendLog("Output folder: \(outputFolderURL.path)")
        appendLog("App support: \(QwenPaths.applicationSupport.path)")
        appendLog("Choose a voice sample and matching transcript before converting.")
        logDiagnosticsIfNeeded()
        Task {
            if await isServerReady() {
                serverState = .external
                appendLog("Qwen server is already running.")
            }
        }
    }

    func chooseBook() {
        let panel = NSOpenPanel()
        panel.title = "Choose Book"
        panel.allowedContentTypes = [.epub, .pdf, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            selectedBookURL = panel.url
            appendLog("Selected book: \(panel.url?.lastPathComponent ?? "")")
        }
    }

    func chooseVoiceSample() {
        let panel = NSOpenPanel()
        panel.title = "Choose Voice Sample"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            voiceSampleURL = url
            appendLog("Voice sample: \(url.path)")
        }
    }

    func chooseVoiceTranscript() {
        let panel = NSOpenPanel()
        panel.title = "Choose Voice Transcript"
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                voiceTranscriptText = try Self.readText(from: url)
                voiceTranscriptURL = url
                voiceTranscriptMode = .file
                appendLog("Voice transcript: \(url.path)")
            } catch {
                appendLog("Could not read transcript: \(error.localizedDescription)")
            }
        }
    }

    func clearVoiceSelection() {
        voiceSampleURL = nil
        voiceTranscriptURL = nil
        voiceTranscriptText = ""
        voiceTranscriptMode = .file
        appendLog("Voice selection cleared.")
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Output Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            outputFolderURL = url
            appendLog("Output folder: \(url.path)")
        }
    }

    func startServer() {
        guard serverState == .stopped else { return }
        serverState = .starting
        setProgress(fraction: 0.02, title: "Preparing Runtime", detail: "Checking local Qwen setup.")
        Task {
            do {
                try await ensureRuntimeReady()
                try startServerProcess()
            } catch {
                serverState = .stopped
                setProgress(fraction: progressFraction, title: "Setup Failed", detail: error.localizedDescription)
                appendLog("Failed to start Qwen: \(error.localizedDescription)")
            }
        }
    }

    func stopServer() {
        if bootstrapProcess != nil {
            appendLog("Stopping runtime setup...")
            bootstrapProcess?.process.terminate()
            bootstrapProcess = nil
        }

        guard let serverProcess else {
            serverState = .stopped
            return
        }
        appendLog("Stopping Qwen server...")
        bootstrapProcess?.process.terminate()
        bootstrapProcess = nil
        serverProcess.process.terminate()
        self.serverProcess = nil
        serverState = .stopped
    }

    func convertSelectedBook() {
        guard let selectedBookURL, !conversionState.isBusy else { return }
        Task {
            await convert(bookURL: selectedBookURL)
        }
    }

    func cancelConversion() {
        appendLog("Cancel requested.")
        converterProcess?.process.terminate()
        converterProcess = nil
        bootstrapProcess?.process.terminate()
        bootstrapProcess = nil
        conversionState = .idle
        setProgress(fraction: 0, title: "Cancelled", detail: "Conversion was cancelled.", allowDecrease: true)
    }

    func openOutputFolder() {
        NSWorkspace.shared.open(outputFolderURL)
    }

    func openLatestOutput() {
        guard let latestOutputURL else { return }
        NSWorkspace.shared.open(latestOutputURL)
    }

    func terminateOwnedProcesses() {
        converterProcess?.process.terminate()
        converterProcess = nil
        bootstrapProcess?.process.terminate()
        bootstrapProcess = nil
        serverProcess?.process.terminate()
        serverProcess = nil
    }

    private func loadDefaultTranscriptText() {
        voiceTranscriptText = ""
    }

    private static func readText(from url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        return try String(contentsOf: url, usedEncoding: &encoding)
    }

    private func convert(bookURL: URL) async {
        conversionState = .preparing
        latestOutputURL = nil
        completedChunks = 0
        totalChunks = 0
        setProgress(fraction: 0.03, title: "Preparing", detail: "Checking files.", allowDecrease: true)

        do {
            logDiagnosticsIfNeeded()
            try await ensureRuntimeReady()
            try validateRequiredFiles()
            try FileManager.default.createDirectory(at: QwenPaths.runRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outputFolderURL, withIntermediateDirectories: true)

            if !(await isServerReady()) {
                setProgress(fraction: 0.06, title: "Starting Qwen", detail: "Waiting for the local server.")
                try startServerProcess()
                let ready = await waitForServerReady(timeoutSeconds: 240)
                guard ready else {
                    throw AppError.message("Qwen server is not ready.")
                }
            } else if serverState == .stopped {
                serverState = .external
            }

            setProgress(fraction: 0.10, title: "Preparing Book", detail: "Copying files into a run folder.")
            let runDirectory = try makeRunDirectory(for: bookURL)
            let bookFolder = runDirectory.appendingPathComponent("book_to_convert", isDirectory: true)
            let audiobookFolder = runDirectory.appendingPathComponent("audiobooks", isDirectory: true)
            try FileManager.default.createDirectory(at: bookFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: audiobookFolder, withIntermediateDirectories: true)
            let runTranscript = try transcriptURLForConversion(in: runDirectory)

            let stagedBook = bookFolder.appendingPathComponent(bookURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: stagedBook.path) {
                try FileManager.default.removeItem(at: stagedBook)
            }
            try FileManager.default.copyItem(at: bookURL, to: stagedBook)

            appendLog("Run folder: \(runDirectory.path)")
            appendLog("Converting \(bookURL.lastPathComponent)...")
            conversionState = .converting
            setProgress(fraction: 0.12, title: "Converting", detail: "Starting the audiobook converter.")

            let status = try await runConverter(in: runDirectory, transcriptURL: runTranscript)
            guard status == 0 else {
                throw AppError.message("Converter exited with status \(status).")
            }

            let generatedFile = audiobookFolder.appendingPathComponent(bookURL.deletingPathExtension().lastPathComponent + ".wav")
            guard FileManager.default.fileExists(atPath: generatedFile.path) else {
                throw AppError.message("Conversion finished but no audio file was found.")
            }

            let finalOutput = try copyOutput(generatedFile, originalBook: bookURL)
            latestOutputURL = finalOutput
            conversionState = .complete(finalOutput)
            setProgress(fraction: 1, title: "Complete", detail: finalOutput.lastPathComponent)
            appendLog("Saved: \(finalOutput.path)")
        } catch {
            conversionState = .failed(error.localizedDescription)
            setProgress(fraction: progressFraction, title: "Failed", detail: error.localizedDescription)
            appendLog("Failed: \(error.localizedDescription)")
        }
    }

    private func ensureRuntimeReady() async throws {
        try QwenPaths.createMutableDirectories()

        let missingBootstrapRequirements = QwenPaths.missingBootstrapRequirements()
        guard missingBootstrapRequirements.isEmpty else {
            throw AppError.message("The app bundle is missing: \(missingBootstrapRequirements.first ?? "")")
        }

        appendLog("Checking runtime setup...")
        setProgress(fraction: max(progressFraction, 0.04), title: "Preparing Runtime", detail: "Checking Python and Qwen files.")

        let status = try await runBootstrap()
        guard status == 0 else {
            throw AppError.message("Runtime setup exited with status \(status).")
        }

        let missing = QwenPaths.missingRequirements()
        guard missing.isEmpty else {
            throw AppError.message("Runtime setup is incomplete: \(missing.first ?? "")")
        }

        appendLog("Runtime is ready.")
    }

    private func runBootstrap() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            do {
                bootstrapProcess = try ProcessRunner.start(
                    executable: URL(fileURLWithPath: "/bin/bash"),
                    arguments: [
                        QwenPaths.bootstrapScript.path,
                        QwenPaths.applicationSupport.path,
                        QwenPaths.bundledRuntime.path
                    ],
                    workingDirectory: QwenPaths.applicationSupport,
                    environment: QwenPaths.converterEnvironment,
                    onOutput: { [weak self] text in
                        self?.appendLog(text)
                    },
                    onTermination: { [weak self] status in
                        self?.bootstrapProcess = nil
                        continuation.resume(returning: status)
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func startServerProcess() throws {
        guard serverProcess == nil else { return }

        let missing = QwenPaths.missingRequirements()
        guard missing.isEmpty else {
            throw AppError.message("Missing required file: \(missing.first ?? "")")
        }

        serverState = .starting
        appendLog("Starting Qwen server...")
        logDiagnosticsIfNeeded()

        serverProcess = try ProcessRunner.start(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [QwenPaths.serverScript.path],
            workingDirectory: QwenPaths.applicationSupport,
            environment: QwenPaths.converterEnvironment,
            onOutput: { [weak self] text in
                self?.appendLog(text)
            },
            onTermination: { [weak self] status in
                guard let self else { return }
                self.appendLog("Qwen server exited with status \(status).")
                self.serverProcess = nil
                if self.serverState != .external {
                    self.serverState = .stopped
                }
            }
        )

        Task {
            let ready = await waitForServerReady(timeoutSeconds: 240)
            if ready {
                serverState = .running
                appendLog("Qwen server is ready.")
            } else if serverProcess != nil {
                appendLog("Qwen server did not become ready before timeout.")
                stopServer()
            }
        }
    }

    private func runConverter(in runDirectory: URL, transcriptURL: URL) async throws -> Int32 {
        guard let voiceSampleURL else {
            throw AppError.message("Choose a voice sample before converting.")
        }
        let voiceSamplePath = voiceSampleURL.path
        let voiceTranscriptPath = transcriptURL.path
        return try await withCheckedThrowingContinuation { continuation in
            do {
                converterProcess = try ProcessRunner.start(
                    executable: QwenPaths.python,
                    arguments: [
                        QwenPaths.converter.path,
                        "--voice-clone",
                        "--voice-sample",
                        voiceSamplePath,
                        "--voice-transcript-file",
                        voiceTranscriptPath
                    ],
                    workingDirectory: runDirectory,
                    environment: QwenPaths.converterEnvironment,
                    onOutput: { [weak self] text in
                        self?.appendLog(text)
                    },
                    onTermination: { [weak self] status in
                        self?.converterProcess = nil
                        continuation.resume(returning: status)
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func validateRequiredFiles() throws {
        let missing = QwenPaths.missingRequirements()
        guard missing.isEmpty else {
            throw AppError.message("Missing required file: \(missing.first ?? "")")
        }
        guard let voiceSampleURL else {
            throw AppError.message("Choose a voice sample before converting.")
        }
        guard FileManager.default.fileExists(atPath: voiceSampleURL.path) else {
            throw AppError.message("Missing voice sample: \(voiceSampleURL.path)")
        }
        switch voiceTranscriptMode {
        case .file:
            guard let voiceTranscriptURL else {
                throw AppError.message("Choose a voice transcript file or switch to Text mode.")
            }
            guard FileManager.default.fileExists(atPath: voiceTranscriptURL.path) else {
                throw AppError.message("Missing voice transcript file: \(voiceTranscriptURL.path)")
            }
        case .text:
            guard !voiceTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.message("Voice transcript text is empty.")
            }
        }
    }

    private func makeRunDirectory(for bookURL: URL) throws -> URL {
        let stamp = DateFormatter.runStamp.string(from: Date())
        let stem = bookURL.deletingPathExtension().lastPathComponent.sanitizedFileName
        let url = QwenPaths.runRoot.appendingPathComponent("\(stamp)-\(stem)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTranscriptFile(in runDirectory: URL) throws -> URL {
        let transcriptURL = runDirectory.appendingPathComponent("voice_transcript.txt")
        try voiceTranscriptText.write(to: transcriptURL, atomically: true, encoding: .utf8)
        return transcriptURL
    }

    private func transcriptURLForConversion(in runDirectory: URL) throws -> URL {
        switch voiceTranscriptMode {
        case .file:
            guard let voiceTranscriptURL else {
                throw AppError.message("Choose a voice transcript file or switch to Text mode.")
            }
            return voiceTranscriptURL
        case .text:
            return try makeTranscriptFile(in: runDirectory)
        }
    }

    private func copyOutput(_ generatedFile: URL, originalBook: URL) throws -> URL {
        let stem = originalBook.deletingPathExtension().lastPathComponent.sanitizedFileName
        let stamp = DateFormatter.outputStamp.string(from: Date())
        let destination = outputFolderURL.appendingPathComponent("\(stem)-qwen-\(stamp).wav")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: generatedFile, to: destination)
        return destination
    }

    private func waitForServerReady(timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if await isServerReady() {
                return true
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return false
    }

    private func isServerReady() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:7860/gradio_api/info") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func appendLog(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .newlines)
        guard !cleaned.isEmpty else { return }
        cleaned
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .forEach(updateProgressFromLogLine)
        logText += "[\(DateFormatter.logStamp.string(from: Date()))] \(cleaned)\n"
    }

    private func updateProgressFromLogLine(_ line: String) {
        if line.contains("Creating converter environment") || line.contains("Installing converter packages") {
            setProgress(fraction: max(progressFraction, 0.05), title: "Installing Runtime", detail: "Setting up the converter environment.")
            return
        }

        if line.contains("Creating Qwen TTS environment") || line.contains("Installing Qwen TTS packages") {
            setProgress(fraction: max(progressFraction, 0.07), title: "Installing Runtime", detail: "Setting up the Qwen voice engine.")
            return
        }

        if line.contains("Runtime setup complete") || line.contains("Runtime is already installed") {
            setProgress(fraction: max(progressFraction, 0.08), title: "Runtime Ready", detail: "Local Qwen setup is ready.")
            return
        }

        if line.contains("Extracting text") {
            setProgress(fraction: 0.15, title: "Extracting Text", detail: "Reading the selected book.")
            return
        }

        if line.contains("Extracted text") {
            setProgress(fraction: 0.20, title: "Extracted Text", detail: "Preparing chunks.")
            return
        }

        if let chunks = firstCapturedInts(in: line, pattern: #"Split into\s+(\d+)\s+chunks"#)?.first {
            totalChunks = chunks
            completedChunks = 0
            setProgress(fraction: 0.24, title: "Processing Chunks", detail: "0 of \(chunks) chunks complete.")
            return
        }

        if let chunks = firstCapturedInts(in: line, pattern: #"Processing\s+(\d+)\s+chunks"#)?.first {
            totalChunks = chunks
            completedChunks = 0
            setProgress(fraction: 0.25, title: "Processing Chunks", detail: "0 of \(chunks) chunks complete.")
            return
        }

        if let values = firstCapturedInts(in: line, pattern: #"Chunk\s+(\d+)\s*/\s*(\d+)\s+(started|running|processing)"#),
           values.count >= 2 {
            let currentChunk = values[0]
            totalChunks = values[1]
            completedChunks = max(0, currentChunk - 1)
            let chunkFraction = Double(completedChunks) / Double(max(totalChunks, 1))
            let overallFraction = 0.25 + (0.65 * chunkFraction)
            setProgress(
                fraction: overallFraction,
                title: "Processing Chunks",
                detail: "Chunk \(currentChunk) of \(totalChunks) is running."
            )
            return
        }

        if let values = firstCapturedInts(in: line, pattern: #"Chunk\s+(\d+)\s*/\s*(\d+)\s+completed"#),
           values.count == 2 {
            completedChunks = values[0]
            totalChunks = values[1]
            let chunkFraction = Double(completedChunks) / Double(max(totalChunks, 1))
            let overallFraction = 0.25 + (0.65 * chunkFraction)
            setProgress(
                fraction: overallFraction,
                title: "Processing Chunks",
                detail: "\(completedChunks) of \(totalChunks) chunks complete."
            )
            return
        }

        if let values = firstCapturedInts(in: line, pattern: #"Chunk\s+(\d+)\s*/\s*(\d+)\s+(FAILED|ERROR)"#),
           values.count >= 2 {
            completedChunks = values[0]
            totalChunks = values[1]
            setProgress(
                fraction: progressFraction,
                title: "Chunk Issue",
                detail: "Chunk \(completedChunks) of \(totalChunks) did not complete."
            )
            return
        }

        if line.contains("Audiobook saved") || line.contains("Saved audiobook") {
            setProgress(fraction: 0.96, title: "Saving Audio", detail: "Writing the audiobook file.")
            return
        }

        if line.contains("Conversion completed") {
            setProgress(fraction: 0.98, title: "Finalizing", detail: "Finishing conversion.")
        }
    }

    private func firstCapturedInts(in text: String, pattern: String) -> [Int]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }

        var values: [Int] = []
        for index in 1..<match.numberOfRanges {
            let captureRange = match.range(at: index)
            guard captureRange.location != NSNotFound else { continue }
            if let value = Int(nsText.substring(with: captureRange)) {
                values.append(value)
            }
        }

        return values.isEmpty ? nil : values
    }

    private func setProgress(fraction: Double, title: String, detail: String, allowDecrease: Bool = false) {
        let clamped = min(max(fraction, 0), 1)
        progressFraction = allowDecrease ? clamped : max(progressFraction, clamped)
        progressTitle = title
        progressDetail = detail
    }

    private func logDiagnosticsIfNeeded() {
        guard !diagnosticsLogged else { return }
        diagnosticsLogged = true

        appendLog("Diagnostics:")
        appendLog("  Bundled runtime: \(QwenPaths.bundledRuntime.path)")
        appendLog("  App support: \(QwenPaths.applicationSupport.path)")
        appendLog("  Server script: \(QwenPaths.serverScript.path)")

        appendLog("  Python runtime: bundled or app-managed")
        appendLog("  External SoX/ffmpeg: not required")

        do {
            let script = try String(contentsOf: QwenPaths.serverScript, encoding: .utf8)
            if script.contains("torch.backends.mps.is_available") {
                appendLog("  Qwen device: auto (MPS if available, CPU fallback)")
            } else if script.contains("--device mps") {
                appendLog("  Qwen device: mps")
            }
            if script.contains("--dtype float32") {
                appendLog("  Qwen dtype: float32")
            } else if script.contains("--dtype bfloat16") {
                appendLog("  Qwen dtype: bfloat16")
            } else if script.contains("--dtype float16") || script.contains("--dtype fp16") {
                appendLog("  Qwen dtype: float16")
            }
            if script.contains("--max-new-tokens") {
                appendLog("  Qwen max tokens: set in server script")
            } else {
                appendLog("  Qwen max tokens: model default")
            }
        } catch {
            appendLog("  Could not read server script diagnostics: \(error.localizedDescription)")
        }
    }

}

enum AppError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        }
    }
}
