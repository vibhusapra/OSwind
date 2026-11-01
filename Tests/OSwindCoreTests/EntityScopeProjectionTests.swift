import XCTest
import CSQLite
@testable import OSwindCore

final class EntityScopeProjectionTests:XCTestCase {
    private func frame(_ value:ChatPayload)throws->SyncRowSnapshot {
        try .init([.text(Data("owned-turn".utf8)),.text(Data("owned-chat".utf8)),.real(Double(1700000000).bitPattern),.blob(SyncProtocolLimits.encode(value))])
    }
    private func payload()->ChatPayload {.init(question:"Owned e\u{301} question",text:"Owned 👩🏽‍💻 answer",provider:"owned",duration:1,warnings:[],filter:SearchFilter(entityID:"owned-entity"),timeZone:"UTC")}
    func testPermitIsExactConnectionScopedNonDeterministicAndClearsAfterCancellation()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-entity-scope-permit-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root.appendingPathComponent("owner")),foreign=try MemoryStore(root:root.appendingPathComponent("foreign"));defer {try? store.close();try? foreign.close()}
        let old=payload();var new=old;new.filter.entityID=nil;new.filter.unavailableEntityScope = .init()
        let before=try frame(old),after=try frame(new)
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT oswind_unavailable_scope_projection_v1(?,?)");defer {sqlite3_finalize(row)}
            let a=try before.encoded(),b=try after.encoded();a.withUnsafeBytes {_=sqlite3_bind_blob(row,1,$0.baseAddress,Int32(a.count),db.transient)};b.withUnsafeBytes {_=sqlite3_bind_blob(row,2,$0.baseAddress,Int32(b.count),db.transient)}
            func check(_ expected:Int32)throws {sqlite3_reset(row);guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};XCTAssertEqual(sqlite3_column_int(row,0),expected)}
            try check(0)
            XCTAssertThrowsError(try store.entityScopeProjection.withTurn(before:before,after:after) {
                try check(1)
                XCTAssertThrowsError(try store.entityScopeProjection.withTurn(before:before,after:after) {})
                try foreign.withRoutineDatabase {other in
                    let foreignRow=try other.statement("SELECT oswind_unavailable_scope_projection_v1(?,?)");defer {sqlite3_finalize(foreignRow)}
                    a.withUnsafeBytes {_=sqlite3_bind_blob(foreignRow,1,$0.baseAddress,Int32(a.count),other.transient)};b.withUnsafeBytes {_=sqlite3_bind_blob(foreignRow,2,$0.baseAddress,Int32(b.count),other.transient)}
                    XCTAssertEqual(sqlite3_step(foreignRow),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(foreignRow,0),0)
                }
                throw CancellationError()
            }) {XCTAssertTrue($0 is CancellationError)}
            try check(0)
            let flags=try db.statement("SELECT flags FROM pragma_function_list WHERE name='oswind_unavailable_scope_projection_v1'");defer {sqlite3_finalize(flags)};XCTAssertEqual(sqlite3_step(flags),SQLITE_ROW);XCTAssertEqual(sqlite3_column_int(flags,0)&SQLITE_DETERMINISTIC,0)
        }
    }
    func testPermitCannotPreserveOtherTextChangesOrRetargetAnActiveScope()throws {
        let permit=EntityScopeProjection(),old=payload(),before=try frame(old)
        var changed=old;changed.filter.entityID=nil;changed.filter.unavailableEntityScope = .init();changed.text="Changed answer"
        XCTAssertThrowsError(try permit.withTurn(before:before,after:frame(changed)) {})
        changed=old;changed.filter.entityID="another-active-entity"
        XCTAssertThrowsError(try permit.withTurn(before:before,after:frame(changed)) {})
        var cells=before.cells;cells[0] = .text(Data("different-turn".utf8))
        XCTAssertThrowsError(try permit.withTurn(before:before,after:SyncRowSnapshot(cells)) {})
    }
}
