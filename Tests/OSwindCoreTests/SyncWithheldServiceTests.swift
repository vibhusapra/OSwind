import XCTest
import CSQLite
import CryptoKit
@testable import OSwindCore

extension SyncOutgoingTests {
    func blockFixtureApp(_ store:MemoryStore)throws {
        var settings=AppSettings();settings.privacy.excludedApps.append("owned.blocked");try settings.save(root:store.root)
    }
    func blockedFixtureMemory(_ id:String)->Memory {Memory(id:id,timestamp:now,kind:.note,app:"Owned blocked",bundleID:"owned.blocked",text:"Owned local-only material")}
    func sourceLocalID(_ cache:SyncVersionStore,_ key:SyncObjectKey)throws->String {
        guard let object=try cache.catalog.object(for:key),let primary=object.primary,case .text(let bytes)=primary[0],let value=String(data:bytes,encoding:.utf8) else {throw OSwindError.invalid("Owned fixture has no native source mapping")};return value
    }
    func waitForService(_ ready:()async throws->Bool)async throws->Bool {
        for _ in 0..<1000 {if try await ready() {return true};try await Task.sleep(nanoseconds:10_000_000)};return false
    }
    func sharedFileHashes(_ folder:SyncObjectFolder)throws->[String:String] {
        var result=[String:String]();let paths=try XCTUnwrap(FileManager.default.enumerator(at:folder.root,includingPropertiesForKeys:nil))
        for case let path as URL in paths {if try path.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true {result[path.path]=SHA256.hash(data:try Data(contentsOf:path)).map{String(format:"%02x",$0)}.joined()}}
        return result
    }

    func testServiceWithheldSourceDoesNotStarveHealthyRowsOrInventPeerSequenceGaps()throws {
        try withServicePair {f in
            try blockFixtureApp(store);try store.insert(blockedFixtureMemory("owned-blocked"));try seed("healthy","Visible healthy note")
            _=try serviceReady(f.a,limit:64);_=try serviceReady(f.b,limit:64)
            XCTAssertEqual(try f.a.withheldCount(),1);XCTAssertEqual(try serviceCount(f.receiver,"memories"),1)
            XCTAssertEqual(try f.receiver.search(.init(query:"Visible healthy"),mode:.keyword).map(\.memory.text),["Visible healthy note"])
            XCTAssertEqual(try f.a.cache.journal.outbox().map(\.dot.counter),[1])
            XCTAssertEqual(try n("SELECT used_bytes FROM personal_sync_capture"),0);XCTAssertEqual(try n("SELECT used_bytes FROM personal_sync_work_state"),0)
            XCTAssertEqual(try n("SELECT used_bytes FROM personal_sync_withheld_state"),320)
            let ordinal=try n("SELECT ordinal FROM personal_sync_withheld")
            for _ in 0..<8 {XCTAssertEqual(try f.a.tick(),.waitingForPolicy(1))}
            XCTAssertEqual(try n("SELECT ordinal FROM personal_sync_withheld"),ordinal)
            for i in 0..<20 {try seed("healthy-\(i)","Visible continuation \(i)")}
            _=try serviceReady(f.a,limit:64);_=try serviceReady(f.b,limit:64)
            XCTAssertEqual(try serviceCount(f.receiver,"memories"),21);XCTAssertEqual(try f.a.withheldCount(),1)
            XCTAssertEqual(try f.a.cache.journal.outbox().map(\.dot.counter),Array(1...21).map(Int64.init))
            XCTAssertEqual(try f.b.cache.journal.cursor(for:replica),21)
            try store.withRoutineDatabase {db in
                let row=try db.statement("SELECT owner_digest,denied_digest,policy_sha FROM personal_sync_withheld");defer {sqlite3_finalize(row)}
                XCTAssertEqual(sqlite3_step(row),SQLITE_ROW)
                for col:Int32 in 0...2 {XCTAssertEqual(db.text(row,col).utf8.count,64);XCTAssertFalse(db.text(row,col).contains("owned-blocked"))}
            }
        }
    }

    func testServiceSavedPolicyReviewReleasesHeldSourceAndDeletionRecreationKeepsNewLifetime()throws {
        try withServicePair {f in
            try blockFixtureApp(store);try store.insert(blockedFixtureMemory("owned-recreated"))
            XCTAssertEqual(try serviceReady(f.a,limit:64),.waitingForPolicy(1))
            let old=try store.withRoutineDatabase {db -> SyncObjectIdentity in
                let row=try db.statement("SELECT i.table_name,i.origin,i.lifetime FROM personal_sync_withheld w JOIN personal_sync_identities i ON i.object_digest=w.owner_digest");defer {sqlite3_finalize(row)}
                guard sqlite3_step(row)==SQLITE_ROW,let table=SyncCanonicalTable(rawValue:db.text(row,0)) else {throw OSwindError.invalid("Missing owned held identity")}
                return try .init(table:table,origin:db.text(row,1),lifetime:db.text(row,2))
            }
            _=try store.delete("owned-recreated");try store.insert(blockedFixtureMemory("owned-recreated"))
            _=try serviceReady(f.a,limit:64);XCTAssertTrue(try f.a.cache.journal.state(for:old.key).isDeleted)
            XCTAssertEqual(try f.a.withheldCount(),1)
            try AppSettings().save(root:root)
            _=try serviceReady(f.a,limit:64);_=try serviceReady(f.b,limit:64)
            XCTAssertEqual(try f.a.withheldCount(),0);XCTAssertEqual(try serviceCount(f.receiver,"memories"),1)
            let put=try XCTUnwrap(f.a.cache.journal.outbox().last);XCTAssertNotEqual(put.key,try old.key)
            XCTAssertEqual(put.mutation,.put);XCTAssertEqual(try f.b.cache.journal.cursor(for:replica),put.dot.counter)
        }
    }

    func testServiceHeldWorkSurvivesLibraryReopenAndNativeEditWakesItWithoutPolicyToggle()throws {
        try withServicePair {f in
            try blockFixtureApp(store);try store.insert(blockedFixtureMemory("owned-edited"))
            XCTAssertEqual(try serviceReady(f.a,limit:64),.waitingForPolicy(1))
            try f.a.stop();try store.close();f.localA.close();store=try MemoryStore(root:root)
            let inbox=try SyncObjectFolder.open(at:f.localA.root,secret:f.secret,group:group,epoch:epoch);defer {inbox.close()}
            let resumed=try SyncLibraryService.install(library:store,replica:replica,group:group,epoch:epoch,peers:f.a.peers,transport:f.transport,inbox:inbox);defer {try? resumed.stop()}
            XCTAssertEqual(try serviceReady(resumed,limit:64),.waitingForPolicy(1))
            try seed("owned-edited","Edited eligible source")
            _=try serviceReady(resumed,limit:64);_=try serviceReady(f.b,limit:64)
            XCTAssertEqual(try resumed.withheldCount(),0);XCTAssertEqual(try resumed.cache.journal.outbox().count,1)
            XCTAssertEqual(try f.receiver.search(.init(query:"Edited eligible"),mode:.keyword).map(\.memory.text),["Edited eligible source"])
        }
    }

    func testServicePeerPutCannotOverwriteHeldNativeEditButAuthenticatedDeletionWins()throws {
        try seed()
        try withServicePair {f in
            _=try serviceReady(f.a,limit:64);_=try serviceReady(f.b,limit:64)
            let first=try XCTUnwrap(f.a.cache.journal.outbox().first),local=try sourceLocalID(f.b.cache,first.key)
            try f.receiver.insert(Memory(id:local,timestamp:now,kind:.note,app:"Owned",text:"password=owned-local-private-edit"))
            XCTAssertEqual(try serviceReady(f.b,limit:64),.waitingForPolicy(1))
            try seed("owned","Owned remote replacement")
            _=try serviceReady(f.a,limit:64)
            XCTAssertThrowsError(try serviceReady(f.b,limit:64))
            XCTAssertEqual(try f.receiver.get(local)?.text,"password=owned-local-private-edit")
            XCTAssertEqual(try f.b.cache.journal.cursor(for:replica),1);XCTAssertEqual(try f.b.withheldCount(),1)
            _=try store.delete("owned");_=try serviceReady(f.a,limit:64);_=try serviceReady(f.b,limit:64)
            XCTAssertNil(try f.receiver.get(local));XCTAssertEqual(try f.b.withheldCount(),0)
            XCTAssertEqual(try f.b.cache.journal.cursor(for:replica),3)
            XCTAssertTrue(try f.b.cache.journal.outbox().isEmpty)
            XCTAssertEqual(try f.receiver.withRoutineDatabase {try $0.eraseCount("SELECT oswind_sync_withheld_erasure_v1()")},0)
        }
    }

    func testServiceSourceErasureCompletesBeforeConflictingIndependentHeldMetadata()throws {
        try seedGraph()
        try withServicePair {f in
            _=try serviceReady(f.a,limit:64);_=try serviceReady(f.b,limit:64)
            try f.receiver.withRoutineDatabase {try $0.execute("UPDATE chat_sessions SET title='password=owned-private-conversation-title'")}
            XCTAssertEqual(try serviceReady(f.b,limit:64),.waitingForPolicy(1))
            _=try store.delete("owned");_=try serviceReady(f.a,limit:64)
            XCTAssertThrowsError(try serviceReady(f.b,limit:64)) {XCTAssertTrue(SyncWithheldWork.isNativeHold($0))}
            XCTAssertEqual(try serviceCount(f.receiver,"chat_turns"),0)
            XCTAssertEqual(try f.receiver.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM memories WHERE text='Alice owns Orion.'")},0)
            XCTAssertEqual(try f.b.withheldCount(),1)
            // The later ordinary conversation put cannot overwrite a separate
            // unpublished private title. Its journal receipt rolls back while
            // the already committed source/answer erasure remains effective.
            XCTAssertEqual(try f.receiver.withRoutineDatabase {try $0.eraseCount("SELECT COUNT(*) FROM chat_sessions WHERE title LIKE 'password=%'")},1)
            XCTAssertEqual(try f.b.cache.journal.cursor(for:replica),30)
            XCTAssertEqual(try f.receiver.withRoutineDatabase {try $0.eraseCount("SELECT oswind_sync_withheld_erasure_v1()")},0)
        }
    }

    func testServiceHeldNativeErasurePermitIsConnectionScopedAndClearsAfterThrow()throws {
        try withServicePair {f in
            XCTAssertThrowsError(try store.withRoutineDatabase {db in
                try SyncChangeCapture.transaction(db) {
                    try SyncWithheldWork.withNativeErasure(db,enabled:true) {
                        XCTAssertEqual(try db.eraseCount("SELECT oswind_sync_withheld_erasure_v1()"),1)
                        XCTAssertEqual(try f.receiver.withRoutineDatabase {try $0.eraseCount("SELECT oswind_sync_withheld_erasure_v1()")},0)
                        throw OSwindError.invalid("Owned permission rollback")
                    }
                }
            })
            XCTAssertEqual(try n("SELECT oswind_sync_withheld_erasure_v1()"),0)
        }
    }

    func testServiceNetworkPausePreparesLocallyWithClosedTransportAndResumesWithoutLostRows()throws {
        try withServicePair {f in
            try blockFixtureApp(store);try store.insert(blockedFixtureMemory("offline-held"))
            for i in 0..<15 {try seed("offline-\(i)","Owned offline source \(i)")}
            func files()->[String:String] {
                var result=[String:String]();let paths=FileManager.default.enumerator(at:f.transport.root,includingPropertiesForKeys:nil)!
                for case let path as URL in paths {if (try? path.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true {result[path.path]=SHA256.hash(data:try! Data(contentsOf:path)).map{String(format:"%02x",$0)}.joined()}}
                return result
            }
            let before=files();f.transport.close()
            XCTAssertEqual(try serviceReady(f.a,limit:64,networkEnabled:false),.networkPaused(withheld:1))
            XCTAssertEqual(files(),before);XCTAssertEqual(try f.a.cache.journal.outbox().count,15)
            XCTAssertEqual(try n("SELECT used_bytes FROM personal_sync_capture"),0);XCTAssertEqual(try n("SELECT used_bytes FROM personal_sync_work_state"),0)
            try f.a.stop();try f.b.stop()
            let shared=try SyncObjectFolder.open(at:f.transport.root,secret:f.secret,group:group,epoch:epoch);defer {shared.close()}
            let a=try SyncLibraryService.install(library:store,replica:replica,group:group,epoch:epoch,peers:f.a.peers,transport:shared,inbox:f.localA)
            let b=try SyncLibraryService.install(library:f.receiver,replica:f.b.cache.journal.replica,group:group,epoch:epoch,peers:[replica],transport:shared,inbox:f.localB)
            defer {try? a.stop();try? b.stop()}
            _=try serviceReady(a,limit:64);_=try serviceReady(b,limit:64)
            XCTAssertEqual(try serviceCount(f.receiver,"memories"),15);XCTAssertEqual(try b.cache.journal.cursor(for:replica),15)
            XCTAssertEqual(try a.withheldCount(),1)
        }
    }

    func testServiceWithheldBudgetFailureDoesNotAcknowledgeOrLoseNativeWorkAndCanRecover()throws {
        try withServicePair {f in
            let held=try store.withRoutineDatabase {_ in try SyncWithheldWork.install(catalog:f.a.cache.catalog)}
            try store.withRoutineDatabase {_ in try held.setBudget(320)}
            try blockFixtureApp(store);try store.insert(blockedFixtureMemory("quota-a"));try store.insert(blockedFixtureMemory("quota-b"))
            XCTAssertThrowsError(try serviceReady(f.a,limit:64)) {XCTAssertTrue(SyncWithheldWork.isMetadataFull($0))}
            XCTAssertEqual(try f.a.withheldCount(),0);XCTAssertEqual(try n("SELECT COUNT(*) FROM personal_sync_work"),2)
            XCTAssertEqual(try serviceCount(store,"memories"),2);XCTAssertTrue(try f.a.cache.journal.outbox().isEmpty)
            try store.withRoutineDatabase {_ in try held.setBudget(640)}
            XCTAssertEqual(try serviceReady(f.a,limit:64),.waitingForPolicy(2))
            XCTAssertEqual(try f.a.withheldCount(),2);XCTAssertEqual(try n("SELECT used_bytes FROM personal_sync_work_state"),0)
            XCTAssertThrowsError(try store.withRoutineDatabase {_ in try held.setBudget(320)})
            try seed("quota-healthy","Owned healthy after quota recovery");_=try serviceReady(f.a,limit:64);_=try serviceReady(f.b,limit:64)
            XCTAssertEqual(try serviceCount(f.receiver,"memories"),1);XCTAssertEqual(try f.a.withheldCount(),2)
            try store.withRoutineDatabase {_ in try held.checkAccounting()}
        }
    }

    func testServiceSchedulerContinuesLocalPreparationDuringPeerPrivacyConflict()async throws {
        try seed()
        try await withServicePairAsync {f in
            _=try serviceReady(f.a,limit:64);_=try serviceReady(f.b,limit:64)
            let first=try XCTUnwrap(f.a.cache.journal.outbox().first),local=try sourceLocalID(f.b.cache,first.key)
            try f.receiver.insert(Memory(id:local,timestamp:now,kind:.note,app:"Owned",text:"password=owned-private-scheduler-edit"))
            _=try serviceReady(f.b,limit:64)
            try seed("owned","Owned peer change while held");_=try serviceReady(f.a,limit:64)
            let scheduler=try SyncLibraryScheduler(service:f.b,schedule:.init(activeSeconds:0.001,idleSeconds:0.01,retrySeconds:0.01))
            do {
                try await scheduler.start()
                let conflicted=try await waitForService {await scheduler.state == .retryingPolicy};XCTAssertTrue(conflicted)
                try f.receiver.insert(Memory(id:"healthy-during-conflict",timestamp:now,kind:.note,app:"Owned",text:"Owned local while peer conflicts"))
                let delivered=try await waitForService {try f.transport.serviceHead(replica:f.b.cache.journal.replica)?.through==1};XCTAssertTrue(delivered)
                try await scheduler.stop()
            }catch {try? await scheduler.stop();throw error}
            _=try serviceReady(f.a,limit:64)
            XCTAssertEqual(try store.search(.init(query:#""Owned local while peer conflicts""#),mode:.keyword).map(\.memory.text),["Owned local while peer conflicts"])
            XCTAssertEqual(try f.receiver.get(local)?.text,"password=owned-private-scheduler-edit")
            XCTAssertEqual(try f.receiver.withRoutineDatabase {try $0.eraseCount("SELECT used_bytes FROM personal_sync_capture")},0)
            XCTAssertFalse(SyncWithheldWork.isNativeHold(OSwindError.database("Unrelated database failure")))
        }
    }

    func testServiceSchedulerNetworkPauseJoinsRemoteWorkWhileLocalCaptureKeepsDraining()async throws {
        try seed()
        try await withServicePairAsync {f in
            let scheduler=try SyncLibraryScheduler(service:f.a,schedule:.init(activeSeconds:0.001,idleSeconds:0.01,retrySeconds:0.01))
            do {
                try await scheduler.start()
                let initial=try await waitForService {try f.transport.serviceHead(replica:replica)?.through==1};XCTAssertTrue(initial)
                try await scheduler.setNetworkEnabled(false)
                let before=try sharedFileHashes(f.transport)
                try blockFixtureApp(store);try store.insert(blockedFixtureMemory("paused-held"));try seed("paused-healthy","Owned healthy while paused")
                let prepared=try await waitForService {await scheduler.state == .running(.networkPaused(withheld:1))};XCTAssertTrue(prepared)
                XCTAssertEqual(try sharedFileHashes(f.transport),before)
                XCTAssertEqual(try f.a.cache.journal.outbox().count,2)
                XCTAssertEqual(try n("SELECT used_bytes FROM personal_sync_capture"),0)
                XCTAssertEqual(try n("SELECT used_bytes FROM personal_sync_work_state"),0)
                try await scheduler.setNetworkEnabled(true)
                let resumed=try await waitForService {try f.transport.serviceHead(replica:replica)?.through==2};XCTAssertTrue(resumed)
                try await scheduler.stop()
                do {try await scheduler.setNetworkEnabled(false);XCTFail("Stopped owner must not start a replacement worker")}catch {}
            }catch {try? await scheduler.stop();throw error}
            _=try serviceReady(f.b,limit:64)
            XCTAssertEqual(try serviceCount(f.receiver,"memories"),2)
            XCTAssertEqual(try f.b.cache.journal.cursor(for:replica),2)
        }
    }

    func testServicePolicyReviewUsesPersistedFinitePagesAcrossRestartAndNewArrivals()throws {
        try withServicePair {f in
            try blockFixtureApp(store)
            for i in 0..<100 {try store.insert(blockedFixtureMemory("held-page-\(i)"))}
            XCTAssertEqual(try serviceReady(f.a,limit:16,networkEnabled:false),.networkPaused(withheld:100))
            var settings=AppSettings.load(root:root);settings.privacy.excludedDomains.append("unused-policy-change.example");try settings.save(root:root)
            for _ in 0..<3 {_=try f.a.tick(limit:7,networkEnabled:false)}
            XCTAssertEqual(try n("SELECT review_through FROM personal_sync_withheld_state"),100)
            XCTAssertGreaterThan(try n("SELECT review_after FROM personal_sync_withheld_state"),0)
            XCTAssertEqual(try n("SELECT reviewing FROM personal_sync_withheld_state"),1)
            try store.insert(blockedFixtureMemory("held-new-during-review"))
            let cursor=try n("SELECT review_after FROM personal_sync_withheld_state")
            try f.a.stop();try store.close();f.localA.close();store=try MemoryStore(root:root)
            let inbox=try SyncObjectFolder.open(at:f.localA.root,secret:f.secret,group:group,epoch:epoch);defer {inbox.close()}
            let resumed=try SyncLibraryService.install(library:store,replica:replica,group:group,epoch:epoch,peers:f.a.peers,transport:f.transport,inbox:inbox);defer {try? resumed.stop()}
            XCTAssertEqual(try n("SELECT review_after FROM personal_sync_withheld_state"),cursor)
            XCTAssertEqual(try serviceReady(resumed,limit:16,networkEnabled:false),.networkPaused(withheld:101))
            XCTAssertEqual(try n("SELECT reviewing FROM personal_sync_withheld_state"),0)
            XCTAssertLessThanOrEqual(try n("SELECT review_after FROM personal_sync_withheld_state"),100)
            XCTAssertEqual(try n("SELECT review_through FROM personal_sync_withheld_state"),100)
            XCTAssertTrue(try resumed.cache.journal.outbox().isEmpty)
            XCTAssertEqual(try n("SELECT used_bytes FROM personal_sync_capture"),0)
            XCTAssertEqual(try n("SELECT used_bytes FROM personal_sync_work_state"),0)
            XCTAssertEqual(try n("SELECT used_bytes FROM personal_sync_withheld_state"),101*320)
        }
    }
}
