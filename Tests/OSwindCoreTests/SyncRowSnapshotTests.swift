import XCTest
import CSQLite
@testable import OSwindCore

final class SyncRowSnapshotTests:XCTestCase {
    func testStorageClassesRawUnicodeNulAndExactRealBitsRoundTrip()throws {
        let cells:[SyncRowCell]=[.null,.integer(.min),.integer(.max),.real((-0.0).bitPattern),.real(Double.pi.bitPattern),.text(Data("e\u{301}\0authored".utf8)),.text(Data("é".utf8)),.blob(Data([0,255,0])),.blob(Data())]
        let snapshot=try SyncRowSnapshot(cells),encoded=try snapshot.encoded();XCTAssertEqual(try SyncRowSnapshot.decode(encoded),snapshot)
        let prefixed=Data([0,0,0])+encoded;XCTAssertEqual(try SyncRowSnapshot.decode(prefixed.dropFirst(3)),snapshot)
    }
    func testMalformedFramesBoundsAndNonfiniteRealRefuse()throws {
        let valid=try SyncRowSnapshot([.text(Data("owned".utf8))]).encoded()
        for bytes in [Data(),Data(valid.dropLast()),valid+Data([0]),Data([79,87,83,82,2,1,0]),Data([79,87,83,82,1,1,9]),Data([79,87,83,82,1,33,0])] {XCTAssertThrowsError(try SyncRowSnapshot.decode(bytes))}
        XCTAssertThrowsError(try SyncRowSnapshot([]));XCTAssertThrowsError(try SyncRowSnapshot([.real(Double.infinity.bitPattern)]).encoded())
    }
    func testSQLFunctionPreservesTypesWithoutJSONOrTextCoercion()throws {
        var handle:OpaquePointer?;XCTAssertEqual(sqlite3_open(":memory:",&handle),SQLITE_OK);let db=RoutineDatabase(handle:try XCTUnwrap(handle));defer {sqlite3_close(handle)}
        try SyncRowSnapshot.register(on:db)
        let row=try db.statement("SELECT oswind_sync_row_v1(NULL,9223372036854775807,?,CAST(x'6500cc81' AS TEXT),x'00ff',x'')");defer {sqlite3_finalize(row)}
        sqlite3_bind_double(row,1,Double.pi);XCTAssertEqual(sqlite3_step(row),SQLITE_ROW)
        let data=Data(bytes:try XCTUnwrap(sqlite3_column_blob(row,0)),count:Int(sqlite3_column_bytes(row,0)))
        XCTAssertEqual(try SyncRowSnapshot.decode(data).cells,[.null,.integer(.max),.real(Double.pi.bitPattern),.text(Data([101,0,204,129])),.blob(Data([0,255])),.blob(Data())])
        let unsafe=try db.statement("SELECT oswind_sync_row_v1(?)");defer {sqlite3_finalize(unsafe)};sqlite3_bind_double(unsafe,1,Double.infinity);XCTAssertNotEqual(sqlite3_step(unsafe),SQLITE_ROW)
    }
}
