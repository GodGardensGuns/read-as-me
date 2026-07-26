import Foundation
import XCTest
@testable import ReadAsMe

final class ReadAsMeTests: XCTestCase {
    func testSanitizedFileNameRemovesUnsafeCharacters() {
        XCTAssertEqual("  My Book: Vol. 1  ".sanitizedFileName, "My-Book-Vol-1")
        XCTAssertEqual("***".sanitizedFileName, "audiobook")
        XCTAssertEqual("Déjà Vu".sanitizedFileName, "Déjà-Vu")
    }

    func testConversionBusyState() {
        XCTAssertFalse(ConversionState.idle.isBusy)
        XCTAssertTrue(ConversionState.preparing.isBusy)
        XCTAssertTrue(ConversionState.converting.isBusy)
        XCTAssertFalse(ConversionState.failed("error").isBusy)
    }

    func testAuditBusyState() {
        XCTAssertFalse(AuditState.idle.isBusy)
        XCTAssertTrue(AuditState.preparingAuditRuntime.isBusy)
        XCTAssertTrue(AuditState.transcribing.isBusy)
        XCTAssertTrue(AuditState.analyzing.isBusy)
        XCTAssertTrue(AuditState.repairing.isBusy)
        XCTAssertTrue(AuditState.verifying.isBusy)
        XCTAssertFalse(AuditState.complete.isBusy)
    }

    func testQualityReportDecodesVersionedSnakeCaseSchema() throws {
        let json = """
        {
          "schema_version": 1,
          "report_id": "report-1",
          "created_at": "2026-07-26T12:00:00Z",
          "input_audio": "/tmp/book.wav",
          "expected_text": null,
          "quality_profile": "Natural",
          "language": "en",
          "incomplete": false,
          "summary": {
            "status": "Passed with Warnings",
            "duration_seconds": 12.5,
            "finding_count": 1,
            "critical_count": 0,
            "warning_count": 1,
            "repaired_count": 0
          },
          "global_metrics": {"peak_dbfs": -3.2},
          "findings": [{
            "id": "finding-1",
            "type": "long_pause",
            "severity": "warning",
            "confidence": 0.95,
            "time_range": {"start": 2.0, "end": 5.0},
            "message": "Long pause",
            "expected_text": null,
            "observed_text": null,
            "evidence": {"summary": "silence", "metrics": {"duration_seconds": 3.0}},
            "source_offset": null,
            "source_length": null,
            "source_chunk": null,
            "repair_safety": "safe",
            "repair_action": "Shorten",
            "repair_status": "pending",
            "before_verification": null,
            "after_verification": null
          }],
          "output_files": {"markdown_report": "/tmp/book.audit.md"},
          "timeline_map": null
        }
        """
        let report = try QualityReportCodec.decoder.decode(AuditReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.findings.first?.type, .longPause)
        XCTAssertEqual(report.findings.first?.repairSafety, .safe)
    }

    func testServerProbeRequiresVoiceCloneEndpoint() throws {
        let compatible = try XCTUnwrap(
            #"{"named_endpoints":{"/run_voice_clone":{"parameters":[]}}}"#.data(using: .utf8)
        )
        let unrelated = try XCTUnwrap(
            #"{"named_endpoints":{"/predict":{"parameters":[]}}}"#.data(using: .utf8)
        )

        XCTAssertTrue(ServerProbe.isCompatibleInfo(compatible))
        XCTAssertFalse(ServerProbe.isCompatibleInfo(unrelated))
        XCTAssertFalse(ServerProbe.isCompatibleInfo(Data("not json".utf8)))
    }

    @MainActor
    func testProcessRunnerDeliversFinalOutputBeforeTermination() async throws {
        let terminated = expectation(description: "process terminated")
        var collectedOutput = ""
        var terminationStatus: Int32?

        let runningProcess = try ProcessRunner.start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'final output'"],
            onOutput: { output in
                collectedOutput += output
            },
            onTermination: { status in
                terminationStatus = status
                terminated.fulfill()
            }
        )

        await fulfillment(of: [terminated], timeout: 2)
        withExtendedLifetime(runningProcess) {}

        XCTAssertEqual(terminationStatus, 0)
        XCTAssertEqual(collectedOutput, "final output")
    }
}
