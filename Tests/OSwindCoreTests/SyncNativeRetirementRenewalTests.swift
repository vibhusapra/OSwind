import XCTest
import CSQLite
@testable import OSwindCore

extension SyncNativeWriterAdmissionTests {
    func testLocalRenewalRequiresPhysicalCompletionAndPreservesUnapprovedGroupReview()throws {
        let file=try stagedCleanup(),accounts=storage.values
        XCTAssertThrowsError(try service!.completeLocalRetirement(pairing:pairing!))
        XCTAssertEqual(storage.values,accounts);XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        XCTAssertTrue(try service!.cleanupRetirement().cleanupComplete)
        let control=try service!.completeLocalRetirement(pairing:pairing!)
        XCTAssertEqual(control.counter,1);XCTAssertEqual(Set(storage.values.keys),Set(accounts.keys));XCTAssertNotEqual(storage.values,accounts)
        XCTAssertEqual(try library.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM personal_sync_collection_approvals")},0)
        try library.insert(Memory(id:"new-lifetime",text:"New local history after exact cleanup"));XCTAssertNotNil(try library.get("new-lifetime"))
        try stop();try library.close();library=try reopen()
        let owner=try PersonalSyncPairing(store:library,stateRoot:environment.stateRoot,machine:machine,storage:storage);pairing=owner
        XCTAssertEqual(try owner.status().phase,.owner)
        service=try owner.prepareAnchoredService(shared:root.appendingPathComponent("shared"),createShared:false)
        guard case .needsGroupReview(let review)=try service!.tick() else {return XCTFail("Renewal must still require explicit group erase review")}
        XCTAssertEqual(review,control);XCTAssertEqual(try library.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM personal_sync_collection_approvals")},0)
    }
    func testCrashRecoveryCanCleanAndRenewUsingOriginalAccounts()throws {
        _=try stagedCleanup();let keys=Set(storage.values.keys)
        try stop();try library.close()
        let owner=try SyncRetirementCleanupOwner.open(root:library.root,environment:environment);defer {try? owner.close()}
        XCTAssertThrowsError(try owner.completeLocalRetirement())
        XCTAssertTrue(try owner.cleanup().cleanupComplete)
        XCTAssertEqual(try owner.completeLocalRetirement().counter,1)
        try owner.close();library=try reopen()
        XCTAssertEqual(Set(storage.values.keys),keys)
        try library.insert(Memory(id:"recovered-active",text:"Recovered active authority"));XCTAssertNotNil(try library.get("recovered-active"))
    }
    func testFailedFirstExternalRenewalSaveCanOnlyRetryThroughAReopenedOwner()throws {
        _=try stagedCleanup();XCTAssertTrue(try service!.cleanupRetirement().cleanupComplete)
        let accounts=storage.values;storage.failReplacement=true
        XCTAssertThrowsError(try service!.completeLocalRetirement(pairing:pairing!));storage.failReplacement=false
        XCTAssertEqual(storage.values,accounts);XCTAssertThrowsError(try library.insert(Memory(id:"failed-renewal",text:"No regrant")))
        try stop();try library.close()
        let owner=try SyncRetirementCleanupOwner.open(root:library.root,environment:environment);defer {try? owner.close()}
        XCTAssertEqual(try owner.completeLocalRetirement().counter,1);try owner.close()
        library=try reopen();XCTAssertNil(try library.get("failed-renewal"))
    }
    func testPartialPairingAdvancementCannotBeSilentlyReboundAfterDeliverySaveFailure()throws {
        _=try stagedCleanup();XCTAssertTrue(try service!.cleanupRetirement().cleanupComplete)
        let accounts=storage.values
        storage.afterReplacement={self.storage.failReplacement=true}
        XCTAssertThrowsError(try service!.completeLocalRetirement(pairing:pairing!))
        storage.afterReplacement=nil;storage.failReplacement=false
        let advanced=storage.values;XCTAssertNotEqual(advanced,accounts);XCTAssertEqual(Set(advanced.keys),Set(accounts.keys))
        try stop();try library.close();XCTAssertThrowsError(try reopen())
        let owner=try SyncRetirementCleanupOwner.open(root:library.root,environment:environment);defer {try? owner.close()}
        XCTAssertThrowsError(try owner.completeLocalRetirement(),"The saved original pairing lifetime must detect partial external advancement")
        XCTAssertEqual(storage.values,advanced)
        _=try LibraryRecovery.createBackup(from:library.root,destination:root.appendingPathComponent("partial-renewal-recovery.oswindbackup"))
    }
    func testFailedNativeCommitAfterBothExternalRenewalsRequiresRecovery()throws {
        _=try stagedCleanup();XCTAssertTrue(try service!.cleanupRetirement().cleanupComplete)
        let handle=try library.withRetirementDatabase {$0.handle},gate=RenewalCommitGate()
        var replacements=0
        storage.afterReplacement={
            replacements+=1
            if replacements==2 {
                _=sqlite3_set_authorizer(handle,{context,action,first,_,_,_ in
                    guard action==SQLITE_TRANSACTION,let first,String(cString:first)=="COMMIT",let context else {return SQLITE_OK}
                    return Unmanaged<RenewalCommitGate>.fromOpaque(context).takeUnretainedValue().denyOnce() ? SQLITE_DENY:SQLITE_OK
                },Unmanaged.passUnretained(gate).toOpaque())
            }
        }
        XCTAssertThrowsError(try service!.completeLocalRetirement(pairing:pairing!))
        storage.afterReplacement=nil;sqlite3_set_authorizer(handle,nil,nil)
        XCTAssertTrue(gate.denied);XCTAssertEqual(replacements,2)
        try stop();try library.close();XCTAssertThrowsError(try reopen())
        XCTAssertThrowsError(try SyncRetirementCleanupOwner.open(root:library.root,environment:environment))
        XCTAssertEqual(try LibraryRecovery.createBackup(from:library.root,destination:root.appendingPathComponent("failed-commit-recovery.oswindbackup")).memories,0)
    }
    func testOrdinaryWholeEraseCannotBypassTheCheckpointOwnerButIndividualDeletionWorks()throws {
        try prepare();try service!.installNativeWriterAdmission();try ready()
        let accounts=storage.values
        XCTAssertThrowsError(try library.wipeLibrary());XCTAssertThrowsError(try library.deleteAll())
        XCTAssertThrowsError(try library.withRoutineDatabase {try $0.execute("INSERT INTO store_metadata(key,value) VALUES('library_wipe_dirty','1')")})
        XCTAssertEqual(storage.values,accounts);XCTAssertNotNil(try library.get("owned"))
        XCTAssertEqual(try library.withRoutineDatabase {try $0.eraseCount("SELECT counter FROM personal_sync_collection_local")},0)
        XCTAssertEqual(try library.delete("owned").sources,1);XCTAssertNil(try library.get("owned"))
    }
}

private final class RenewalCommitGate:@unchecked Sendable {
    private let lock=NSLock();private var used=false
    var denied:Bool {lock.lock();defer {lock.unlock()};return used}
    func denyOnce()->Bool {lock.lock();defer {lock.unlock()};guard !used else {return false};used=true;return true}
}
