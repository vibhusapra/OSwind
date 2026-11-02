import XCTest
@testable import OSwindCore

extension SyncIncomingSourceTests {
    func testLibraryWipeRejectsPreviouslyUnseenOfflineSourceBeforeItsBodyIsRequested()throws {
        let (a,ac)=try endpoint("offline-producer",producerID),(b,bc)=try endpoint("wiped-receiver",receiverID)
        defer {try? a.close();try? b.close()}
        try bc.journal.allowPeer(producerID)
        try a.insert(Memory(id:"offline-before-wipe",timestamp:now,kind:.note,app:"Owned offline app",text:"Authored old offline history must stay erased"))
        try drain(a,ac)
        let operation=try XCTUnwrap(ac.journal.outbox().first),record=try packet(operation,ac)
        XCTAssertEqual(try count(b,"memories"),0)
        _=try b.wipeLibrary()
        // A collection barrier must preserve genuinely new local work as well
        // as suppressing unseen old peer lifetimes. Do not erase everything on
        // every peer delivery as a substitute for era-aware admission.
        try b.insert(Memory(id:"local-after-wipe",timestamp:now.addingTimeInterval(1),kind:.note,app:"Owned fresh app",text:"Authored new local history must survive"))
        try drain(b,bc)
        XCTAssertNotNil(try b.get("local-after-wipe"))
        var bodyChecks=0,projected=false
        let lease=try b.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        let result=try bc.journal.receive(operation,contentAvailable:{_ in bodyChecks+=1;return true}) {_ in
            projected=true
            _=try writer.apply(record,admission:lease,fetchExactSource:{_ in throw OSwindError.invalid("Owned source has no dependencies")})
        }
        XCTAssertEqual(result.applied,1,"Discarding an erased old operation must still advance its authenticated producer stream")
        XCTAssertEqual(try bc.journal.cursor(for:producerID),operation.dot.counter)
        XCTAssertEqual(bodyChecks,0,"An unseen pre-wipe object must be refused before fetching its old content")
        XCTAssertFalse(projected,"An unseen pre-wipe lifetime must not reach native projection")
        XCTAssertEqual(try count(b,"memories"),1,"Late old peer content must not repopulate the wiped library")
        XCTAssertNotNil(try b.get("local-after-wipe"))
    }
}
