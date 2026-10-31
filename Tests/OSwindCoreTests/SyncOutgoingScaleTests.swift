import XCTest
import CSQLite
import CryptoKit
@testable import OSwindCore

/// Warm authored automatic outgoing text-source bootstrap and work processing.
/// No model, media, transport, real capture, energy or competitor measurement.
final class SyncOutgoingScaleTests:XCTestCase {
    func testOwnedOutgoingPreparationAtBoundedScale()throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_SYNC_OUTGOING_SCALE_OUTPUT"] else {throw XCTSkip("Explicit owned version preparation scale fixture")}
        let root=URL(fileURLWithPath:path,isDirectory:true),fm=FileManager.default
        guard root.path==path,root.resolvingSymlinksInPath().path==path,root.standardizedFileURL.path==path,fm.fileExists(atPath:root.deletingLastPathComponent().path),!fm.fileExists(atPath:path) else {throw OSwindError.invalid("Version fixture output must be a fresh absolute nonsymlink directory")}
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);try Data("OSwind authored outgoing preparation v1".utf8).write(to:root.appendingPathComponent("owned-fixture"),options:.withoutOverwriting)
        var results=[[String:Any]]()
        for count in [1000,10000] {
            let base=root.appendingPathComponent("n\(count)");try fm.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            let library=base.appendingPathComponent("library"),store=try MemoryStore(root:library);defer {try? store.close()}
            let template=Memory(id:"template",timestamp:Date(timeIntervalSince1970:1700000000),kind:.note,app:"Owned version scale",title:"Version source",text:"template"),data=try SyncProtocolLimits.encode(template),load=ProcessInfo.processInfo.systemUptime
            try store.withRoutineDatabase {db in try db.transaction {
                let row=try db.statement("""
                WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<?)
                INSERT INTO memories(id,timestamp,kind,app,title,url,text,favorite,payload)
                SELECT printf('version-%08d',x),1700000000,'note','Owned version scale','Version source',NULL,'Owned version source '||x,0,
                       CAST(json_set(CAST(? AS TEXT),'$.id',printf('version-%08d',x),'$.text','Owned version source '||x) AS BLOB) FROM n
                """);defer {sqlite3_finalize(row)};sqlite3_bind_int(row,1,Int32(count));data.withUnsafeBytes {_ = sqlite3_bind_blob(row,2,$0.baseAddress,Int32(data.count),db.transient)};try db.done(row)
            }}
            let loadSeconds=ProcessInfo.processInfo.systemUptime-load
            func hashOriginal()throws->String {
                try store.withRoutineDatabase {db in
                    let row=try db.statement("SELECT oswind_sync_row_v1(id,timestamp,kind,app,title,url,text,favorite,payload,embedding,embedding_model) FROM memories ORDER BY id COLLATE BINARY");defer {sqlite3_finalize(row)};var hash=SHA256(),rows=0,code=sqlite3_step(row)
                    while code==SQLITE_ROW {let n=Int(sqlite3_column_bytes(row,0));guard let p=sqlite3_column_blob(row,0) else {throw db.error()};var size=UInt64(n).littleEndian;withUnsafeBytes(of:&size){hash.update(data:Data($0))};hash.update(data:Data(bytes:p,count:n));rows+=1;code=sqlite3_step(row)}
                    guard code==SQLITE_DONE,rows==count else {throw OSwindError.invalid("Version source membership changed")};return hash.finalize().map {String(format:"%02x",$0)}.joined()
                }
            }
            let original=try hashOriginal(),setup=ProcessInfo.processInfo.systemUptime
            let (catalog,journal,cache)=try store.withRoutineDatabase {db -> (SyncIdentityCatalog,SyncJournal,SyncVersionStore) in
                _=try SyncChangeCapture.activate(db);let catalog=try SyncIdentityCatalog.install(db),journal=try SyncJournal.install(database:db,replica:"00000000-0000-0000-0000-000000000711",group:"00000000-0000-0000-0000-000000000712",epoch:"00000000-0000-0000-0000-000000000713")
                return (catalog,journal,try SyncVersionStore.install(catalog:catalog,journal:journal,budget:1024*1024*1024))
            }
            let setupSeconds=ProcessInfo.processInfo.systemUptime-setup
            let queue=try SyncOutgoingWorkQueue.install(catalog:catalog)
            let processor=SyncOutgoingProcessor(queue:queue,cache:cache,admitRow:{_,_ in},admitVersion:{_ in},media:{_ in []})
            var batches=[[String:Any]](),steps=[[String:Any]](),seen=0,complete=false
            let prepare=ProcessInfo.processInfo.systemUptime
            while !complete {
                let start=ProcessInfo.processInfo.systemUptime,result=try processor.step(limit:128),seconds=ProcessInfo.processInfo.systemUptime-start
                switch result {
                case .prepared(let objects):batches.append(["objects":objects,"seconds":seconds]);seen+=objects;steps.append(["kind":"prepared","objects":objects,"seconds":seconds])
                case .bootstrapped(let table,let objects):steps.append(["kind":"bootstrap","table":table.rawValue,"objects":objects,"seconds":seconds])
                case .captured:throw OSwindError.invalid("Bootstrap fixture unexpectedly captured an edit")
                case .idle:steps.append(["kind":"idle","objects":0,"seconds":seconds]);complete=true
                }
            }
            let prepareSeconds=ProcessInfo.processInfo.systemUptime-prepare;XCTAssertEqual(seen,count);XCTAssertEqual(try hashOriginal(),original)
            let metadata=try store.withRoutineDatabase {db -> [String:Int64] in
                var values=[String:Int64]()
                for (name,sql) in ["versions":"SELECT COUNT(*) FROM personal_sync_versions","projections":"SELECT COUNT(*) FROM personal_sync_version_projection","outbox":"SELECT COUNT(*) FROM personal_sync_outbox","usedBytes":"SELECT used_bytes FROM personal_sync_version_state"] {let row=try db.statement(sql);defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};values[name]=sqlite3_column_int64(row,0)};return values
            }
            for name in ["versions","projections","outbox"] {XCTAssertEqual(metadata[name],Int64(count))}
            try store.close()
            let report:[String:Any]=["librarySchema":Int(MemoryStore.schemaVersion),"count":count,"sourceOriginalSHA256":original,"loadSeconds":loadSeconds,"setupSeconds":setupSeconds,"prepareSeconds":prepareSeconds,"batchLimit":128,"batches":batches,"steps":steps,"metadata":metadata,"scope":"One warm authored text-source run; timer includes bounded automatic identity bootstrap, opaque work staging, dependency identity checks, actual canonical row read, typed export, journal, cache/projection and work acknowledgement across all 13 bootstrap cursors. Raw SQL population, setup, source checks, models, media and transport excluded. Not sustained capture, physical power or competitor evidence."]
            try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:base.appendingPathComponent("report.json"),options:.withoutOverwriting);results.append(report)
            print("OUTGOING_PREPARE count=\(count) seconds=\(prepareSeconds)")
        }
        try JSONSerialization.data(withJSONObject:results,options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent("report.json"),options:.withoutOverwriting)
    }
}
