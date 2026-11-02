import XCTest
import CSQLite
@testable import OSwindCore

extension SyncNativeWriterAdmissionTests {
    func stagedCleanup()throws->URL {
        let file=library.root.appendingPathComponent("images/cleanup-owned.jpg")
        try Data("Owned physical cleanup bytes".utf8).write(to:file)
        try library.insert(Memory(id:"owned",text:"Owned cleanup source",imagePath:"images/cleanup-owned.jpg"))
        try prepare();try service!.installNativeWriterAdmission();try ready();_=try service!.stageLocalRetirement()
        return file
    }
    func testOwnedPhysicalCleanupRemovesQueuedMediaWithoutGrantingNormalWrites()throws {
        let file=try stagedCleanup(),accounts=storage.values
        let result=try service!.cleanupRetirement()
        XCTAssertTrue(result.cleanupComplete,result.erasure.warnings.joined(separator:"; "));XCTAssertTrue(result.compacted)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path));XCTAssertEqual(storage.values,accounts,"Physical cleanup does not rewrite or renew authority")
        XCTAssertThrowsError(try library.insert(Memory(id:"not-renewed",text:"Cleanup alone cannot grant capture")))
        XCTAssertThrowsError(try reopen());try stop()
    }
    func testRetirementRecoveryReopensExactAuthorityAndExcludesASecondOwner()throws {
        let file=try stagedCleanup(),accounts=storage.values
        try stop();try library.close()
        let owner=try SyncRetirementCleanupOwner.open(root:library.root,environment:environment);defer {try? owner.close()}
        XCTAssertThrowsError(try SyncRetirementCleanupOwner.open(root:library.root,environment:environment))
        let result=try owner.cleanup();XCTAssertTrue(result.cleanupComplete,result.erasure.warnings.joined(separator:"; "))
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path));XCTAssertEqual(storage.values,accounts)
        XCTAssertThrowsError(try reopen());try owner.close()
    }
    func testCanceledPhysicalCleanupKeepsPendingPathsForAJoinedRetry()async throws {
        let file=try stagedCleanup()
        let entered=expectation(description:"Cleanup reader is owned"),release=DispatchSemaphore(value:0),active=service!
        defer {release.signal()}
        let worker=Task.detached {
            try active.cleanupRetirement(progress:{event in if event.phase=="Retrying retained-media cleanup" {entered.fulfill();release.wait()}})
        }
        await fulfillment(of:[entered],timeout:10);worker.cancel();release.signal()
        let cancelled=try await worker.value
        XCTAssertTrue(cancelled.cancelled);XCTAssertFalse(cancelled.cleanupComplete);XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        XCTAssertThrowsError(try reopen())
        let retry=try service!.cleanupRetirement();XCTAssertTrue(retry.cleanupComplete,retry.erasure.warnings.joined(separator:"; "))
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path));try stop()
    }
    func testMissingRetirementCredentialCannotCreateAnUnverifiedCleanupOwner()throws {
        let file=try stagedCleanup(),id=try deliveryID()
        try stop();try library.close();storage.forget(id)
        let accounts=storage.values,db=library.root.appendingPathComponent("memory.sqlite"),before=try Data(contentsOf:db)
        XCTAssertThrowsError(try SyncRetirementCleanupOwner.open(root:library.root,environment:environment))
        XCTAssertEqual(try Data(contentsOf:db),before);XCTAssertEqual(storage.values,accounts);XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
    }
    func testRetirementCleanupWaitsForActualWALReadersBeforeClaimingComplete()throws {
        let file=try stagedCleanup()
        var db:OpaquePointer?,row:OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(library.root.appendingPathComponent("memory.sqlite").path,&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX,nil),SQLITE_OK)
        defer {sqlite3_finalize(row);sqlite3_close(db)}
        XCTAssertEqual(sqlite3_prepare_v2(db,"SELECT value FROM store_metadata WHERE key='identity'",-1,&row,nil),SQLITE_OK)
        XCTAssertEqual(sqlite3_step(row),SQLITE_ROW)
        let blocked=try service!.cleanupRetirement()
        XCTAssertFalse(blocked.cleanupComplete);XCTAssertFalse(blocked.compacted)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path));XCTAssertThrowsError(try reopen())
        sqlite3_finalize(row);row=nil;sqlite3_close(db);db=nil
        let retried=try service!.cleanupRetirement()
        XCTAssertTrue(retried.cleanupComplete,retried.erasure.warnings.joined(separator:"; "));XCTAssertTrue(retried.compacted)
        try stop()
    }
    func testChangedMediaQueueProtectionRefusesBeforePhysicalCleanup()throws {
        let file=try stagedCleanup()
        try library.withRetirementDatabase {try $0.execute("DROP TRIGGER erasure_assets_delete_v33")}
        XCTAssertThrowsError(try service!.cleanupRetirement());XCTAssertTrue(FileManager.default.fileExists(atPath:file.path));try stop()
    }
    func testCopiedRetirementCannotOpenWithTheOriginalExternalAuthority()throws {
        let file=try stagedCleanup(),copy=root.appendingPathComponent("copied-retirement")
        try stop();try library.close()
        try FileManager.default.copyItem(at:library.root,to:copy)
        let db=copy.appendingPathComponent("memory.sqlite"),before=try Data(contentsOf:db)
        XCTAssertThrowsError(try SyncRetirementCleanupOwner.open(root:copy,environment:environment))
        XCTAssertEqual(try Data(contentsOf:db),before);XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
    }
}
