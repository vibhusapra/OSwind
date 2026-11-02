import XCTest
@testable import OSwindCore

extension SyncNativeReceivedRetirementTests {
    func publicSessionA()throws->PersonalSyncSession {
        try sa.stop();sa.inbox.close();sa.transport.close()
        return try pa.prepareSession(sharedFolder:root.appendingPathComponent("shared"))
    }
    func publicSessionB()throws->PersonalSyncSession {
        try sb.stop();sb.inbox.close();sb.transport.close()
        return try pb.prepareSession(sharedFolder:root.appendingPathComponent("shared"))
    }
    func testPublicFolderFactoryStartsPausedSavesLocationAndReopensOriginalAccounts()async throws {
        let accounts=Set(storage.values.keys),connection=try publicSessionA()
        do {
            XCTAssertTrue(connection.ownsHistoryRetirement)
            let initial=await connection.status();XCTAssertEqual(initial.phase,.ready)
            XCTAssertEqual(try pa.savedSessionFolder()?.resolvingSymlinksInPath(),root.appendingPathComponent("shared").resolvingSymlinksInPath())
            try await connection.setNetworkEnabled(false);try await connection.setProcessingEnabled(true)
            try await wait(connection,phase:.networkPaused)
            try await connection.stop()
        }catch {try? await connection.stop();throw error}
        pa=try pairing(a)
        let resumed=try pa.prepareSavedSession()
        do {
            let initial=await resumed.status();XCTAssertEqual(initial.phase,.ready)
            try await resumed.setProcessingEnabled(true);try await wait(resumed,phase:.upToDate)
            XCTAssertEqual(Set(storage.values.keys),accounts)
            XCTAssertEqual(try a.stats(includeDiskUsage:false).count,2)
            try await resumed.stop()
        }catch {try? await resumed.stop();throw error}
    }
    func testPublicReviewedEraseIsSessionBoundAndCannotResumeDeliveryWithoutExplicitConfiguration()async throws {
        _=try sa.stageLocalRetirement();XCTAssertTrue(try sa.cleanupRetirement().cleanupComplete)
        _=try sa.completeLocalRetirement(pairing:pa);try reopenA()
        let sender=try publicSessionA(),receiver=try publicSessionB()
        do {
            try await sender.setProcessingEnabled(true);try await wait(sender,phase:.needsLocalEraseReview)
            try await receiver.setProcessingEnabled(true);try await wait(receiver,phase:.upToDate)
            let pending=try await sender.localEraseReview(),review=try XCTUnwrap(pending)
            XCTAssertEqual(Set(review.deviceNames),Set(["Owned sender","Owned receiver"]))
            do {try await receiver.approveLocalErase(review);XCTFail("A different session cannot approve this local intent")}catch {}
            try await sender.approveLocalErase(review)
            let suspended=await sender.status();XCTAssertEqual(suspended.phase,.suspended)
            do {try await sender.approveLocalErase(review);XCTFail("An already resolved review cannot be reused")}catch {}
            try await Task.sleep(for:.milliseconds(50))
            let stillLocal=await receiver.status();XCTAssertEqual(stillLocal.phase,.upToDate)
            try await sender.setProcessingEnabled(true);try await wait(sender,phase:.upToDate)
            try await receiver.setNetworkEnabled(false);try await receiver.setNetworkEnabled(true)
            try await wait(receiver,phase:.needsReceivedErase)
            let erased=try await receiver.applyReceivedErase();XCTAssertTrue(erased.cleanupComplete);XCTAssertEqual(erased.erasure.sources,2)
            try await sender.stop();try await receiver.stop()
        }catch {try? await sender.stop();try? await receiver.stop();throw error}
        try reopenB();XCTAssertEqual(try b.stats(includeDiskUsage:false).count,0)
    }
    func testSavedFolderCannotActivatePortableRestoredHistory()async throws {
        let connection=try publicSessionA();try await connection.stop()
        let backup=root.appendingPathComponent("folder-session.oswindbackup"),restored=root.appendingPathComponent("portable")
        _=try LibraryBackup.create(store:a,destination:backup)
        _=try LibraryBackup.restore(backup,to:restored)
        let local=try MemoryStore(root:restored);defer {try? local.close()}
        XCTAssertEqual(try count(local,"store_metadata WHERE key='sync-session-folder-bookmark-v1'"),0)
        let ordinary=try PersonalSyncPairing(store:local);defer {ordinary.close()}
        XCTAssertEqual(try ordinary.status().phase,.unconfigured)
        XCTAssertThrowsError(try ordinary.prepareSavedSession())
        XCTAssertEqual(try local.stats(includeDiskUsage:false).count,2)
    }
    func testInvalidSavedBookmarkRefusesWithoutChangingCredentialsOrNativeContent()async throws {
        let connection=try publicSessionA();try await connection.stop();pa=try pairing(a)
        let accounts=storage.values
        try a.withRoutineDatabase {db in try db.execute("UPDATE store_metadata SET value='invalid owned bookmark' WHERE key='sync-session-folder-bookmark-v1'")}
        XCTAssertThrowsError(try pa.savedSessionFolder());XCTAssertThrowsError(try pa.prepareSavedSession())
        XCTAssertEqual(storage.values,accounts);XCTAssertEqual(try a.stats(includeDiskUsage:false).count,2)
        let replacement=try pa.prepareSession(sharedFolder:root.appendingPathComponent("shared"))
        try await replacement.stop()
    }
    func testSamePendingEraseRequiresANewReviewAfterSessionReopen()async throws {
        _=try sa.stageLocalRetirement();XCTAssertTrue(try sa.cleanupRetirement().cleanupComplete)
        _=try sa.completeLocalRetirement(pairing:pa);try reopenA()
        let first=try publicSessionA()
        try await first.setProcessingEnabled(true);try await wait(first,phase:.needsLocalEraseReview)
        let pending=try await first.localEraseReview(),old=try XCTUnwrap(pending)
        try await first.stop();pa=try pairing(a)
        let fresh=try pa.prepareSavedSession()
        do {
            try await fresh.setProcessingEnabled(true);try await wait(fresh,phase:.needsLocalEraseReview)
            do {try await fresh.approveLocalErase(old);XCTFail("A reopened session needs its own explicit review")}catch {}
            let pending=try await fresh.localEraseReview(),current=try XCTUnwrap(pending)
            XCTAssertNotEqual(current,old)
            try await fresh.approveLocalErase(current)
            let status=await fresh.status();XCTAssertEqual(status.phase,.suspended)
            try await fresh.stop()
        }catch {try? await fresh.stop();throw error}
    }
    func testRestrictedAsyncRecoveryJoinsCancelledCleanupAndRenewsOnExplicitRetry()async throws {
        let orphan=a.root.appendingPathComponent("audio/public-recovery-orphan");try Data("Owned recovery orphan".utf8).write(to:orphan)
        _=try sa.stageLocalRetirement();try sa.stop();sa.inbox.close();sa.transport.close();pa.close();try a.close()
        let location=a.root,environment=environment,gate=SyncSessionEraseGate(),finished=SyncSessionStopProbe()
        defer {gate.release()}
        let retry=Task {
            defer {finished.mark()}
            return try await PersonalSyncRetirementRecovery.retry(root:location,environment:environment,progress:{value in
                if value.phase=="Retrying retained-media cleanup" {gate.pause()}
            })
        }
        await fulfillment(of:[gate.entered],timeout:10);retry.cancel()
        await fulfillment(of:[gate.cancelled],timeout:10)
        XCTAssertFalse(finished.value);XCTAssertTrue(FileManager.default.fileExists(atPath:orphan.path))
        gate.release();let stopped=try await retry.value
        XCTAssertTrue(finished.value);XCTAssertTrue(stopped.cancelled);XCTAssertFalse(stopped.cleanupComplete)
        XCTAssertThrowsError(try MemoryStore(root:location,recoveryReadOnly:false,nativeWriterEnvironment:environment))
        let cleaned=try await PersonalSyncRetirementRecovery.retry(root:location,environment:environment)
        XCTAssertTrue(cleaned.cleanupComplete);XCTAssertFalse(FileManager.default.fileExists(atPath:orphan.path))
        try reopenA();XCTAssertEqual(try a.stats(includeDiskUsage:false).count,0)
        guard case .needsGroupReview=try ready(sa) else {return XCTFail("Recovery cannot authorize group erasure")}
    }
}
