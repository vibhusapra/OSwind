import XCTest
import CSQLite
@testable import OSwindCore

private final class SyncJournalFailures:@unchecked Sendable {
    private let lock=NSLock();private var failures=0
    func append() {lock.lock();failures+=1;lock.unlock()}
    var count:Int {lock.lock();defer {lock.unlock()};return failures}
}
final class PersonalSyncJournalTests:XCTestCase {
    let a="00000000-0000-0000-0000-000000000001",b="00000000-0000-0000-0000-000000000002",c="00000000-0000-0000-0000-000000000003"
    let group="00000000-0000-0000-0000-000000000004",epoch="00000000-0000-0000-0000-000000000005"
    var root:URL!,store:MemoryStore!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-sync-journal-"+UUID().uuidString);store=try MemoryStore(root:root)
        try store.withRoutineDatabase {_ = try SyncJournal.install(database:$0,replica:a,group:group,epoch:epoch)}
    }
    override func tearDownWithError()throws {try store.close();store=nil;try FileManager.default.removeItem(at:root)}
    func journal<T>(_ body:(SyncJournal)throws->T)throws->T {try store.withRoutineDatabase {try SyncJournal.prepareConnection($0);return try body(SyncJournal(database:$0,replica:a,group:group,epoch:epoch))}}
    func key(_ id:String="owned")throws->SyncObjectKey {try .make(kind:.source,identity:Data(id.utf8))}
    func reference(_ text:String="owned")throws->SyncContentReference {try .init(data:Data(text.utf8))}
    func remote(_ actor:String,_ counter:Int64,_ context:SyncClock = .empty,_ deleted:Bool=false)throws->SyncRevision {
        try .init(key:key(),dot:.init(replica:actor,counter:counter),context:context,mutation:deleted ? .delete:.put,content:deleted ? nil:reference("\(actor)-\(counter)"))
    }
    func testLocalSourceAndOutboxCommitTogetherAndSurviveReopen()throws {
        let revision=try journal {j in try j.put(key:key(),content:reference()) {_ in try store.insert(Memory(id:"owned",text:"original source"))}}
        try store.close();store=try MemoryStore(root:root)
        try journal {j in XCTAssertEqual(try j.outbox(),[revision]);XCTAssertEqual(try j.cursor(for:a),1);XCTAssertEqual(try j.state(for:key()).preferred,revision)}
        XCTAssertEqual(try store.get("owned")?.text,"original source")
    }
    func testFailedTypedApplyRollsBackSourceStateCounterAndOutbox()throws {
        enum Stop:Error {case expected}
        XCTAssertThrowsError(try journal {j in try j.put(key:key(),content:reference()) {_ in try store.insert(Memory(id:"owned",text:"must roll back"));throw Stop.expected}})
        XCTAssertNil(try store.get("owned"))
        try journal {j in XCTAssertTrue(try j.outbox().isEmpty);XCTAssertEqual(try j.cursor(for:a),0);XCTAssertTrue(try j.state(for:key()).heads.isEmpty)
            XCTAssertEqual(try j.put(key:key(),content:reference()).dot.counter,1)
        }
    }
    func testOuterLibraryTransactionCanRollBackReleasedInnerSavepoint()throws {
        enum Stop:Error {case expected}
        XCTAssertThrowsError(try store.withRoutineDatabase {db in try db.transaction {
            let j=try SyncJournal(database:db,replica:a,group:group,epoch:epoch)
            try j.put(key:key(),content:reference())
            try store.insert(Memory(id:"owned",text:"outside transaction"));throw Stop.expected
        }})
        XCTAssertNil(try store.get("owned"));try journal {XCTAssertTrue(try $0.outbox().isEmpty)}
    }
    func testOutOfOrderReceivePersistsAndDrainsContiguousStream()throws {
        let first=try remote(b,1),second=try remote(b,2,SyncClock([b:1]))
        try journal {j in try j.allowPeer(b);XCTAssertEqual(try j.receive(second,contentAvailable:{_ in true}),.init(inserted:true,applied:0));XCTAssertEqual(try j.cursor(for:b),0)}
        try store.close();store=try MemoryStore(root:root)
        try journal {j in XCTAssertEqual(try j.receive(first,contentAvailable:{_ in true}),.init(inserted:true,applied:2));XCTAssertEqual(try j.cursor(for:b),2);XCTAssertEqual(try j.state(for:key()).heads,[second])}
    }
    func testCausalPeerDependencyWaitsForItsOtherPeer()throws {
        let earlier=try remote(b,1),later=try remote(c,1,SyncClock([b:1]))
        try journal {j in try j.allowPeer(b);try j.allowPeer(c)
            XCTAssertEqual(try j.receive(later,contentAvailable:{_ in true}).applied,0);XCTAssertEqual(try j.receive(earlier,contentAvailable:{_ in true}).applied,2)
            XCTAssertEqual(try j.cursor(for:c),1);XCTAssertEqual(try j.state(for:key()).heads,[later])
        }
    }
    func testMissingContentDefersButDeleteBarrierPreventsResurrectionBeforeGapArrives()throws {
        let first=try remote(b,1),deletion=try remote(b,2,SyncClock([b:1]),true)
        try journal {j in try j.allowPeer(b)
            XCTAssertEqual(try j.receive(first,contentAvailable:{_ in false}).applied,0)
            XCTAssertEqual(try j.receive(deletion,contentAvailable:{_ in false}).applied,2)
            XCTAssertTrue(try j.state(for:key()).isDeleted);XCTAssertEqual(try j.cursor(for:b),2)
        }
    }
    func testUnknownPeerForkAndClonedLocalIdentityRefuseWithoutMutation()throws {
        let first=try remote(b,1)
        try journal {j in XCTAssertThrowsError(try j.receive(first,contentAvailable:{_ in true}));try j.allowPeer(b);try j.receive(first,contentAvailable:{_ in true})
            let changed=try SyncRevision(key:key(),dot:first.dot,context:.empty,mutation:.delete)
            XCTAssertThrowsError(try j.receive(changed,contentAvailable:{_ in true}))
            XCTAssertThrowsError(try j.receive(remote(a,1),contentAvailable:{_ in true}))
            XCTAssertEqual(try j.cursor(for:b),1);XCTAssertFalse(try j.state(for:key()).isDeleted)
        }
    }
    func testFailedRemoteAdapterDoesNotAdvanceReceiptCursorOrSource()throws {
        enum Stop:Error {case expected}
        let first=try remote(b,1)
        try journal {j in try j.allowPeer(b)
            XCTAssertThrowsError(try j.receive(first,contentAvailable:{_ in true}) {_ in try store.insert(Memory(id:"owned",text:"invalid remote apply"));throw Stop.expected})
            XCTAssertNil(try store.get("owned"));XCTAssertEqual(try j.cursor(for:b),0)
            XCTAssertTrue(try j.receive(first,contentAvailable:{_ in true}).inserted);XCTAssertEqual(try j.cursor(for:b),1)
        }
    }
    func testConcurrentChangesRetainBothAndLocalResolutionExtendsClock()throws {
        try journal {j in try j.allowPeer(b);let local=try j.put(key:key(),content:reference("alpha"));let incoming=try remote(b,1)
            try j.receive(incoming,contentAvailable:{_ in true});XCTAssertTrue(try j.state(for:key()).isConflicted)
            XCTAssertThrowsError(try j.put(key:key(),content:reference("must not silently resolve")))
            XCTAssertThrowsError(try j.resolve(key:key(),expectedHeads:[local.dot],content:reference("stale review")))
            let resolved=try j.resolve(key:key(),expectedHeads:[local.dot,incoming.dot],content:reference("resolved"))
            XCTAssertTrue(resolved.context.contains(local.dot));XCTAssertTrue(resolved.context.contains(incoming.dot))
            XCTAssertEqual(try j.state(for:key()).heads,[resolved]);XCTAssertEqual(try j.outbox(after:1),[resolved])
        }
    }
    func testStaleWorkspaceAndCorruptLocalCursorCannotAdvanceOrExposeOutbox()throws {
        try journal {j in
            try j.database.execute("UPDATE personal_sync_peers SET cursor=10 WHERE replica='\(a)'")
            XCTAssertThrowsError(try j.put(key:key(),content:reference()))
            XCTAssertTrue(try j.outbox().isEmpty)
            try j.database.execute("UPDATE personal_sync_local SET epoch='\(c)' WHERE singleton=1")
            XCTAssertThrowsError(try j.put(key:key(),content:reference()))
            XCTAssertThrowsError(try j.allowPeer(b))
            XCTAssertThrowsError(try j.outbox())
            XCTAssertThrowsError(try j.state(for:key()))
            XCTAssertThrowsError(try j.drain(contentAvailable:{_ in true}))
        }
    }
    func testAbsentReceiptBelowCursorRefusesInsteadOfQueuingAnUnreachableOperation()throws {
        let first=try remote(b,1)
        try journal {j in
            try j.allowPeer(b);try j.receive(first,contentAvailable:{_ in true})
            try j.database.execute("DELETE FROM personal_sync_receipts WHERE replica='\(b)' AND sequence=1")
            XCTAssertThrowsError(try j.receive(first,contentAvailable:{_ in true}))
            XCTAssertEqual(try j.cursor(for:b),1)
        }
    }
    func testUnpreparedConnectionRefusesWritesUntilExplicitlyPrepared()throws {
        try store.withRoutineDatabase {db in
            let j=try SyncJournal(database:db,replica:a,group:group,epoch:epoch)
            try db.execute("PRAGMA synchronous=NORMAL")
            XCTAssertThrowsError(try j.put(key:key(),content:reference()))
            XCTAssertTrue(try j.outbox().isEmpty)
            try SyncJournal.prepareConnection(db)
            XCTAssertEqual(try j.put(key:key(),content:reference()).dot.counter,1)
        }
    }
    func testTwoConnectionsSerializeLocalSequencesWithoutLosingOutboxEntries()throws {
        let other=try MemoryStore(root:root);defer {try? other.close()}
        try other.withRoutineDatabase {try SyncJournal.prepareConnection($0)}
        let stores=[store!,other],failures=SyncJournalFailures(),a=self.a,group=self.group,epoch=self.epoch
        DispatchQueue.concurrentPerform(iterations:2) {writer in
            for index in 0..<20 {
                do {
                    let key=try SyncObjectKey.make(kind:.source,identity:Data("writer-\(writer)-\(index)".utf8)),reference=try SyncContentReference(data:Data("authored-\(index)".utf8))
                    try stores[writer].withRoutineDatabase {db in _=try SyncJournal(database:db,replica:a,group:group,epoch:epoch).put(key:key,content:reference)}
                }catch {failures.append()}
            }
        }
        XCTAssertEqual(failures.count,0)
        try journal {j in XCTAssertEqual(try j.outbox().map { $0.dot.counter },(1...40).map(Int64.init));XCTAssertEqual(try j.cursor(for:a),40)}
    }
    func testIdentityMismatchAndInvalidBoundsNeverResetWorkspace()throws {
        try journal {j in _=try j.put(key:key(),content:reference())
            XCTAssertThrowsError(try SyncJournal.install(database:j.database,replica:b,group:group,epoch:epoch))
            XCTAssertEqual(try j.cursor(for:a),1);XCTAssertThrowsError(try j.outbox(after:-1));XCTAssertThrowsError(try j.drain(limit:0,contentAvailable:{_ in true}))
        }
    }
}
