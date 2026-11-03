import XCTest
import Foundation
@testable import OSwindCore

final class VaultCredentialDiagnosticTests:XCTestCase {
    func testCredentialActionsCannotEnterReadOnlyRetryOrValidation()async throws {
        for operation:VaultNativeOperation in [.imageCreate,.imageAttach] {
            let box=CredentialDiagnosticProbe()
            XCTAssertTrue(operation.mutates)
            do {
                _=try await VaultReadOnlyQuery.run(operation:operation,validate:{box.countValidation()},query:{_ in box.countQuery();return .init(status:0,stdout:Data(),stderr:Data())})
                XCTFail("Credential action entered read-only recovery")
            } catch {}
            XCTAssertEqual(box.counts().validation,0);XCTAssertEqual(box.counts().query,0)
        }
    }
    func testCredentialStdoutExcludedAndNativeStderrMetadataBounded()throws {
        let stdout=Data(repeating:65,count:20000),stderr=Data(repeating:66,count:20000)
        for operation:VaultNativeOperation in [.imageCreate,.imageAttach] {
            let diagnostic=VaultNativeDiagnostic(operation:operation,result:.init(status:35,stdout:stdout,stderr:stderr),durationSeconds:0.25)
            XCTAssertNil(diagnostic.stdoutSuffix);XCTAssertEqual(diagnostic.stderrSuffix.utf8.count,4096)
            XCTAssertEqual(diagnostic.summary.stdoutBytes,20000);XCTAssertEqual(diagnostic.summary.stderrBytes,20000)
            XCTAssertEqual(diagnostic.summary.stdoutSHA256,BackupSHA256.hex(stdout));XCTAssertEqual(diagnostic.summary.stderrSHA256,BackupSHA256.hex(stderr))
            let decoded=try JSONDecoder().decode(VaultNativeDiagnostic.self,from:JSONEncoder().encode(diagnostic))
            XCTAssertEqual(decoded.summary,diagnostic.summary);XCTAssertNil(decoded.stdoutSuffix);XCTAssertEqual(decoded.durationSeconds,0.25)
        }
    }
    func testOwnedCredentialTraceRefusesSecretBeforeExport()throws {
        let sentinel=Data("OWNED-REDACTION-SENTINEL-7429".utf8)
        for operation:VaultNativeOperation in [.imageCreate,.imageAttach] {
            let unsafe=VaultNativeDiagnostic(operation:operation,result:.init(status:35,stdout:Data(),stderr:sentinel))
            XCTAssertThrowsError(try OwnedVaultNativeTrace.redactedJSON(JSONEncoder().encode(unsafe),roots:[],secret:sentinel))
            let safe=VaultNativeSummary(operation:operation,result:.init(status:35,stdout:sentinel,stderr:sentinel))
            XCTAssertNoThrow(try OwnedVaultNativeTrace.redactedJSON(JSONEncoder().encode(safe),roots:[],secret:sentinel))
        }
    }
}

final class NativeVaultCredentialDiagnosticTests:XCTestCase {
    func testActualFailedCreationRetainsNativeResultWithoutCredentialOutput()async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Explicit owned native credential-action failure fixture")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-vault-create-diagnostic-"+UUID().uuidString)
        try Paths.ensure(root);defer {try? FileManager.default.removeItem(at:root)}
        let package=root.appendingPathComponent("Fixture.oswindvault"),paths=try VaultPaths(package)
        // Construct the intended path while absent, then place an owned regular
        // file at its package parent. The real native helper must refuse; no
        // image, mounted volume or credential file is needed for this control.
        let canary=Data("Owned unavailable package parent".utf8);try canary.write(to:package)
        let probe=CredentialDiagnosticProbe(),secret=Data(UUID().uuidString.utf8)
        let driver=NativeVaultDriver(observer:{probe.append($0)},willMutate:{operation,_ in probe.mutation(operation)},credentialHelperReady:{helper,pid in probe.helper(helper,pid)})
        do {try await driver.create(paths:paths,capacityGiB:1,secret:secret);XCTFail("Native creation accepted an owned file as its parent")}
        catch {}
        let events=probe.events();XCTAssertEqual(events.count,1)
        let event=try XCTUnwrap(events.first);XCTAssertEqual(event.summary.operation,.imageCreate)
        XCTAssertEqual(event.summary.termination,.exit);XCTAssertNotEqual(event.summary.status,0);XCTAssertGreaterThan(event.summary.stderrBytes,0)
        XCTAssertTrue(event.durationSeconds.isFinite);XCTAssertGreaterThanOrEqual(event.durationSeconds,0);XCTAssertNil(event.stdoutSuffix)
        XCTAssertEqual(probe.mutations(),[.imageCreate]);XCTAssertEqual(probe.helpers().map(\.0),[.create]);XCTAssertTrue(probe.helpers().allSatisfy {$0.1>0})
        XCTAssertEqual(try Data(contentsOf:package),canary);XCTAssertFalse(FileManager.default.fileExists(atPath:paths.image.path))
        let exported=try OwnedVaultNativeTrace.redactedJSON(JSONEncoder().encode(event),roots:[root],secret:secret)
        XCTAssertNil(exported.range(of:secret))
        if let path=ProcessInfo.processInfo.environment["OSWIND_TEST_CREDENTIAL_DIAGNOSTIC_DIR"] {
            let directory=URL(fileURLWithPath:path);try Paths.ensure(directory)
            try exported.write(to:directory.appendingPathComponent("native-create-result.json"),options:.withoutOverwriting)
        }
        print("OWNED_NATIVE_CREATE_DIAGNOSTIC realHelper=true status=\(event.summary.status) nonzeroExitRecorded=true stdoutExcluded=true secretExcluded=true originalCanaryPreserved=true noImageCreated=true")
    }
}

private final class CredentialDiagnosticProbe:@unchecked Sendable {
    private let lock=NSLock()
    private var captured=[VaultNativeDiagnostic](),actions=[VaultNativeOperation](),closed=[(VaultCredentialHelper,Int32)](),validationCount=0,queryCount=0
    func append(_ event:VaultNativeDiagnostic) {lock.lock();captured.append(event);lock.unlock()}
    func mutation(_ action:VaultNativeOperation) {lock.lock();actions.append(action);lock.unlock()}
    func helper(_ helper:VaultCredentialHelper,_ pid:Int32) {lock.lock();closed.append((helper,pid));lock.unlock()}
    func countValidation() {lock.lock();validationCount+=1;lock.unlock()}
    func countQuery() {lock.lock();queryCount+=1;lock.unlock()}
    func counts()->(validation:Int,query:Int) {lock.lock();defer {lock.unlock()};return(validationCount,queryCount)}
    func events()->[VaultNativeDiagnostic] {lock.lock();defer {lock.unlock()};return captured}
    func mutations()->[VaultNativeOperation] {lock.lock();defer {lock.unlock()};return actions}
    func helpers()->[(VaultCredentialHelper,Int32)] {lock.lock();defer {lock.unlock()};return closed}
}
