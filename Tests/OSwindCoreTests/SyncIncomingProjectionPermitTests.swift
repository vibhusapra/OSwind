import XCTest
import CSQLite
@testable import OSwindCore

final class SyncIncomingProjectionPermitTests:XCTestCase {
    func withStores(_ body:(MemoryStore,MemoryStore)throws->Void)throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-source-permit-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let a=try MemoryStore(root:root.appendingPathComponent("a")),b=try MemoryStore(root:root.appendingPathComponent("b"))
        defer {try? a.close();try? b.close()};try body(a,b)
    }
    func scalar(_ store:MemoryStore,_ sql:String,_ arguments:[SyncRowCell])throws->Int {
        try store.withRoutineDatabase {db in
            let row=try db.statement(sql);defer {sqlite3_finalize(row)}
            for (offset,cell) in arguments.enumerated() {
                let index=Int32(offset+1)
                switch cell {
                case .text(let bytes):bytes.withUnsafeBytes {_=sqlite3_bind_text(row,index,$0.baseAddress?.assumingMemoryBound(to:CChar.self),Int32(bytes.count),db.transient)}
                case .blob(let bytes):bytes.withUnsafeBytes {_=sqlite3_bind_blob(row,index,$0.baseAddress,Int32(bytes.count),db.transient)}
                default:throw OSwindError.invalid("Unsupported permit fixture argument")
                }
            }
            guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return Int(sqlite3_column_int(row,0))
        }
    }
    func source(_ store:MemoryStore,_ memory:Memory,owner:String?=nil)throws->Int {
        try scalar(store,"SELECT oswind_incoming_source_projection_v1(?,?)",[.text(Data((owner ?? memory.id).utf8)),.blob(SyncProtocolLimits.encode(memory))])
    }
    func testSourcePermitIsExactConnectionScopedNonDeterministicAndClearsAfterCancellation()throws {
        try withStores {a,b in
            let value=Memory(id:"caf\u{e9}",timestamp:Date(timeIntervalSince1970:1700000000),kind:.note,app:"Owned",text:"Exact original")
            XCTAssertEqual(try source(a,value),0)
            XCTAssertThrowsError(try a.incomingSourceProjection.withSource(value) {
                XCTAssertEqual(try source(a,value),1);XCTAssertEqual(try source(b,value),0)
                XCTAssertEqual(try source(a,value,owner:"cafe\u{301}"),0)
                var changed=value;changed.text="Forged body";XCTAssertEqual(try source(a,changed),0)
                changed=value;changed.favorite=true;XCTAssertEqual(try source(a,changed),0)
                XCTAssertThrowsError(try a.incomingSourceProjection.withSource(value) {})
                throw CancellationError()
            })
            XCTAssertEqual(try source(a,value),0)
            try a.incomingSourceProjection.withSource(value) {XCTAssertEqual(try source(a,value),1)}
            XCTAssertEqual(try source(a,value),0)
            try a.withRoutineDatabase {db in
                for name in ["oswind_incoming_source_projection_v1","oswind_incoming_binding_projection_v1"] {
                    XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM pragma_function_list WHERE name='"+name+"' AND (flags & 2048)=0 AND (flags & 2097152)!=0"),1)
                }
            }
        }
    }
    func testBindingPermitAcceptsRealWidthsAndRejectsForgedUnrelatedCellsAndCrossConnection()throws {
        try withStores {a,b in
            let owner="owned-source",handle=UUID().uuidString.lowercased()
            for recap in [false,true] {
                let table=recap ? "recap_sources":"chat_sources"
                var before:[SyncRowCell]=[.text(Data("turn-or-recap".utf8)),.text(Data(owner.utf8)),.integer(0)]
                if recap {before.append(.text(Data("old-revision".utf8)))}
                before += [.real(1.0.bitPattern),.text(Data("owned-match".utf8)),.integer(1),.integer(3),.null,.null]
                var after=before;after[1] = .null;after[after.count-2] = .text(Data(owner.utf8));after[after.count-1] = .text(Data(handle.utf8))
                if recap {after[3] = .text(Data("new-revision".utf8))}
                func check(_ store:MemoryStore,_ cells:[SyncRowCell],_ name:String?=nil)throws->Int {
                    try scalar(store,"SELECT oswind_incoming_binding_projection_v1(?,?,?)",[.text(Data((name ?? table).utf8)),.blob(SyncRowSnapshot(before).encoded()),.blob(SyncRowSnapshot(cells).encoded())])
                }
                XCTAssertEqual(try check(a,after),0)
                XCTAssertThrowsError(try a.incomingSourceProjection.withBinding(owner:owner,handle:handle,oldRevision:"old-revision",newRevision:"new-revision") {
                    XCTAssertEqual(try check(a,after),1);XCTAssertEqual(try check(b,after),0)
                    XCTAssertEqual(try check(a,after,"memories"),0)
                    for index in [0,2,recap ? 4:3,recap ? 5:4,recap ? 6:5,after.count-2,after.count-1] {
                        var forged=after;forged[index] = .text(Data("forged".utf8));XCTAssertEqual(try check(a,forged),0,"Forged cell \(index), \(table)")
                    }
                    throw CancellationError()
                })
                XCTAssertEqual(try check(a,after),0)
            }
        }
    }
}
