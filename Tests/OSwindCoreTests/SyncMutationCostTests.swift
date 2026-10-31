import XCTest
import CSQLite
@testable import OSwindCore

private final class SyncObservationTrace {
    private let lock=NSLock()
    private var updates=0
    var count:Int {lock.lock();defer {lock.unlock()};return updates}
    func record(_ sql:String) {if sql.hasPrefix("UPDATE personal_sync_observed ") {lock.lock();updates+=1;lock.unlock()}}
    func install(_ db:RoutineDatabase) {
        sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{_,context,_,sql in
            if let context,let sql {Unmanaged<SyncObservationTrace>.fromOpaque(context).takeUnretainedValue().record(String(cString:sql.assumingMemoryBound(to:CChar.self)))};return 0
        },Unmanaged.passUnretained(self).toOpaque())
    }
}
extension SyncIncomingSourceTests {
    func testMutationCostNoChildProjectionNeedsNoObservationWriteAndNextLocalWriteObservesPeer()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        _=try a.createChat(title:"Owned no-child projection");try drain(a,ac);let operation=try XCTUnwrap(ac.journal.outbox().last),record=try packet(operation,ac),trace=SyncObservationTrace()
        try b.withRoutineDatabase {db in trace.install(db);defer {sqlite3_trace_v2(db.handle,0,nil,nil)};_=try receive(operation,record,b,bc,fetch:{_ in record})}
        XCTAssertEqual(trace.count,0,"A root with no child publication must not write the observation row")
        let other=try SyncObjectIdentity(table:.source,origin:bc.catalog.scope.origin,lifetime:UUID().uuidString.lowercased())
        let local=try bc.journal.put(key:other.key,content:.init(data:Data("Owned causal metadata".utf8)))
        XCTAssertTrue(local.context.contains(operation.dot),"The advanced peer cursor still supplies causality to later local writes")
    }
    func testMutationCostAlreadyObservedRootDoesNotRewriteClock()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        _=try a.createChat(title:"Owned repeated observation");try drain(a,ac);let operation=try XCTUnwrap(ac.journal.outbox().last),record=try packet(operation,ac);_=try receive(operation,record,b,bc,fetch:{_ in record})
        try bc.journal.observeAppliedRoot(operation.key)
        let trace=SyncObservationTrace()
        try b.withRoutineDatabase {db in trace.install(db);defer {sqlite3_trace_v2(db.handle,0,nil,nil)};try bc.journal.observeAppliedRoot(operation.key)}
        XCTAssertEqual(trace.count,0,"An unchanged authenticated frontier needs no SQLite write")
    }
}
