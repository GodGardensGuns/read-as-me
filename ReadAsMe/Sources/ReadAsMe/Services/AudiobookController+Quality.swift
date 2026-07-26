import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

@MainActor
extension AudiobookController {
    func chooseAuditAudio() {
        guard !auditState.isBusy, !conversionState.isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an Audiobook to Audit"
        panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio, .audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            selectedAuditAudioURL = url
            auditReport = nil
            selectedFindingIDs = []
            appendQualityLog("Audit audio: \(url.path)")
        }
    }

    func chooseExpectedText() {
        guard !auditState.isBusy, !conversionState.isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose the Expected Book or Transcript"
        panel.allowedContentTypes = [.epub, .pdf, .plainText, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            selectedExpectedTextURL = url
            appendQualityLog("Expected text: \(url.path)")
        }
    }

    func clearExpectedText() {
        guard !auditState.isBusy else { return }
        selectedExpectedTextURL = nil
    }

    func startExistingAudit() {
        guard let selectedAuditAudioURL, canStartExistingAudit else { return }
        Task {
            await performAudit(
                audioURL: selectedAuditAudioURL,
                expectedTextURL: selectedExpectedTextURL,
                generatedChunksURL: nil
            )
        }
    }

    func startGeneratedAudit(
        audioURL: URL,
        expectedTextURL: URL?,
        generatedChunksURL: URL?
    ) async {
        selectedAuditAudioURL = audioURL
        await performAudit(
            audioURL: audioURL,
            expectedTextURL: expectedTextURL,
            generatedChunksURL: generatedChunksURL
        )
        if auditState == .complete, let generatedChunksURL {
            cleanupGeneratedChunkAudio(around: generatedChunksURL)
        }
    }

    func repair(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        Task { await performRepair(selection: .ids(ids)) }
    }

    func repairAllSafe() {
        Task { await performRepair(selection: .allSafe) }
    }

    func repairAll() {
        Task { await performRepair(selection: .all) }
    }

    func openAuditReport() {
        guard let latestMarkdownReportURL else { return }
        NSWorkspace.shared.open(latestMarkdownReportURL)
    }

    func openLatestRepairedOutput() {
        guard let latestRepairedOutputURL else { return }
        NSWorkspace.shared.open(latestRepairedOutputURL)
    }

    func playFinding(_ finding: AuditFinding) {
        guard let source = selectedAuditAudioURL ?? auditReport.map({ URL(fileURLWithPath: $0.inputAudio) }) else { return }
        let player = AVPlayer(url: source)
        auditPlayer = player
        let contextStart = max(0, finding.timeRange.start - 2)
        player.seek(to: CMTime(seconds: contextStart, preferredTimescale: 600))
        player.play()
        let stopAfter = max(4, finding.timeRange.end - contextStart + 2)
        Task {
            try? await Task.sleep(for: .seconds(stopAfter))
            if auditPlayer === player {
                player.pause()
            }
        }
    }

    func removeAuditModelAndRuntime() {
        guard !auditState.isBusy else { return }
        let targets = [
            AppPaths.applicationSupport.appendingPathComponent("venvs/parakeet-audit", isDirectory: true),
            AppPaths.cache.appendingPathComponent("huggingface/hub/models--nvidia--parakeet-tdt-0.6b-v3", isDirectory: true),
        ]
        for target in targets where FileManager.default.fileExists(atPath: target.path) {
            do {
                try FileManager.default.removeItem(at: target)
                appendQualityLog("Removed: \(target.path)")
            } catch {
                appendQualityLog("Could not remove \(target.lastPathComponent): \(error.localizedDescription)")
            }
        }
        auditModelNoticeAccepted = false
        auditState = .idle
    }

    private func performAudit(audioURL: URL, expectedTextURL: URL?, generatedChunksURL: URL?) async {
        cancellationRequested = false
        auditReport = nil
        selectedFindingIDs = []
        latestAuditReportURL = nil
        latestMarkdownReportURL = nil
        latestRepairedOutputURL = nil
        auditState = .preparingAuditRuntime
        setQualityProgress(0.01, "Preparing Audit", "Checking disk space and local quality tools.")

        do {
            try preflightAudit(audioURL: audioURL)
            if serverProcess != nil {
                appendQualityLog("Stopping Qwen before loading Parakeet to conserve memory.")
                serverProcess?.process.terminate()
                serverProcess = nil
                serverState = .stopped
            }
            try await ensureAuditRuntimeReady()
            try throwIfQualityCancelled()
            let sessionDirectory = try makeAuditSessionDirectory(audioURL: audioURL)
            let manifestURL = sessionDirectory.appendingPathComponent("audit-manifest.json")
            let manifest = makeQualityManifest(
                audioURL: audioURL,
                expectedTextURL: expectedTextURL,
                generatedChunksURL: generatedChunksURL,
                repairSelection: nil
            )
            try QualityReportCodec.writeManifest(manifest, to: manifestURL)
            auditState = .analyzing
            let result = try await runQualityEngine(command: "audit", manifestURL: manifestURL)
            try throwIfQualityCancelled()
            guard let reportURL = result.reportURL else {
                throw AppError.message("The audit completed without producing a report.")
            }
            try loadAuditReport(reportURL)
            auditState = .complete
            setQualityProgress(1, auditReport?.summary.status ?? "Audit Complete", "\(auditReport?.summary.findingCount ?? 0) findings.")
        } catch {
            handleQualityFailure(error)
        }
    }

    private func performRepair(selection: RepairSelection) async {
        guard let report = auditReport, let reportURL = latestAuditReportURL else { return }
        cancellationRequested = false
        auditState = .repairing
        setQualityProgress(0.02, "Preparing Repair", "Creating a new repaired copy. The original will not be changed.")
        do {
            let selected = findings(for: selection, report: report)
            guard !selected.isEmpty else {
                throw AppError.message("No repairable findings match that selection.")
            }
            let needsQwen = selected.contains {
                [.missingSpeech, .extraSpeech, .substitution, .repeatedSpeech, .clipping].contains($0.type)
            }
            if needsQwen {
                guard voiceSampleURL != nil, hasQualityVoiceTranscript else {
                    throw AppError.message("Speech repair needs a voice sample and matching transcript. Choose them in Generate Audiobook first.")
                }
                try await ensureRuntimeReady()
                if !(await isServerReady()) {
                    try startServerProcess()
                    guard await waitForServerReady() else {
                        throw AppError.message("Qwen did not become ready for speech repair.")
                    }
                }
            }
            let audioURL = URL(fileURLWithPath: report.inputAudio)
            let sessionDirectory = try makeAuditSessionDirectory(audioURL: audioURL)
            let manifestURL = sessionDirectory.appendingPathComponent("repair-manifest.json")
            var manifest = makeQualityManifest(
                audioURL: audioURL,
                expectedTextURL: report.expectedText.map(URL.init(fileURLWithPath:)),
                generatedChunksURL: nil,
                repairSelection: selection
            )
            manifest = QualityManifest(
                schemaVersion: manifest.schemaVersion,
                sessionID: manifest.sessionID,
                inputAudio: manifest.inputAudio,
                expectedText: manifest.expectedText,
                generatedChunks: manifest.generatedChunks,
                voiceReference: voiceSampleURL?.path,
                voiceTranscript: qualityVoiceTranscriptPath(in: sessionDirectory),
                qualityProfile: manifest.qualityProfile,
                language: manifest.language,
                outputDirectory: manifest.outputDirectory,
                outputSameFormat: manifest.outputSameFormat,
                ffmpeg: manifest.ffmpeg,
                ffprobe: manifest.ffprobe,
                qwenPython: AppPaths.python.path,
                converter: AppPaths.converter.path,
                repairFindingIDs: manifest.repairFindingIDs,
                repairMode: manifest.repairMode,
                reportPath: reportURL.path
            )
            try QualityReportCodec.writeManifest(manifest, to: manifestURL)
            let result = try await runQualityEngine(command: "repair", manifestURL: manifestURL)
            if let repairedURL = result.outputURL {
                latestRepairedOutputURL = repairedURL
                latestOutputURL = repairedURL
            }
            try loadAuditReport(reportURL)
            auditState = .complete
            setQualityProgress(1, "Repair Complete", latestRepairedOutputURL?.lastPathComponent ?? "Verified repaired copy saved.")
        } catch {
            handleQualityFailure(error)
        }
    }

    private var hasQualityVoiceTranscript: Bool {
        switch voiceTranscriptMode {
        case .file:
            voiceTranscriptURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        case .text:
            !voiceTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func qualityVoiceTranscriptPath(in folder: URL) -> String? {
        switch voiceTranscriptMode {
        case .file:
            return voiceTranscriptURL?.path
        case .text:
            let url = folder.appendingPathComponent("repair-voice-transcript.txt")
            do {
                try voiceTranscriptText.write(to: url, atomically: true, encoding: .utf8)
                return url.path
            } catch {
                appendQualityLog("Could not stage repair voice transcript: \(error.localizedDescription)")
                return nil
            }
        }
    }

    private func findings(for selection: RepairSelection, report: AuditReport) -> [AuditFinding] {
        switch selection {
        case .ids(let ids):
            report.findings.filter { ids.contains($0.id) && $0.repairSafety != .unrepairable }
        case .allSafe:
            report.findings.filter { $0.repairSafety == .safe }
        case .all:
            report.findings.filter { $0.repairSafety != .unrepairable }
        }
    }

    private func makeQualityManifest(
        audioURL: URL,
        expectedTextURL: URL?,
        generatedChunksURL: URL?,
        repairSelection: RepairSelection?
    ) -> QualityManifest {
        let repairIDs: [String]?
        let repairMode: String?
        switch repairSelection {
        case .ids(let ids):
            repairIDs = Array(ids).sorted()
            repairMode = "ids"
        case .allSafe:
            repairIDs = nil
            repairMode = "all_safe"
        case .all:
            repairIDs = nil
            repairMode = "all"
        case nil:
            repairIDs = nil
            repairMode = nil
        }
        return QualityManifest(
            schemaVersion: 1,
            sessionID: qualitySessionID(for: audioURL),
            inputAudio: audioURL.path,
            expectedText: expectedTextURL?.path,
            generatedChunks: generatedChunksURL?.path,
            voiceReference: voiceSampleURL?.path,
            voiceTranscript: voiceTranscriptURL?.path,
            qualityProfile: qualityProfile.rawValue,
            language: "auto",
            outputDirectory: outputFolderURL.path,
            outputSameFormat: outputSameFormat,
            ffmpeg: AppPaths.ffmpeg.path,
            ffprobe: AppPaths.ffprobe.path,
            qwenPython: nil,
            converter: nil,
            repairFindingIDs: repairIDs,
            repairMode: repairMode,
            reportPath: nil
        )
    }

    private func preflightAudit(audioURL: URL) throws {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw AppError.message("The selected audiobook is missing.")
        }
        let values = try AppPaths.applicationSupport.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        let audioSize = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let required = max(7_000_000_000, audioSize * 3)
        guard available >= required else {
            throw AppError.message("Not enough free space. The audit needs about \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) available.")
        }
        let missing = AppPaths.missingAuditRequirements(includePython: false)
        guard missing.isEmpty else {
            throw AppError.message("The app bundle is missing a quality component: \(missing[0])")
        }
    }

    private func ensureAuditRuntimeReady() async throws {
        try AppPaths.createMutableDirectories()
        setQualityProgress(0.03, "Preparing Parakeet", "First setup downloads about 2.5 GB of model data.")
        let status = try await withCheckedThrowingContinuation { continuation in
            do {
                auditBootstrapProcess = try ProcessRunner.start(
                    executable: URL(fileURLWithPath: "/bin/bash"),
                    arguments: [
                        AppPaths.auditBootstrapScript.path,
                        AppPaths.applicationSupport.path,
                        AppPaths.bundledRuntime.path,
                    ],
                    workingDirectory: AppPaths.applicationSupport,
                    environment: AppPaths.converterEnvironment,
                    onOutput: { [weak self] text in self?.appendQualityLog(text) },
                    onTermination: { [weak self] status in
                        self?.auditBootstrapProcess = nil
                        continuation.resume(returning: status)
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            throw AppError.message("Parakeet runtime setup exited with status \(status).")
        }
        let missing = AppPaths.missingAuditRequirements()
        guard missing.isEmpty else {
            throw AppError.message("Parakeet setup is incomplete: \(missing[0])")
        }
    }

    private func runQualityEngine(command: String, manifestURL: URL) async throws -> (reportURL: URL?, outputURL: URL?) {
        qualityOutputBuffer = ""
        var foundReport: URL?
        var foundOutput: URL?
        let status = try await withCheckedThrowingContinuation { continuation in
            do {
                qualityProcess = try ProcessRunner.start(
                    executable: AppPaths.auditPython,
                    arguments: [AppPaths.qualityEngine.path, command, "--manifest", manifestURL.path],
                    workingDirectory: manifestURL.deletingLastPathComponent(),
                    environment: AppPaths.converterEnvironment,
                    onOutput: { [weak self] text in
                        guard let self else { return }
                        self.qualityOutputBuffer += text
                        while let newline = self.qualityOutputBuffer.firstIndex(of: "\n") {
                            let line = String(self.qualityOutputBuffer[..<newline])
                            self.qualityOutputBuffer.removeSubrange(...newline)
                            if let event = QualityReportCodec.decodeProgressLine(line) {
                                if let path = event.report { foundReport = URL(fileURLWithPath: path) }
                                if let path = event.output { foundOutput = URL(fileURLWithPath: path) }
                                self.applyQualityProgress(event)
                            } else {
                                self.appendQualityLog(line)
                            }
                        }
                    },
                    onTermination: { [weak self] status in
                        self?.qualityProcess = nil
                        continuation.resume(returning: status)
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
        if !qualityOutputBuffer.isEmpty {
            if let event = QualityReportCodec.decodeProgressLine(qualityOutputBuffer) {
                if let path = event.report { foundReport = URL(fileURLWithPath: path) }
                if let path = event.output { foundOutput = URL(fileURLWithPath: path) }
                applyQualityProgress(event)
            } else {
                appendQualityLog(qualityOutputBuffer)
            }
            qualityOutputBuffer = ""
        }
        guard status == 0 else {
            throw AppError.message("Quality engine exited with status \(status). See Logs for details.")
        }
        return (foundReport, foundOutput)
    }

    private func applyQualityProgress(_ event: QualityProgressEvent) {
        switch event.phase {
        case "transcribing": auditState = .transcribing
        case "analyzing": auditState = .analyzing
        case "repairing": auditState = .repairing
        case "verifying": auditState = .verifying
        default: break
        }
        if let progress = event.progress {
            setQualityProgress(progress, auditState.label, event.message ?? progressDetail)
        }
        if let message = event.message {
            appendQualityLog(message)
        }
    }

    private func loadAuditReport(_ url: URL) throws {
        let report = try QualityReportCodec.decodeReport(at: url)
        auditReport = report
        latestAuditReportURL = url
        if let markdown = report.outputFiles["markdown_report"] {
            latestMarkdownReportURL = URL(fileURLWithPath: markdown)
        }
        if voiceSampleURL == nil, let reference = report.outputFiles["voice_reference"] {
            voiceSampleURL = URL(fileURLWithPath: reference)
            appendQualityLog("Selected a clean voice reference automatically.")
        }
        if voiceTranscriptURL == nil, let transcript = report.outputFiles["voice_reference_transcript"] {
            voiceTranscriptURL = URL(fileURLWithPath: transcript)
            voiceTranscriptMode = .file
        }
        selectedFindingIDs = Set(
            report.findings
                .filter { $0.repairSafety == .safe && $0.repairStatus == .pending }
                .map(\.id)
        )
    }

    private func makeAuditSessionDirectory(audioURL: URL) throws -> URL {
        try FileManager.default.createDirectory(at: AppPaths.auditRunRoot, withIntermediateDirectories: true)
        let stem = audioURL.deletingPathExtension().lastPathComponent.sanitizedFileName
        let url = AppPaths.auditRunRoot.appendingPathComponent("\(DateFormatter.runStamp.string(from: Date()))-\(stem)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func qualitySessionID(for audioURL: URL) -> String {
        let values = try? audioURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        return "\(audioURL.deletingPathExtension().lastPathComponent.sanitizedFileName)-\(size)-\(modified)"
    }

    private func cleanupGeneratedChunkAudio(around manifestURL: URL) {
        let chunksFolder = manifestURL.deletingLastPathComponent()
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: chunksFolder,
            includingPropertiesForKeys: nil
        ) else { return }
        var removed = 0
        for child in children where child.pathExtension.lowercased() == "wav" {
            do {
                try FileManager.default.removeItem(at: child)
                removed += 1
            } catch {
                appendQualityLog("Could not clean temporary chunk \(child.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if removed > 0 {
            appendQualityLog("Cleaned up \(removed) temporary generated chunks after the audit.")
        }
    }

    private func throwIfQualityCancelled() throws {
        if cancellationRequested { throw CancellationError() }
    }

    private func handleQualityFailure(_ error: Error) {
        if cancellationRequested || error is CancellationError {
            cancellationRequested = false
            auditState = .idle
            setQualityProgress(0, "Cancelled", "The quality operation was cancelled.")
            appendQualityLog("Quality operation cancelled.")
            return
        }
        auditState = .failed(error.localizedDescription)
        setQualityProgress(progressFraction, "Quality Check Failed", error.localizedDescription)
        appendQualityLog("Quality check failed: \(error.localizedDescription)")
    }

    private func setQualityProgress(_ fraction: Double, _ title: String, _ detail: String) {
        progressFraction = min(max(fraction, 0), 1)
        progressTitle = title
        progressDetail = detail
    }

    private func appendQualityLog(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        logText += "[\(DateFormatter.logStamp.string(from: Date()))] \(cleaned)\n"
    }
}
