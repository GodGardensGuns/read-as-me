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
