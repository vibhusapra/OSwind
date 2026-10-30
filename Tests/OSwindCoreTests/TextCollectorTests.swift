import XCTest
import Foundation
import CSQLite
@testable import OSwindCore

final class TextCollectorTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    let collector="dev.example.tickets"
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-collector-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError()throws {try store?.close();store=nil;try? FileManager.default.removeItem(at:root)}
    func record(_ key:String="ticket-123",text:String="Maya owns Aurora")->[String:Any] {["key":key,"timestamp":"2026-10-25T05:23:45.123456-07:00","app":"Tickets","bundleID":"dev.example.tickets","title":"Launch","text":text,"url":"https://example.com/ticket/123"]}
    func batch(_ records:[[String:Any]],id:String?=nil,extra:[String:Any]=[:])throws->Data {var object:[String:Any] = ["format":"OSwind collector batch","version":1,"collectorID":id ?? collector,"records":records];for(k,v)in extra {object[k]=v};return try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])}
    func testFrozenNamespaceAndFractionalTimestamp()throws {
        let result=try store.importCollectorBatch(batch([record()])),id=try XCTUnwrap(result.sourceIDs.first)
        XCTAssertEqual(id,"collector:dev.example.tickets:750e2f6fb300f764f94a0e110ed83aeae5b816bf9e20db82b46bdc777e4fd616")
        XCTAssertEqual(try TextCollector.tag(collectorID:collector),"collector:9bf18778581d07e6234c9529511a5a7f")
        XCTAssertEqual(result.imported,1);XCTAssertEqual(result.excluded,0)
        let source=try XCTUnwrap(store.get(id));XCTAssertEqual(source.kind,.note);XCTAssertEqual(try ISOTime.string(source.timestamp),"2026-10-25T12:23:45.123456Z")
        XCTAssertEqual(source.tags,["collector",try TextCollector.tag(collectorID:collector)])
    }
    func testExactUTF8KeysAndNamespacesDoNotCollapse()throws {
        let result=try store.importCollectorBatch(batch([record("é"),record("e\u{301}")]))
        XCTAssertNotEqual(result.sourceIDs[0],result.sourceIDs[1]);XCTAssertEqual(try store.stats().count,2)
        let another=try store.importCollectorBatch(batch([record("é")],id:"dev.other.tickets"));XCTAssertNotEqual(another.sourceIDs[0],result.sourceIDs[0]);XCTAssertEqual(try store.stats().count,3)
    }
    func testRetryUpdatesSourceAndPreservesUserCuration()throws {
        let input=try batch([record()]),first=try store.importCollectorBatch(input),id=first.sourceIDs[0]
        try store.setFavorite(id,value:true);try store.setTags(id,tags:["reviewed"])
        XCTAssertEqual(try store.importCollectorBatch(input).sourceIDs,first.sourceIDs)
        XCTAssertEqual(try store.stats().count,1)
        _=try store.importCollectorBatch(batch([record(text:"Cedar draft updated")]))
        let source=try XCTUnwrap(store.get(id));XCTAssertTrue(source.favorite);XCTAssertEqual(source.text,"Cedar draft updated")
        XCTAssertEqual(Set(source.tags),Set(["reviewed","collector",try TextCollector.tag(collectorID:collector)]))
    }
    func testChangedSourceInvalidatesDerivedEntityEvidence()throws {
        let result=try store.importCollectorBatch(batch([record()])),id=result.sourceIDs[0],original=try XCTUnwrap(store.get(id)),plan=try store.entityIndexPlan()
        try store.saveEntityExtraction(memory:original,plan:plan,result:.init(candidates:[.init(kind:.person,name:"Maya",start:0,length:4)]))
        XCTAssertEqual(try store.entities().count,1)
        _=try store.importCollectorBatch(batch([record(text:"Cedar draft updated")]))
        XCTAssertTrue(try store.entities().isEmpty);XCTAssertEqual(try store.entityIndexProgress(processor:EntityExtractor.processor(plan)).indexed,0)
    }
    func testMalformedLastRecordAndUnknownFieldsRefuseBeforeMutation()throws {
        let id=try TextCollector.sourceID(collectorID:collector,key:"first");try store.insert(Memory(id:id,kind:.note,text:"Keep original"))
        var bad=record("last");bad["url"]="file:///unsupported"
        XCTAssertThrowsError(try store.importCollectorBatch(batch([record("first",text:"must roll back"),bad])))
        bad=record("last");bad["imagePath"]="not-accepted.png"
        XCTAssertThrowsError(try store.importCollectorBatch(batch([record("first"),bad])))
        XCTAssertThrowsError(try store.importCollectorBatch(batch([record()],extra:["version":2])))
        XCTAssertThrowsError(try store.importCollectorBatch(batch([record()],extra:["unknown":"unsupported"])))
        XCTAssertEqual(try store.get(id)?.text,"Keep original");XCTAssertEqual(try store.stats().count,1)
    }
    func testLaterIncompatibleSourceRollsBackWholeTransaction()throws {
        let first=try TextCollector.sourceID(collectorID:collector,key:"first"),second=try TextCollector.sourceID(collectorID:collector,key:"second")
        try store.insert(Memory(id:first,kind:.note,text:"Keep first"));try store.setFavorite(first,value:true)
        try store.insert(Memory(id:second,kind:.audio,text:"Keep incompatible source"))
        XCTAssertThrowsError(try store.importCollectorBatch(batch([record("first",text:"Uncommitted update"),record("second")])))
        XCTAssertEqual(try store.get(first)?.text,"Keep first");XCTAssertEqual(try store.get(first)?.favorite,true);XCTAssertEqual(try store.get(second)?.kind,.audio);XCTAssertEqual(try store.stats().count,2)
    }
    func testExclusionsAndRedactionUseCurrentPolicyWithoutErasingEarlierHistory()throws {
        var allowed=record("allowed",text:"password=hello123");allowed["title"]="password=hello123";allowed["url"]="https://example.com/?password=hello123"
        var excluded=record("excluded");excluded["bundleID"]="com.apple.Passwords"
        var domain=record("domain");domain["url"]="https://sub.chase.com/fixture"
        let result=try store.importCollectorBatch(batch([allowed,excluded,domain]));XCTAssertEqual(result.requested,3);XCTAssertEqual(result.imported,1);XCTAssertEqual(result.excluded,2)
        let saved=try XCTUnwrap(store.get(result.sourceIDs[0]));XCTAssertFalse(saved.text.contains("hello123"));XCTAssertFalse(saved.title.contains("hello123"));XCTAssertFalse(saved.url?.contains("hello123") ?? true)
        XCTAssertNil(try store.get(result.sourceIDs[1]));XCTAssertNil(try store.get(result.sourceIDs[2]))
        allowed["bundleID"]="com.apple.Passwords";allowed["text"]="Excluded update"
        XCTAssertEqual(try store.importCollectorBatch(batch([allowed])).excluded,1);XCTAssertEqual(try store.get(saved.id)?.text,saved.text)
    }
    func testKnownBrowserWithoutURLHonorsRequiredContext()throws {
        var browser=record("browser");browser["bundleID"]="com.google.Chrome";browser.removeValue(forKey:"url")
        let result=try store.importCollectorBatch(batch([browser]))
        XCTAssertEqual(result.excluded,1);XCTAssertEqual(try store.stats().count,0)
        var relaxed=PrivacyPolicy();relaxed.requireBrowserContext=false
        XCTAssertEqual(try store.importCollectorBatch(batch([browser]),policy:relaxed).imported,1)
    }
    func testCancellationRollsBackAndLeavesStoreReusable()async throws {
        let data=try batch([record("one"),record("two")]),store=self.store!
        try store.withRoutineDatabase {db in
            sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{_,_,_,sql in
                if let sql,String(cString:sql.assumingMemoryBound(to:CChar.self)).hasPrefix("INSERT INTO memories(") {withUnsafeCurrentTask {$0?.cancel()}}
                return 0
            },nil)
        }
        let worker=Task.detached {try store.importCollectorBatch(data)}
        do {_=try await worker.value;XCTFail("Cancelled batch committed")}catch is CancellationError {} catch {throw error}
        try store.withRoutineDatabase {sqlite3_trace_v2($0.handle,0,nil,nil)}
        XCTAssertEqual(try store.stats().count,0);XCTAssertEqual(try store.importCollectorBatch(data).imported,2)
    }
    func testByteAndRecordBoundsAndDuplicateKeysRefuse()throws {
        XCTAssertThrowsError(try store.importCollectorBatch(Data(repeating:32,count:TextCollector.maximumBatchBytes+1))) {XCTAssertTrue($0.localizedDescription.contains("16 MiB"))}
        XCTAssertThrowsError(try store.importCollectorBatch(batch([record(text:String(repeating:"x",count:1024*1024+1))])))
        XCTAssertThrowsError(try store.importCollectorBatch(batch((0..<1001).map {record(String($0))})))
        XCTAssertThrowsError(try store.importCollectorBatch(batch([record(),record()])))
        XCTAssertThrowsError(try store.importCollectorBatch(batch([])))
        var bad=record();bad["timestamp"]="2026-10-25T12:23:45.123456";XCTAssertThrowsError(try store.importCollectorBatch(batch([bad])))
        XCTAssertThrowsError(try store.importCollectorBatch(batch([record()],id:"Invalid.Identity")))
        XCTAssertEqual(try store.stats().count,0)
    }
    func testClosedStoreAndAlreadyCancelledAdmissionRefuse()async throws {
        let data=try batch([record()]),store=self.store!
        let worker=Task.detached {withUnsafeCurrentTask {$0?.cancel()};return try store.importCollectorBatch(data)}
        do {_=try await worker.value;XCTFail("Already cancelled admission ran")}catch is CancellationError {} catch {throw error}
        XCTAssertEqual(try store.stats().count,0);try store.close();XCTAssertThrowsError(try store.importCollectorBatch(data))
        let reopened=try MemoryStore(root:root);defer {try? reopened.close()};XCTAssertEqual(try reopened.stats().count,0)
    }
}

final class NativeVaultCollectorTests:XCTestCase {
    func testKnownHeldReaderAtFirstCollectorLockRetainsPhaseAndRecoversNormally() async throws {
        try await knownHeldReader(atSecondLock:false)
    }
    func testKnownHeldReaderAtSecondCollectorLockRetainsPhaseAndRecoversNormally() async throws {
        try await knownHeldReader(atSecondLock:true)
    }
    private func knownHeldReader(atSecondLock:Bool) async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned collector known-reader native control")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-native-collector-known-reader-"+UUID().uuidString)
        try Paths.ensure(root)
        let trace=OwnedVaultNativeTrace(root:root)
        let driver=NativeVaultDriver(observer:{trace.append($0)},willMutate:{trace.beforeMutation($0,$1)})
        let package=root.appendingPathComponent("Collector.oswindvault"),secret=Data(UUID().uuidString.utf8)
        let vault=try LibraryVault(package:package,nativeDriver:driver)
        var active:MemoryStore?,reader:FileHandle?
        do {
            _=try await LibraryVault.create(at:package,name:"Owned collector reader control",capacityGiB:1,passphrase:secret,keepUnlocked:true)
            var store=try MemoryStore(root:vault.libraryURL)
            active=store
            let data=Data(#"{"format":"OSwind collector batch","version":1,"collectorID":"dev.example.notes","records":[{"key":"owned","timestamp":"2026-10-25T12:00:00Z","app":"Fixture","bundleID":"dev.example.notes","title":"Owned collector control","text":"Owned collector source survives known-reader refusal"}]}"#.utf8)
            let result=try store.importCollectorBatch(data)
            if atSecondLock {
                trace.setStage("collector-first-lock")
                _=try await vault.lock(store:store)
                active=nil
                _=try await vault.unlock(passphrase:secret)
                store=try MemoryStore(root:vault.libraryURL)
                active=store
                XCTAssertEqual(try store.get(result.sourceIDs[0])?.text,"Owned collector source survives known-reader refusal")
            }
            let phase=atSecondLock ? "collector-second-lock":"collector-first-lock"
            reader=try FileHandle(forReadingFrom:vault.libraryURL.appendingPathComponent("memory.sqlite"))
            let heldDescriptor=try XCTUnwrap(reader).fileDescriptor
            trace.setStage(phase)
            do {
                _=try await vault.lock(store:store)
                XCTFail("Known reader was detached")
            } catch let failure as VaultNativeFailure {
                XCTAssertEqual(failure.summary.operation,.imageDetach)
                XCTAssertEqual(failure.summary.status,16)
                XCTAssertEqual(failure.summary.termination,.exit)
                trace.markFailure()
            }
            XCTAssertTrue(store.isClosed)
            active=nil
            let failed=trace.snapshot()
            XCTAssertEqual(failed.failureStage,phase)
            let boundary=try XCTUnwrap(failed.beforeMutations.first {$0.stage==phase && $0.operation == .imageDetach})
            XCTAssertTrue(boundary.ownedHandles.contains {$0.descriptor==Int(heldDescriptor) && $0.mounted})
            XCTAssertTrue(failed.events.contains {$0.stage==phase && $0.event.summary.operation == .imageDetach && $0.event.summary.status==16})
            let attached=try await driver.attachment(paths:VaultPaths(package))
            XCTAssertEqual(attached?.mounted,true)
            try reader?.close()
            reader=nil
            let locked=try await vault.lock()
            XCTAssertFalse(locked.imageAttached)
            XCTAssertEqual(trace.snapshot().failureStage,phase)
            trace.setStage("collector-control-history-reopen")
            _=try await vault.unlock(passphrase:secret)
            let reopened=try MemoryStore(root:vault.libraryURL)
            active=reopened
            XCTAssertEqual(try reopened.get(result.sourceIDs[0])?.text,"Owned collector source survives known-reader refusal")
            trace.setStage("collector-control-final-lock")
            _=try await vault.lock(store:reopened)
            active=nil
            let inventory=try await VaultProcess.run("/usr/bin/hdiutil",["info","-plist"])
            XCTAssertEqual(inventory.status,0)
            let plist=try XCTUnwrap(PropertyListSerialization.propertyList(from:inventory.stdout,format:nil) as? [String:Any])
            let images=try XCTUnwrap(plist["images"] as? [[String:Any]])
            let image=package.appendingPathComponent("contents.sparsebundle").standardizedFileURL.resolvingSymlinksInPath()
            XCTAssertFalse(images.contains {($0["image-path"] as? String).map {URL(fileURLWithPath:$0).standardizedFileURL.resolvingSymlinksInPath()==image} ?? false})
            trace.setStage("collector-control-completed")
            try trace.save(root:root,secret:secret,failed:false)
            try FileManager.default.removeItem(at:root)
        } catch {
            let original=error
            trace.markFailure()
            try? reader?.close()
            try? active?.close()
            _=try? await vault.lock()
            do {try trace.save(root:root,secret:secret,failed:true)} catch {print("Owned collector control trace could not be saved; original failure is preserved")}
            throw original
        }
    }

    func testCollectorAdmissionAndReopenPreserveEncryptedHistoryWithoutPlaintextFallback()async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned synthetic encrypted collector fixture")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-native-collector-"+UUID().uuidString)
        try Paths.ensure(root)
        let trace=OwnedVaultNativeTrace(root:root)
        let driver=NativeVaultDriver(observer:{trace.append($0)},willMutate:{trace.beforeMutation($0,$1)})
        let package=root.appendingPathComponent("Collector.oswindvault"),secret=Data(UUID().uuidString.utf8)
        let vault=try LibraryVault(package:package,nativeDriver:driver)
        var active:MemoryStore?
        do {
            // Keep the original public create-with-unlock path. Native output
            // tracing is limited to subsequent credential-free inspections and mutations.
            trace.setStage("collector-create-unlocked")
            _=try await LibraryVault.create(at:package,name:"Owned text collector",capacityGiB:1,passphrase:secret,keepUnlocked:true)
            trace.setStage("collector-import")
            let store=try MemoryStore(root:vault.libraryURL)
            active=store
            let data=Data(#"{"format":"OSwind collector batch","version":1,"collectorID":"dev.example.notes","records":[{"key":"owned","timestamp":"2026-10-25T12:00:00Z","app":"Fixture","bundleID":"dev.example.notes","title":"Owned collector","text":"Owned collector source survives encrypted reopen"}]}"#.utf8)
            let result=try store.importCollectorBatch(data)
            trace.setStage("collector-first-lock")
            _=try await vault.lock(store:store)
            XCTAssertTrue(store.isClosed)
            active=nil
            trace.setStage("collector-closed-refusal")
            XCTAssertThrowsError(try MemoryStore(root:vault.libraryURL))
            XCTAssertThrowsError(try store.importCollectorBatch(data))
            trace.setStage("collector-reopen")
            _=try await vault.unlock(passphrase:secret)
            let reopened=try MemoryStore(root:vault.libraryURL)
            active=reopened
            trace.setStage("collector-preserved-history")
            XCTAssertEqual(try reopened.get(result.sourceIDs[0])?.text,"Owned collector source survives encrypted reopen")
            trace.setStage("collector-second-lock")
            _=try await vault.lock(store:reopened)
            XCTAssertTrue(reopened.isClosed)
            active=nil
            trace.setStage("collector-independent-absence")
            let inventory=try await VaultProcess.run("/usr/bin/hdiutil",["info","-plist"])
            XCTAssertEqual(inventory.status,0)
            let plist=try XCTUnwrap(PropertyListSerialization.propertyList(from:inventory.stdout,format:nil) as? [String:Any])
            let images=try XCTUnwrap(plist["images"] as? [[String:Any]])
            let attached=images.contains {($0["image-path"] as? String).map {URL(fileURLWithPath:$0).standardizedFileURL.resolvingSymlinksInPath()==package.appendingPathComponent("contents.sparsebundle").standardizedFileURL.resolvingSymlinksInPath()} ?? false}
            guard !attached else {throw OSwindError.unavailable("Owned collector image remains attached; fixture preserved")}
            let events=trace.snapshot()
            for phase in ["collector-first-lock","collector-second-lock"] {
                XCTAssertEqual(events.events.filter {$0.stage==phase && $0.event.summary.operation == .imageDetach}.count,1)
                XCTAssertEqual(events.beforeMutations.filter {$0.stage==phase && $0.operation == .imageDetach}.count,1)
            }
            trace.setStage("collector-completed")
            try trace.save(root:root,secret:secret,failed:false)
            try FileManager.default.removeItem(at:root)
        } catch {
            let original=error
            trace.markFailure()
            try? active?.close()
            _=try? await vault.lock()
            do {try trace.save(root:root,secret:secret,failed:true)} catch {print("Owned collector trace could not be saved; original failure is preserved")}
            throw original
        }
    }
}
