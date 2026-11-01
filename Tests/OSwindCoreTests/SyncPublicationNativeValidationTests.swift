import XCTest
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    func testPublicationQueueSourcePressureRollsBackRootReceiptRedactionAndGraphThenRetriesWithoutEviction()throws {
        try withQueueFixture(citations:1) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox)
            try supplyDeclarations(f.operations,f.producer,service)
            for operation in f.operations {_=try queueReceive(operation,f.ac,service)}
            let source=try XCTUnwrap(f.operations.first{$0.key.kind == .source}),owner=try packet(XCTUnwrap(f.operations.first{$0.key.kind == .turn}),f.ac),chat=try XCTUnwrap(f.b.chats().first),before=try f.b.chatTurns(chat.id)
            let cursor=try f.bc.journal.cursor(for:producerID),outbox=try f.bc.journal.outbox(),deletion=try f.ac.journal.delete(key:source.key)
            // There is enough budget for an opaque job, but not its required
            // source edge. The API must refuse this receipt explicitly rather
            // than commit half of its redaction/withdrawal/native erasure.
            try f.queue.setBudgets(pending:512,binding:SyncPublicationQueue.defaultBudget)
            XCTAssertThrowsError(try queueReceive(deletion,f.ac,service)) {error in
                XCTAssertTrue(String(describing:error).contains("publication dependencies are full"),String(describing:error))
            }
            XCTAssertEqual(try f.bc.journal.cursor(for:producerID),cursor);XCTAssertEqual(try f.bc.journal.outbox(),outbox);XCTAssertFalse(try f.bc.journal.state(for:source.key).isDeleted)
            XCTAssertEqual(try f.b.chatTurns(chat.id).map(\.id),before.map(\.id));XCTAssertEqual(try f.b.chats().first?.title,chat.title)
            XCTAssertEqual(try count(f.b,"memories"),1);XCTAssertEqual(try count(f.b,"chat_sources"),1);XCTAssertTrue(try f.queue.isComplete(owner.identity));XCTAssertTrue(try f.queue.jobs(readyOnly:false).isEmpty);try f.queue.checkAccounting()
            try f.b.withRoutineDatabase {db in
                let row=try db.statement("SELECT count(*) FROM personal_sync_receipts WHERE replica=? AND sequence=?");defer {sqlite3_finalize(row)};db.bind(row,1,deletion.dot.replica);sqlite3_bind_int64(row,2,deletion.dot.counter)
                XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int64(row,0),0)
            }
            try f.queue.setBudgets(pending:640,binding:SyncPublicationQueue.defaultBudget)
            let replay=try queueReceive(deletion,f.ac,service);XCTAssertTrue(replay.receipt.inserted);XCTAssertEqual(replay.receipt.applied,1)
            XCTAssertEqual(try count(f.b,"memories"),0);XCTAssertEqual(try count(f.b,"chat_turns"),0);XCTAssertTrue(try f.bc.journal.state(for:source.key).isDeleted)
            XCTAssertEqual(try f.queue.jobs(readyOnly:false).map(\.reason),[.erasedEvidence]);XCTAssertFalse(try f.bc.journal.state(for:owner.identity.key).isDeleted);try f.queue.checkAccounting()
        }
    }
    func testPublicationQueueSourceRedactionRejectsTextCreatedDateWithoutCoercion()throws {try rejectRedactionDate(column:"created",blob:false)}
    func testPublicationQueueSourceRedactionRejectsBlobCreatedDateWithoutCoercion()throws {try rejectRedactionDate(column:"created",blob:true)}
    func testPublicationQueueSourceRedactionRejectsTextUpdatedDateWithoutCoercion()throws {try rejectRedactionDate(column:"updated",blob:false)}
    func testPublicationQueueSourceRedactionRejectsBlobUpdatedDateWithoutCoercion()throws {try rejectRedactionDate(column:"updated",blob:true)}
    private func rejectRedactionDate(column:String,blob:Bool)throws {
        try withQueueFixture(citations:1) {f in
            let service=queueService(f.b,f.bc,f.queue,f.inbox)
            try supplyDeclarations(f.operations,f.producer,service)
            for operation in f.operations {_=try queueReceive(operation,f.ac,service)}
            let chat=try XCTUnwrap(f.b.chats().first),source=try XCTUnwrap(f.operations.first{$0.key.kind == .source}),deletion=try f.ac.journal.delete(key:source.key)
            try f.b.withRoutineDatabase {db in try SyncChangeCapture.withoutEcho(db,scope:f.bc.catalog.scope) {
                // Authored raw SQLite corruption, not a public app editing API.
                // REAL affinity retains these invalid TEXT/BLOB storage classes.
                try db.execute("UPDATE chat_sessions SET \(column)="+(blob ? "X'6e6f742d612d64617465'":"'not-a-date'")+" WHERE id IN (SELECT session_id FROM chat_turns)")
            }}
            let cursor=try f.bc.journal.cursor(for:producerID),outbox=try f.bc.journal.outbox()
            XCTAssertThrowsError(try queueReceive(deletion,f.ac,service)) {error in
                XCTAssertTrue(String(describing:error).contains("native numeric date"),String(describing:error))
            }
            XCTAssertEqual(try f.bc.journal.cursor(for:producerID),cursor);XCTAssertEqual(try f.bc.journal.outbox(),outbox)
            XCTAssertFalse(try f.bc.journal.state(for:source.key).isDeleted);XCTAssertEqual(try count(f.b,"memories"),1)
            XCTAssertEqual(try count(f.b,"chat_turns"),1);XCTAssertEqual(try count(f.b,"chat_sources"),1);XCTAssertTrue(try f.queue.jobs(readyOnly:false).isEmpty)
            try f.b.withRoutineDatabase {db in
                let row=try db.statement("SELECT typeof(\(column)),title FROM chat_sessions WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,chat.id)
                XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(db.text(row,0),blob ? "blob":"text");XCTAssertEqual(db.text(row,1),chat.title)
                let receipt=try db.statement("SELECT count(*) FROM personal_sync_receipts WHERE replica=? AND sequence=?");defer {sqlite3_finalize(receipt)};db.bind(receipt,1,deletion.dot.replica);sqlite3_bind_int64(receipt,2,deletion.dot.counter)
                XCTAssertEqual(sqlite3_step(receipt),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int64(receipt,0),0)
            };try f.queue.checkAccounting()
        }
    }
}
