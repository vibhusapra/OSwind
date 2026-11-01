import XCTest
@testable import OSwindCore

final class VaultEjectTransitionTests:XCTestCase {
    actor Scenario {
        var observations:[VaultVolumeProof?],detachResults:[Int32],unmountResults:[Int32]
        var devices=[String](),mounts=[URL](),inspectionCount=0
        var terminations:[VaultProcessTermination]=[]
        func setTerminations(_ values:[VaultProcessTermination]) {terminations=values}
        init(_ observations:[VaultVolumeProof?],detach:[Int32],unmount:[Int32]=[]) {self.observations=observations;detachResults=detach;unmountResults=unmount}
        func inspect()throws->VaultVolumeProof? {
            inspectionCount+=1;guard !observations.isEmpty else {XCTFail("Unexpected extra inspection");throw OSwindError.invalid("fixture exhausted")};return observations.removeFirst()
        }
        func detach(_ device:String)->VaultProcessResult {
            devices.append(device);guard !detachResults.isEmpty else {XCTFail("Unexpected extra detach");return .init(status:99,stdout:Data(),stderr:Data())}
            return .init(status:detachResults.removeFirst(),stdout:Data(),stderr:Data(),termination:terminations.isEmpty ? .exit:terminations.removeFirst())
        }
        func unmount(_ mount:URL)->VaultProcessResult {
            mounts.append(mount);guard !unmountResults.isEmpty else {XCTFail("Unexpected extra unmount");return .init(status:99,stdout:Data(),stderr:Data())}
            return .init(status:unmountResults.removeFirst(),stdout:Data(),stderr:Data())
        }
    }
    func proof(mounted:Bool=true)->VaultVolumeProof {ownedVaultProof(mounted:mounted)}
    func run(_ scenario:Scenario,moved:Bool=false,busyRetries:Int=2,busyPause:@escaping @Sendable (Int) async throws ->Void={_ in},validate:@escaping @Sendable () throws ->Void={}) async throws {
        let verified=proof()
        try await VaultEjectTransition.run(verified:verified,expectedImage:{URL(fileURLWithPath:moved ? "/owned/new-image":"/owned/image")},validate:validate,
            observe:{try await scenario.inspect()},detach:{device,_ in await scenario.detach(device)},unmount:{mount,_ in await scenario.unmount(mount)},attempts:2,busyRetries:busyRetries,busyPause:busyPause,pause:{_ in})
    }
    func counts(_ s:Scenario,detach:Int,unmount:Int,inspect:Int) async {
        let devices=await s.devices,mounts=await s.mounts,count=await s.inspectionCount
        XCTAssertEqual(devices,Array(repeating:proof().attachmentDevice,count:detach));XCTAssertEqual(mounts,Array(repeating:proof().mount,count:unmount));XCTAssertEqual(count,inspect)
    }
    func testSuccessfulDetachRequiresTwoFreshAbsentObservations() async throws {
        let s=Scenario([nil,nil],detach:[0]);try await run(s);await counts(s,detach:1,unmount:0,inspect:2)
    }
    func testNonzeroDetachCanFinishOnlyAfterIndependentAbsenceConfirmation() async throws {
        let s=Scenario([nil,nil,nil],detach:[6]);try await run(s);await counts(s,detach:1,unmount:0,inspect:3)
    }
    func testOtherNonzeroDetachWithStillMountedImageDoesNotRetryOrUnmount() async throws {
        let s=Scenario([proof()],detach:[6])
        do {try await run(s);XCTFail("Mounted image reported locked")} catch let e as VaultNativeFailure {XCTAssertEqual(e.summary.status,6);XCTAssertEqual(e.summary.operation,.imageDetach)}
        await counts(s,detach:1,unmount:0,inspect:1)
    }
    func testOneAbsenceAfterFailureCannotReportLocked() async throws {
        let s=Scenario([nil,nil,proof()],detach:[6])
        do {try await run(s);XCTFail("Single confirmed absence reported locked")} catch {}
        await counts(s,detach:1,unmount:0,inspect:3)
    }
    func testSuccessfulExitWithAttachedImageCannotReportLocked() async throws {
        let s=Scenario([proof(),proof()],detach:[0])
        do {try await run(s);XCTFail("Exit status substituted for attachment state")} catch {}
        await counts(s,detach:1,unmount:0,inspect:2)
    }
    func testExplicitBusyRecoversThroughFreshNormalDetachAndConfirmedAbsence()async throws {
        let s=Scenario([proof(),proof(),nil,nil],detach:[16,0])
        do {try await run(s)}catch {XCTFail("Explicit owned busy did not recover: \(error)")}
        await counts(s,detach:2,unmount:0,inspect:4)
    }
    func testExplicitBusyRetriesAreBoundedWhenAReaderRemains()async throws {
        let s=Scenario(Array(repeating:proof(),count:5),detach:[16,16,16])
        do {try await run(s);XCTFail("Busy image reported locked")}catch let e as VaultNativeFailure {XCTAssertEqual(e.summary.status,16)}
        await counts(s,detach:3,unmount:0,inspect:5)
    }
    func testChangedProofBeforeBusyRetryNeverReceivesAnotherMutation()async throws {
        var foreign=proof();foreign.image.inode+=1
        let s=Scenario([proof(),foreign],detach:[16])
        do {try await run(s);XCTFail("Changed image admitted to retry")}catch {}
        await counts(s,detach:1,unmount:0,inspect:2)
    }
    func testBusyImageDisappearingDuringBackoffNeedsFreshAbsenceConfirmation()async throws {
        let s=Scenario([proof(),nil,nil,nil],detach:[16])
        do {try await run(s)}catch {XCTFail("Independently absent image did not confirm: \(error)")}
        await counts(s,detach:1,unmount:0,inspect:4)
    }
    func testBusyRecoveryCanBeDisabledWithoutChangingFailureConfirmation()async throws {
        let s=Scenario([proof()],detach:[16])
        do {try await run(s,busyRetries:0);XCTFail("Disabled retry mutated again")}catch let e as VaultNativeFailure {XCTAssertEqual(e.summary.status,16)}
        await counts(s,detach:1,unmount:0,inspect:1)
    }
    func testInvalidBusyBudgetsNeverStartNativeMutation()async throws {
        for budget in [-1,3,Int.max] {
            let s=Scenario([],detach:[])
            do {try await run(s,busyRetries:budget);XCTFail("Invalid budget admitted")}catch {}
            await counts(s,detach:0,unmount:0,inspect:0)
        }
    }
    func testSignalAndUnknownStatus16DoNotReceiveBusyRetries()async throws {
        for termination:VaultProcessTermination in [.signal,.unknown] {
            let s=Scenario([proof()],detach:[16]);await s.setTerminations([termination])
            do {try await run(s);XCTFail("Non-exit retried")}catch let e as VaultNativeFailure {XCTAssertEqual(e.summary.termination,termination)}
            await counts(s,detach:1,unmount:0,inspect:1)
        }
    }
    func testOtherFailureAfterBusyRetryStopsFurtherMutations()async throws {
        let s=Scenario([proof(),proof(),proof()],detach:[16,6])
        do {try await run(s);XCTFail("Other failure reported locked")}catch let e as VaultNativeFailure {XCTAssertEqual(e.summary.status,6)}
        await counts(s,detach:2,unmount:0,inspect:3)
    }
    func testBusyRetryFailureStillNeedsTwoFreshAbsences()async throws {
        let s=Scenario([proof(),proof(),nil,nil,proof()],detach:[16,6])
        do {try await run(s);XCTFail("Single absence reported locked")}catch {}
        await counts(s,detach:2,unmount:0,inspect:5)
    }
    func testUnmountedImageBeforeBusyRetryIsPreserved()async throws {
        let s=Scenario([proof(),proof(mounted:false)],detach:[16])
        do {try await run(s);XCTFail("Unmounted image blindly retried")}catch {}
        await counts(s,detach:1,unmount:0,inspect:2)
    }
    func testCancellationDuringNoncooperativeBusyPauseStopsBeforeInspectionAndMutation()async throws {
        let s=Scenario([proof()],detach:[16])
        let task=Task {
            try await self.run(s,busyPause:{_ in withUnsafeCurrentTask {$0?.cancel()}})
        }
        do {try await task.value;XCTFail("Cancelled retry continued")}catch is CancellationError {}catch {throw error}
        await counts(s,detach:1,unmount:0,inspect:1)
    }
    func testPackageReplacementDuringBusyPauseStopsBeforeInspectionAndMutation()async throws {
        final class Identity:@unchecked Sendable {
            let lock=NSLock();var valid=true
            func replace() {lock.withLock {valid=false}}
            func validate()throws {try lock.withLock {if !valid {throw OSwindError.invalid("Owned package replaced")}}}
        }
        let identity=Identity(),s=Scenario([proof()],detach:[16])
        do {try await run(s,busyPause:{_ in identity.replace()},validate:{try identity.validate()});XCTFail("Replaced package admitted")}catch {}
        await counts(s,detach:1,unmount:0,inspect:1)
    }
    func testOneRetryBudgetCannotStartThirdDetach()async throws {
        let s=Scenario([proof(),proof(),proof()],detach:[16,16])
        do {try await run(s,busyRetries:1);XCTFail("Busy image reported locked")}catch let e as VaultNativeFailure {XCTAssertEqual(e.summary.status,16)}
        await counts(s,detach:2,unmount:0,inspect:3)
    }
    func testUnknownObservationAfterBusyPauseStopsBeforeAnotherMutation()async throws {
        let s=Scenario([proof()],detach:[16]),p=proof()
        actor Reads {
            var count=0
            func inspect(_ p:VaultVolumeProof)throws->VaultVolumeProof? {count+=1;if count==1 {return p};throw OSwindError.invalid("Unknown owned inventory")}
        }
        let reads=Reads()
        do {
            try await VaultEjectTransition.run(verified:p,expectedImage:{URL(fileURLWithPath:"/owned/image")},validate:{},observe:{try await reads.inspect(p)},detach:{d,_ in await s.detach(d)},unmount:{m,_ in await s.unmount(m)},busyPause:{_ in},pause:{_ in})
            XCTFail("Unknown inventory admitted")
        }catch {}
        let devices=await s.devices,count=await reads.count
        XCTAssertEqual(devices,[p.attachmentDevice]);XCTAssertEqual(count,2)
    }
    func testMovedPathUsesOnlyNormalUnmountThenVerifiedBackingDevice() async throws {
        let s=Scenario([proof(),proof(mounted:false),nil,nil],detach:[16,0],unmount:[0])
        try await run(s,moved:true);await counts(s,detach:2,unmount:1,inspect:4)
    }
    func testFailedMovedUnmountWithAlreadyAbsentImageNeedsConfirmation() async throws {
        let s=Scenario([proof(),nil,nil,nil],detach:[16],unmount:[6])
        try await run(s,moved:true);await counts(s,detach:1,unmount:1,inspect:4)
    }
    func testFailedMovedUnmountStillAttachedDoesNotContinueMutating() async throws {
        let s=Scenario([proof(),proof()],detach:[16],unmount:[16])
        do {try await run(s,moved:true);XCTFail("Failed unmount reported locked")} catch let e as VaultNativeFailure {XCTAssertEqual(e.summary.operation,.filesystemUnmount)}
        await counts(s,detach:1,unmount:1,inspect:2)
    }
    func testSuccessfulUnmountWithAlreadyAbsentImageNeedsConfirmation() async throws {
        let s=Scenario([proof(),nil,nil,nil],detach:[16],unmount:[0])
        try await run(s,moved:true);await counts(s,detach:1,unmount:1,inspect:4)
    }
    func testFinalDetachNonzeroButAbsentStillNeedsTwoFreshAbsences() async throws {
        let s=Scenario([proof(),proof(mounted:false),nil,nil,nil],detach:[16,6],unmount:[0])
        try await run(s,moved:true);await counts(s,detach:2,unmount:1,inspect:5)
    }
    func testFinalDetachFailureWithRemainingUnmountedImageStaysUnconfirmed() async throws {
        let s=Scenario([proof(),proof(mounted:false),proof(mounted:false)],detach:[16,6],unmount:[0])
        do {try await run(s,moved:true);XCTFail("Remaining encrypted device reported locked")} catch let e as VaultNativeFailure {XCTAssertEqual(e.summary.status,6)}
        await counts(s,detach:2,unmount:1,inspect:3)
    }
    func testChangedImageAfterUnmountNeverReceivesSecondDetach() async throws {
        var changed=proof(mounted:false);changed.volumeUUID="foreign"
        let s=Scenario([proof(),changed],detach:[16],unmount:[0])
        do {try await run(s,moved:true);XCTFail("Foreign device admitted")} catch {}
        await counts(s,detach:1,unmount:1,inspect:2)
    }
    func testInvalidIdentityStopsBeforeAnyNativeMutation() async throws {
        let s=Scenario([],detach:[])
        do {try await run(s,validate:{throw OSwindError.invalid("owned identity changed")});XCTFail("Invalid identity admitted")} catch {}
        await counts(s,detach:0,unmount:0,inspect:0)
    }
    func testAlreadyCancelledTransitionDoesNotStartNativeMutation() async throws {
        let s=Scenario([],detach:[]),p=proof()
        let task=Task {
            withUnsafeCurrentTask {$0?.cancel()}
            try await VaultEjectTransition.run(verified:p,expectedImage:{URL(fileURLWithPath:"/owned/image")},validate:{},observe:{try await s.inspect()},detach:{device,_ in await s.detach(device)},unmount:{mount,_ in await s.unmount(mount)},pause:{_ in})
        }
        do {try await task.value;XCTFail("Cancelled transition succeeded")} catch is CancellationError {} catch {throw error}
        await counts(s,detach:0,unmount:0,inspect:0)
    }
    func testCancellationAfterNativeMutationDoesNotSkipConfirmationIntoSuccess() async throws {
        let s=Scenario([],detach:[0]),p=proof()
        let task=Task {
            try await VaultEjectTransition.run(verified:p,expectedImage:{URL(fileURLWithPath:"/owned/image")},validate:{},observe:{try await s.inspect()},detach:{device,_ in
                let result=await s.detach(device);withUnsafeCurrentTask {$0?.cancel()};return result
            },unmount:{mount,_ in await s.unmount(mount)},pause:{_ in})
        }
        do {try await task.value;XCTFail("Cancelled mutation reported locked")} catch is CancellationError {} catch {throw error}
        await counts(s,detach:1,unmount:0,inspect:0)
    }
}
