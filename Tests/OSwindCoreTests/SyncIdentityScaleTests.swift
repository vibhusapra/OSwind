import XCTest
import CSQLite
import CryptoKit
import Darwin
@testable import OSwindCore

/// Metadata bootstrap on authored source rows only. Not typed content transfer,
/// live capture, actual API ingestion, a cold-cache or physical-energy benchmark.
final class SyncIdentityScaleTests:XCTestCase {
    func testOwnedIdentityBootstrapAndIncrementalLifetimeScale()throws {
        let env=ProcessInfo.processInfo.environment,fm=FileManager.default
        guard let count=env["OSWIND_TEST_SYNC_IDENTITY_SCALE_ROWS"].flatMap(Int.init),let path=env["OSWIND_TEST_SYNC_IDENTITY_SCALE_OUTPUT"] else {throw XCTSkip("Explicit owned identity bootstrap scale fixture not requested")}
        guard [1000,100000,1000000].contains(count) else {throw OSwindError.invalid("Invalid identity fixture size")}
        let base=URL(fileURLWithPath:path,isDirectory:true)
        guard !fm.fileExists(atPath:base.path) else {throw OSwindError.invalid("Identity fixture output must be fresh")}
        var volume=statfs();guard statfs(base.deletingLastPathComponent().path,&volume)==0,UInt64(volume.f_bavail)*UInt64(volume.f_bsize)>5*1024*1024*1024 else {throw OSwindError.unavailable("Identity scale fixture requires five GiB free")}
        try fm.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try Data("OSwind authored identity bootstrap scale fixture v1".utf8).write(to:base.appendingPathComponent("owned-fixture"),options:.withoutOverwriting)
        let started=Date(),library=base.appendingPathComponent("library"),store=try MemoryStore(root:library);defer {try? store.close()}
        let template=Memory(id:"template",timestamp:Date(timeIntervalSince1970:1700000000),kind:.note,app:"Owned identity scale",title:"Identity source",text:"template"),data=try JSONEncoder().encode(template),load=ProcessInfo.processInfo.systemUptime
        try store.withRoutineDatabase {db in try db.transaction {
            let row=try db.statement("""
            WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<?)
            INSERT INTO memories(id,timestamp,kind,app,title,url,text,favorite,payload)
            SELECT 'identity-'||x,1700000000,'note','Owned identity scale','Identity source',NULL,'Owned identity source '||x,0,
                   CAST(json_set(CAST(? AS TEXT),'$.id','identity-'||x,'$.text','Owned identity source '||x) AS BLOB) FROM n
            """);defer {sqlite3_finalize(row)};sqlite3_bind_int(row,1,Int32(count));data.withUnsafeBytes {_=sqlite3_bind_blob(row,2,$0.baseAddress,Int32(data.count),db.transient)};try db.done(row)
        }}
        let loadSeconds=ProcessInfo.processInfo.systemUptime-load
        func originalHash()throws->String {
            try store.withRoutineDatabase {db in
                let row=try db.statement("SELECT oswind_sync_row_v1(id,timestamp,kind,app,title,url,text,favorite,payload,embedding,embedding_model) FROM memories ORDER BY id COLLATE BINARY");defer {sqlite3_finalize(row)}
                var hash=SHA256(),rows=0,status=sqlite3_step(row)
                while status==SQLITE_ROW {
                    let size=Int(sqlite3_column_bytes(row,0));guard size>0,let pointer=sqlite3_column_blob(row,0) else {throw db.error()}
                    var n=UInt64(size).littleEndian;hash.update(data:withUnsafeBytes(of:&n){Data($0)});hash.update(data:Data(bytes:pointer,count:size));rows+=1;status=sqlite3_step(row)
                }
                guard status==SQLITE_DONE,rows==count else {throw OSwindError.invalid("Identity scale source membership changed")}
                return hash.finalize().map {String(format:"%02x",$0)}.joined()
            }
        }
        let before=try originalHash()
        try store.withRoutineDatabase {db in _=try SyncChangeCapture.activate(db);_=try SyncIdentityCatalog.install(db)}
        var batches=[[String:Any]](),seen=0,complete=false
        let bootstrapStart=ProcessInfo.processInfo.systemUptime
        while !complete {
            let start=ProcessInfo.processInfo.systemUptime
            let result=try store.withRoutineDatabase {db in
                let c=SyncIdentityCatalog(database:db,scope:try SyncChangeCapture.scope(db))
                return try c.bootstrap(.source,limit:128,byteLimit:1024*1024) {batch in
                    for value in batch {
                        guard value.identity.table == .source,value.primary.count==1,case .text(let bytes)=value.primary[0],let id=String(data:bytes,encoding:.utf8),id.hasPrefix("identity-"),let ordinal=Int(id.dropFirst(9)),(1...count).contains(ordinal),id=="identity-\(ordinal)" else {throw OSwindError.invalid("Unexpected identity fixture key")}
                    }
                    seen+=batch.count
                }
            }
            batches.append(["objects":result.objects,"complete":result.complete,"milliseconds":(ProcessInfo.processInfo.systemUptime-start)*1000]);complete=result.complete
        }
        let bootstrapSeconds=ProcessInfo.processInfo.systemUptime-bootstrapStart
        guard seen==count else {throw OSwindError.invalid("Identity bootstrap skipped source keys")}
        try store.close()
        let reopened=try MemoryStore(root:library);defer {try? reopened.close()}
        func catalog<T>(_ body:(SyncIdentityCatalog)throws->T)throws->T {try reopened.withRoutineDatabase {db in try SyncChangeCapture.prepare(db);return try body(.init(database:db,scope:SyncChangeCapture.scope(db)))}}
        try catalog {c in let result=try c.bootstrap(.source,consume:{_ in XCTFail("Completed bootstrap visited sources again")});guard result == .init(objects:0,complete:true) else {throw OSwindError.invalid("Completed bootstrap did not resume")}}
        var incremental=[[String:Any]]()
        func consume()throws->SyncIdentifiedChange {
            var changes=[SyncIdentifiedChange]();let start=ProcessInfo.processInfo.systemUptime
            try catalog {c in guard try c.process(consume:{changes=$0})==1,changes.count==1 else {throw OSwindError.invalid("Incremental fixture did not consume exactly one intent")}}
            incremental.append(["milliseconds":(ProcessInfo.processInfo.systemUptime-start)*1000,"before":try changes[0].before?.key.digest as Any? ?? NSNull(),"after":try changes[0].after?.key.digest as Any? ?? NSNull()])
            return changes[0]
        }
        let probe="owned-lifecycle-probe",text="Owned lifecycle probe"
        try reopened.insert(Memory(id:probe,text:text));let first=try XCTUnwrap(consume().after)
        try reopened.withRoutineDatabase {try $0.execute("DELETE FROM memories WHERE id='owned-lifecycle-probe'")};let removed=try consume();guard removed.before==first,removed.after==nil else {throw OSwindError.invalid("First lifetime deletion differs")}
        try reopened.insert(Memory(id:probe,text:text));let fresh=try XCTUnwrap(consume().after);guard fresh != first else {throw OSwindError.invalid("Recreated source reused its deleted lifetime")}
        try catalog {try $0.deletePeer(first) {XCTAssertNil($0)}}
        XCTAssertEqual(try reopened.search(.init(query:"\"Owned lifecycle probe\"",limit:5),mode:.keyword).map(\.id),[probe])
        try reopened.withRoutineDatabase {try $0.execute("DELETE FROM memories WHERE id='owned-lifecycle-probe'")};_=try consume()
        XCTAssertTrue(try reopened.search(.init(query:"\"Owned lifecycle probe\"",limit:5),mode:.keyword).isEmpty)
        let metadata=try reopened.withRoutineDatabase {db in
            func n(_ sql:String)throws->Int64 {let s=try db.statement(sql);defer {sqlite3_finalize(s)};guard sqlite3_step(s)==SQLITE_ROW else {throw db.error()};return sqlite3_column_int64(s,0)}
            return ["identities":try n("SELECT COUNT(*) FROM personal_sync_identities"),"live":try n("SELECT COUNT(*) FROM personal_sync_identities WHERE deleted=0"),"tombstones":try n("SELECT COUNT(*) FROM personal_sync_identities WHERE deleted=1"),"currentKeys":try n("SELECT COUNT(*) FROM personal_sync_identity_current"),"pending":try n("SELECT COUNT(*) FROM personal_sync_changes"),"deletedRawKeys":try n("SELECT COUNT(*) FROM personal_sync_identities WHERE deleted=1 AND key_frame IS NOT NULL"),"completedWithoutRawCursor":try n("SELECT COUNT(*) FROM personal_sync_identity_bootstrap WHERE complete=1 AND next_key IS NULL AND cursor_key IS NULL")]
        }
        guard metadata["identities"]==Int64(count+2),metadata["live"]==Int64(count),metadata["tombstones"]==2,metadata["currentKeys"]==Int64(count+1),metadata["pending"]==0,metadata["deletedRawKeys"]==0,metadata["completedWithoutRawCursor"]==1 else {throw OSwindError.invalid("Identity scale accounting differs")}
        try reopened.close()
        // Reopen only the same authored fixture to compare all original typed cells.
        let final=try MemoryStore(root:library);defer {try? final.close()}
        let after=try final.withRoutineDatabase {db -> String in
            let row=try db.statement("SELECT oswind_sync_row_v1(id,timestamp,kind,app,title,url,text,favorite,payload,embedding,embedding_model) FROM memories ORDER BY id COLLATE BINARY");defer {sqlite3_finalize(row)}
            var hash=SHA256(),rows=0,code=sqlite3_step(row)
            while code==SQLITE_ROW {let size=Int(sqlite3_column_bytes(row,0));guard size>0,let p=sqlite3_column_blob(row,0) else {throw db.error()};var n=UInt64(size).littleEndian;hash.update(data:withUnsafeBytes(of:&n){Data($0)});hash.update(data:Data(bytes:p,count:size));rows+=1;code=sqlite3_step(row)}
            guard code==SQLITE_DONE,rows==count else {throw OSwindError.invalid("Final original source membership differs")};return hash.finalize().map {String(format:"%02x",$0)}.joined()
        }
        guard before==after else {throw OSwindError.invalid("Original identity fixture source cells changed")}
        try final.close()
        let raw=batches.map {$0["milliseconds"] as! Double},sorted=raw.sorted(),median=sorted.count.isMultiple(of:2) ? (sorted[sorted.count/2-1]+sorted[sorted.count/2])/2:sorted[sorted.count/2]
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        let report:[String:Any]=["format":"OSwind owned identity bootstrap scale component v1","state":"completed","rows":count,"startedAtUTC":ISO8601DateFormatter().string(from:started),"finishedAtUTC":ISO8601DateFormatter().string(from:Date()),"loadSeconds":loadSeconds,"bootstrapSeconds":bootstrapSeconds,"batchLimit":128,"keyByteLimit":1024*1024,"bootstrapBatches":batches,"batchMedianMS":median,"batchP95MS":sorted[min(sorted.count-1,Int(ceil(Double(sorted.count)*0.95))-1)],"originalTypedSHA256Before":before,"originalTypedSHA256After":after,"metadata":metadata,"incremental":incremental,"peakWholeProcessRSSBytes":usage.ru_maxrss,"scope":"Warm single-device identity metadata bootstrap and four real capture-to-catalog lifecycle intents over authored raw-SQL populated sources. Count/byte-bounded transactions and resumed completed cursor; exact original typed rows independently hashable. Not API ingestion, typed content/journal/transport throughput, live capture, cold cache, physical power or product ranking."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:base.appendingPathComponent("report.json"),options:.withoutOverwriting)
        print("IDENTITY_SCALE rows=\(count) bootstrapSeconds=\(bootstrapSeconds) batches=\(batches.count) sourceCellsUnchanged=1 lifecycle=4")
    }
}
