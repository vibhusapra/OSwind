import XCTest
import Foundation
import CSQLite
@testable import OSwindCore

private final class LifecycleValue<T>:@unchecked Sendable {
    private let lock=NSLock();private var storage:T
    init(_ value:T){storage=value}
    var value:T {get {lock.lock();defer {lock.unlock()};return storage} set {lock.lock();storage=newValue;lock.unlock()}}
}

final class StoreLifecycleTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-lifecycle-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError()throws {try store?.close();store=nil;try? FileManager.default.removeItem(at:root)}
    private func sql(_ db:OpaquePointer,_ text:String)throws {guard sqlite3_exec(db,text,nil,nil,nil)==SQLITE_OK else {throw OSwindError.database("Owned lifecycle SQL fixture failed")}}
    /// Hold an actual uncommitted writer and the store's SQL mutex. Every exit
    /// releases and joins the owned worker before the temporary root is removed.
    private func withHeldWriter(_ body:()throws->Void)throws {
        let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0),failure=LifecycleValue<String?>(nil),store=self.store!
        DispatchQueue(label:"OSwind.test.held-writer",qos:.userInitiated).async {
            defer {done.signal()}
            do {try store.withRoutineDatabase {db in
                try self.sql(db.handle,"BEGIN IMMEDIATE")
                do {
                    try store.insert(Memory(id:"owned-writer",kind:.note,text:"Owned uncommitted lifecycle fixture"))
                    entered.signal()
                    guard release.wait(timeout:.now()+10) == .success else {throw OSwindError.unavailable("Owned writer release timed out")}
                    try self.sql(db.handle,"COMMIT")
                } catch {try? self.sql(db.handle,"ROLLBACK");throw error}
            }} catch {failure.value=error.localizedDescription}
        }
        defer {release.signal();XCTAssertEqual(done.wait(timeout:.now()+15),.success);XCTAssertNil(failure.value)}
        guard entered.wait(timeout:.now()+5) == .success else {throw OSwindError.unavailable("Owned writer did not enter")}
        try body()
    }
    func testStatusReadFinishesWhileWriterHeldAndSQLReadStaysSerialized()throws {
        let probeDone=DispatchSemaphore(value:0),queryStarted=DispatchSemaphore(value:0),queryDone=DispatchSemaphore(value:0),probe=LifecycleValue<Bool?>(nil),queryCount=LifecycleValue<Int?>(nil),queryFailure=LifecycleValue<String?>(nil),store=self.store!
        var probeWasEarly=false
        try withHeldWriter {
            DispatchQueue(label:"OSwind.test.sql-reader",qos:.userInitiated).async {
                queryStarted.signal();defer {queryDone.signal()}
                do {queryCount.value=try store.stats().count} catch {queryFailure.value=error.localizedDescription}
            }
            XCTAssertEqual(queryStarted.wait(timeout:.now()+2),.success)
            DispatchQueue(label:"OSwind.test.status-reader",qos:.userInitiated).async {probe.value=store.isClosed;probeDone.signal()}
            probeWasEarly=probeDone.wait(timeout:.now()+1) == .success
            XCTAssertTrue(probeWasEarly,"Lifecycle status waited for the unrelated SQL writer")
            if probeWasEarly {XCTAssertEqual(probe.value,false)}
            XCTAssertEqual(queryDone.wait(timeout:.now()+0.05),.timedOut,"SQL read escaped the store mutex")
        }
        if !probeWasEarly {XCTAssertEqual(probeDone.wait(timeout:.now()+5),.success)}
        XCTAssertEqual(queryDone.wait(timeout:.now()+5),.success);XCTAssertEqual(queryCount.value,1);XCTAssertNil(queryFailure.value)
        XCTAssertEqual(probe.value,false);XCTAssertEqual(try store.get("owned-writer")?.text,"Owned uncommitted lifecycle fixture")
    }
    func testPendingCloseDoesNotClaimClosedBeforeWriterAndNativeCloseFinish()throws {
        let closeStarted=DispatchSemaphore(value:0),closed=DispatchSemaphore(value:0),probeDone=DispatchSemaphore(value:0),failure=LifecycleValue<String?>(nil),probe=LifecycleValue<Bool?>(nil),store=self.store!
        var probeWasEarly=false
        try withHeldWriter {
            DispatchQueue(label:"OSwind.test.pending-close",qos:.userInitiated).async {
                closeStarted.signal();defer {closed.signal()}
                do {try store.close()} catch {failure.value=error.localizedDescription}
            }
            XCTAssertEqual(closeStarted.wait(timeout:.now()+2),.success)
            DispatchQueue(label:"OSwind.test.close-status",qos:.userInitiated).async {probe.value=store.isClosed;probeDone.signal()}
            probeWasEarly=probeDone.wait(timeout:.now()+1) == .success
            XCTAssertTrue(probeWasEarly,"Status read was queued behind draining close work")
            if probeWasEarly {XCTAssertEqual(probe.value,false)}
            XCTAssertEqual(closed.wait(timeout:.now()+0.05),.timedOut)
        }
        if !probeWasEarly {XCTAssertEqual(probeDone.wait(timeout:.now()+5),.success)}
        XCTAssertEqual(closed.wait(timeout:.now()+5),.success);XCTAssertNil(failure.value);XCTAssertTrue(store.isClosed)
        let reopened=try MemoryStore(root:root);defer {try? reopened.close()};XCTAssertEqual(try reopened.get("owned-writer")?.text,"Owned uncommitted lifecycle fixture")
    }
    func testOrdinaryCloseAndRepeatedClosePublishClosedAndRejectQueries()throws {
        XCTAssertFalse(store.isClosed);try store.close();XCTAssertTrue(store.isClosed);try store.close();XCTAssertTrue(store.isClosed)
        XCTAssertThrowsError(try store.stats());XCTAssertThrowsError(try store.insert(Memory(kind:.note,text:"Must not reopen")))
    }
    func testConcurrentStatusReadersObserveOnlyOpenToClosedTransition()throws {
        let ready=DispatchSemaphore(value:0),go=DispatchSemaphore(value:0),done=DispatchGroup(),failures=LifecycleValue<[String]>([]),store=self.store!
        for index in 0..<4 {
            done.enter()
            DispatchQueue(label:"OSwind.test.lifecycle-\(index)",qos:.userInitiated).async {
                defer {done.leave()}
                let initial=store.isClosed;ready.signal()
                guard go.wait(timeout:.now()+5) == .success else {failures.value=["Reader gate timed out"];return}
                var sawClosed=false,reopened=initial
                for _ in 0..<10_000 {let closed=store.isClosed;if sawClosed && !closed {reopened=true};sawClosed = sawClosed || closed}
                if reopened {failures.value=["Connection status reopened or began closed"]}
            }
        }
        for _ in 0..<4 {XCTAssertEqual(ready.wait(timeout:.now()+5),.success)}
        for _ in 0..<4 {go.signal()}
        defer {XCTAssertEqual(done.wait(timeout:.now()+10),.success)}
        try store.close()
        XCTAssertEqual(done.wait(timeout:.now()+10),.success);XCTAssertTrue(failures.value.isEmpty);XCTAssertTrue(store.isClosed)
    }
    func testFailedNativeCloseKeepsConnectionOpenUntilStatementReleased()throws {
        var statement:OpaquePointer?
        try store.withRoutineDatabase {db in XCTAssertEqual(sqlite3_prepare_v2(db.handle,"SELECT 1",-1,&statement,nil),SQLITE_OK)}
        defer {if let statement {sqlite3_finalize(statement)}}
        XCTAssertThrowsError(try store.close());XCTAssertFalse(store.isClosed)
        XCTAssertEqual(sqlite3_finalize(statement),SQLITE_OK);statement=nil
        try store.close();XCTAssertTrue(store.isClosed)
    }
    func testSealedRestorePublishesClosedState()throws {
        try store.insert(Memory(id:"owned-sealed",kind:.note,text:"Owned restore seal"));try store.sealRestoredLibrary();XCTAssertTrue(store.isClosed)
        XCTAssertThrowsError(try store.stats());try store.close()
        let reopened=try MemoryStore(root:root);defer {try? reopened.close()};XCTAssertEqual(try reopened.get("owned-sealed")?.text,"Owned restore seal")
    }
    func testDiscardedRestorePublishesClosedState()throws {
        try store.insert(Memory(id:"owned-discard",kind:.note,text:"Owned discarded connection"));store.discardRestoreConnection();XCTAssertTrue(store.isClosed)
        store.discardRestoreConnection();XCTAssertThrowsError(try store.stats());try store.close()
    }
}
