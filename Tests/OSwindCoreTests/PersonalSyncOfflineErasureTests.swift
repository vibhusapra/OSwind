import XCTest
@testable import OSwindCore

extension SyncNativeReceivedRetirementTests {
    func stopSenderForOfflineErase()throws {
        try sa.stop();sa.inbox.close();sa.transport.close();pa.close();pa=try pairing(a)
    }
    func files(_ directory:URL)throws->[String:Data] {
        var result=[String:Data]()
        for case let url as URL in FileManager.default.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey])! {
            if try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true {result[String(url.path.dropFirst(directory.path.count+1))]=try Data(contentsOf:url)}
        }
        return result
    }
    func testNativeOnlyErasureWorksWithMissingProviderAndPreservesOriginalAccounts()async throws {
        try stopSenderForOfflineErase();try sb.stop();sb.inbox.close();sb.transport.close()
        let shared=root.appendingPathComponent("shared"),offline=root.appendingPathComponent("unavailable-provider")
        try FileManager.default.moveItem(at:shared,to:offline)
        let original=try files(offline),accounts=Set(storage.values.keys)
        let eraser=try pa.prepareLocalErasure()
        XCTAssertTrue(a.requiresOwnedLibraryErasure)
        let erased=try await eraser.erase();await eraser.stop()
        XCTAssertTrue(erased.cleanupComplete);XCTAssertEqual(erased.erasure.sources,2)
        XCTAssertFalse(FileManager.default.fileExists(atPath:shared.path));XCTAssertEqual(try files(offline),original)
        XCTAssertEqual(Set(storage.values.keys),accounts);XCTAssertEqual(try b.stats(includeDiskUsage:false).count,2)
        try a.insert(Memory(id:"offline-new",text:"Owned recording after native-only renewal"))
        XCTAssertEqual(try a.stats(includeDiskUsage:false).count,1)
        try FileManager.default.moveItem(at:offline,to:shared);try reopenA()
        guard case .needsGroupReview=try ready(sa) else {return XCTFail("Offline local erase cannot approve peer erasure")}
    }
    func testNativeOnlyErasureCannotReplaceLiveDeliveryOrCloseItsPairingOwner()throws {
        let accounts=storage.values
        XCTAssertThrowsError(try pa.prepareLocalErasure())
        XCTAssertEqual(storage.values,accounts);XCTAssertEqual(try a.stats(includeDiskUsage:false).count,2)
        XCTAssertEqual(try pa.status().phase,.owner)
        guard case .transferred=try ready(sa) else {return XCTFail("Refused secondary eraser must preserve live delivery")}
    }
    func testNativeOnlyErasureStopJoinsCanceledLogicalWorkWithoutProviderAccess()async throws {
        try stopSenderForOfflineErase()
        let eraser=try pa.prepareLocalErasure(),gate=SyncSessionEraseGate(),stopped=SyncSessionStopProbe(),accounts=storage.values
        defer {gate.release()}
        let erase=Task {try await eraser.erase(progress:{value in if value.phase=="Inventorying retained media" {gate.pause()}})}
        await fulfillment(of:[gate.entered],timeout:10)
        let stop=Task {await eraser.stop();stopped.mark()};stop.cancel()
        await fulfillment(of:[gate.cancelled],timeout:10)
        XCTAssertFalse(stopped.value);XCTAssertEqual(try count(a,"memories"),2)
        gate.release()
        do {_=try await erase.value;XCTFail("Canceled logical erase must roll back")}catch {}
        await stop.value;XCTAssertTrue(stopped.value);XCTAssertEqual(storage.values,accounts)
        XCTAssertEqual(try count(a,"memories"),2)
        pa=try pairing(a);let retry=try pa.prepareLocalErasure()
        let cleaned=try await retry.erase();await retry.stop()
        XCTAssertTrue(cleaned.cleanupComplete);XCTAssertEqual(cleaned.erasure.sources,2)
    }
}
