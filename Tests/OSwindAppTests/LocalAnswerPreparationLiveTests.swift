import XCTest
@testable import OSwindCore
@testable import OSwind

@MainActor final class LocalAnswerPreparationLiveTests: XCTestCase {
    struct Report: Encodable {
        let state: String
        let selectedModelAlreadyReportedLoaded: Bool
        let preparation: LocalModelPreparation
        let scope: String
    }
    func testExplicitExistingLocalModelLoadsWithoutEvidenceOrConfigurationChanges() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OSWIND_TEST_LOCAL_MODEL_PREPARE"] == "1" else { throw XCTSkip("Explicit existing-model preparation only; no weights downloaded") }
        let endpoint = try XCTUnwrap(environment["OSWIND_TEST_PREPARE_ENDPOINT"])
        let model = try XCTUnwrap(environment["OSWIND_TEST_PREPARE_MODEL"])
        let digest = try XCTUnwrap(environment["OSWIND_TEST_PREPARE_DIGEST"])
        let output = URL(fileURLWithPath:try XCTUnwrap(environment["OSWIND_TEST_PREPARE_REPORT"]))
        guard !FileManager.default.fileExists(atPath:output.path) else { throw OSwindError.invalid("Preparation receipt already exists; do not repeat the live request") }
        let installed = try await OllamaClient.shared.models(endpoint:endpoint)
        let selected = try XCTUnwrap(installed.first { $0.name == model })
        XCTAssertEqual(selected.digest,digest); XCTAssertFalse(selected.isRemote)
        guard selected.digest == digest, !selected.isRemote else { return }
        let before = try await OllamaClient.shared.runningModels(endpoint:endpoint)
        let library = LocalModelLibraryModel()
        library.configure(answer:endpoint,search:"http://127.0.0.1:9",answerModel:model);library.select(.search)
        library.prepareAnswer()
        let deadline = ContinuousClock.now.advanced(by:.seconds(330))
        while library.busy && ContinuousClock.now < deadline { try await Task.sleep(nanoseconds:50_000_000) }
        if library.busy {
            library.cancelPreparation();await library.cancelAndWait();XCTFail("Model preparation exceeded its bounded observation deadline");return
        }
        let value = try XCTUnwrap(library.prepared,library.preparationStatus ?? "No load observation")
        XCTAssertEqual(value.requestedModel,model);XCTAssertEqual(value.model,model);XCTAssertEqual(value.endpoint,endpoint);XCTAssertEqual(value.digest,digest)
        XCTAssertGreaterThan(value.residentBytes,0);XCTAssertGreaterThan(value.observationExpiresAt,Date())
        XCTAssertEqual(library.answerModel,model);XCTAssertEqual(library.role,.search)
        await library.cancelAndWait()
        let encoder = JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];encoder.dateEncodingStrategy = .iso8601
        let report = Report(state:"completed",selectedModelAlreadyReportedLoaded:before.contains { $0.name == model && $0.digest == digest },preparation:value,scope:"One explicitly configured local model load through the actual app controller/client. Empty API request, finite five-minute retention; no history/store/settings root or answer inference. Server residency/load duration are observations, not processor-use, cold-start, first-answer speed or power measurements. No model unloaded and global server settings unchanged.")
        try encoder.encode(report).write(to:output,options:.withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
        print("OSWIND_LIVE_PREPARE model=\(value.model) digest=\(value.digest) residentBytes=\(value.residentBytes) elapsedSeconds=\(value.elapsedSeconds)")
    }
}
