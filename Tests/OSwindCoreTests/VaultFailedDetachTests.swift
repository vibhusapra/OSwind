import XCTest
import Darwin
@testable import OSwindCore

func ownedVaultProof(mounted:Bool=true)->VaultVolumeProof {
    var image=stat();image.st_dev=41;image.st_ino=101
    var root=stat();root.st_dev=42;root.st_ino=102
    return .init(mount:URL(fileURLWithPath:"/owned/mount"),device:"/dev/disk900s1",volumeUUID:"owned-volume",root:mounted ? BackupFileStamp(root):nil,image:BackupFileStamp(image),attachmentDevice:"/dev/disk899",reportedImagePath:"/owned/image")
}

final class VaultFailedDetachTests:XCTestCase {
    final class Identity:@unchecked Sendable {
        private let lock=NSLock();private var count=0
        let failAt:Int?
        init(failAt:Int?=nil) {self.failAt=failAt}
        var calls:Int {lock.withLock {count}}
        func validate()throws {try lock.withLock {count+=1;if count==failAt {throw OSwindError.invalid("owned identity changed")}}}
    }
    func proof(mounted:Bool=true)->VaultVolumeProof {ownedVaultProof(mounted:mounted)}

    func testAbsentObservationValidatesBeforeAndAfterButIsNotALockVerdict() async throws {
        let identity=Identity(),p=proof()
        let current=try await VaultDetachSettlement.inspectAfterFailure(expected:p,validate:{try identity.validate()},inspect:{nil})
        XCTAssertNil(current);XCTAssertEqual(identity.calls,2)
    }
    func testSameMountedAndUnmountedIdentitiesRemainAvailableForCallerDecision() async throws {
        for mounted in [true,false] {
            let p=proof(),next=proof(mounted:mounted)
            let result=try await VaultDetachSettlement.inspectAfterFailure(expected:p,validate:{},inspect:{next})
            XCTAssertEqual(result?.mounted,mounted)
        }
    }
    func testChangedDeviceImageVolumeMountAndRootRefuse() async throws {
        let p=proof();var values=[VaultVolumeProof]()
        var v=p;v.device="/dev/disk901s1";values.append(v)
        v=p;v.attachmentDevice="/dev/disk898";values.append(v)
        v=p;v.volumeUUID="other";values.append(v)
        v=p;v.image.inode+=1;values.append(v)
        v=p;v.image.device+=1;values.append(v)
        v=p;v.mount=URL(fileURLWithPath:"/other/mount");values.append(v)
        v=p;v.root?.inode+=1;values.append(v)
        v=p;v.root?.device+=1;values.append(v)
        for value in values {
            do {_ = try await VaultDetachSettlement.inspectAfterFailure(expected:p,validate:{},inspect:{value});XCTFail("Changed attachment admitted")} catch {}
        }
    }
    func testIdentityChangeBeforeInspectionStopsIPC() async throws {
        let identity=Identity(failAt:1),p=proof()
        do {_ = try await VaultDetachSettlement.inspectAfterFailure(expected:p,validate:{try identity.validate()},inspect:{XCTFail("Inspection started after identity change");return nil});XCTFail("Changed identity accepted")} catch {}
        XCTAssertEqual(identity.calls,1)
    }
    func testIdentityChangeAcrossInspectionRefusesEvenAnAbsentResult() async throws {
        let identity=Identity(failAt:2),p=proof()
        do {_ = try await VaultDetachSettlement.inspectAfterFailure(expected:p,validate:{try identity.validate()},inspect:{nil});XCTFail("Stale absence accepted")} catch {}
        XCTAssertEqual(identity.calls,2)
    }
    func testUnknownInspectionAndPendingVolumeAreNotConvertedToAbsence() async throws {
        let p=proof()
        for pending in [true,false] {
            do {_ = try await VaultDetachSettlement.inspectAfterFailure(expected:p,validate:{},inspect:{
                if pending {throw VaultAttachmentObservationError.unmountedVolumePending}
                throw OSwindError.unavailable("owned inventory unavailable")
            });XCTFail("Unknown attachment state accepted")} catch {}
        }
    }
    func testCancellationAfterInspectionCannotAdmitItsResult() async throws {
        let p=proof(),task=Task {
            try await VaultDetachSettlement.inspectAfterFailure(expected:p,validate:{},inspect:{withUnsafeCurrentTask {$0?.cancel()};return nil})
        }
        do {_ = try await task.value;XCTFail("Cancelled absence accepted")} catch is CancellationError {} catch {throw error}
    }
    func testOneAbsentFailureObservationStillNeedsTwoFreshAbsentConfirmations() async throws {
        let p=proof();_ = try await VaultDetachSettlement.inspectAfterFailure(expected:p,validate:{},inspect:{nil})
        actor Observations {var count=0;func inspect()->Bool {count+=1;return count>1}}
        let observations=Observations()
        do {try await VaultDetachSettlement.confirm(attempts:2,pause:{_ in},inspect:{await observations.inspect()});XCTFail("One fresh absence reported locked")} catch {}
    }
}
