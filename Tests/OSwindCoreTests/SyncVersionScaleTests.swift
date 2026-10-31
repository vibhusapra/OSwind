import XCTest
import CSQLite
import CryptoKit
@testable import OSwindCore

/// Warm authored text-source bootstrap, codec, journal and cache projection.
/// No model, media, transport, real capture, energy or competitor measurement.
final class SyncVersionScaleTests:XCTestCase {
    func testOwnedVersionPreparationAtBoundedScale()throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_SYNC_VERSION_SCALE_OUTPUT"] else {throw XCTSkip("Explicit owned version preparation scale fixture")}
        let root=URL(fileURLWithPath:path,isDirectory:true),fm=FileManager.default
        guard root.path==path,root.resolvingSymlinksInPath().path==path,root.standardizedFileURL.path==path,fm.fileExists(atPath:root.deletingLastPathComponent().path),!fm.fileExists(atPath:path) else {throw OSwindError.invalid("Version fixture output must be a fresh absolute nonsymlink directory")}
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);try Data("OSwind authored version preparation v1".utf8).write(to:root.appendingPathComponent("owned-fixture"),options:.withoutOverwriting)
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
            var active:SyncBootstrapObject?
            let refs=SyncPortableReferences(identity:{table,primary in
                guard let active,table == .source,active.primary==primary else {throw OSwindError.invalid("Version fixture identity differs")};return active.identity
            },source:{_,_ in throw OSwindError.invalid("No source dependency expected")},media:{_ in []},recipe:{_,_ in throw OSwindError.invalid("No recipe dependency expected")},session:{_ in nil})
            var batches=[[String:Any]](),seen=0,complete=false
            let prepare=ProcessInfo.processInfo.systemUptime
            while !complete {
                let start=ProcessInfo.processInfo.systemUptime
                let result=try store.withRoutineDatabase {db in try catalog.bootstrap(.source,limit:128) {batch in
                    for object in batch {
                        active=object
                        guard case .text(let key)=object.primary[0] else {throw OSwindError.invalid("Version fixture primary differs")}
                        let row=try db.statement("SELECT "+SyncCanonicalTable.source.schema.snapshot("t")+" FROM memories t WHERE id IS ?");defer {sqlite3_finalize(row)}
                        key.withUnsafeBytes {_ = sqlite3_bind_text64(row,1,$0.baseAddress?.assumingMemoryBound(to:CChar.self),UInt64(key.count),db.transient,UInt8(SQLITE_UTF8))}
                        guard sqlite3_step(row)==SQLITE_ROW,let p=sqlite3_column_blob(row,0) else {throw db.error()};let snapshot=try SyncRowSnapshot.decode(Data(bytes:p,count:Int(sqlite3_column_bytes(row,0))))
                        let record=try SyncPortableExporter(references:refs).record(identity:object.identity,row:snapshot),reference=try record.reference
                        _=try journal.put(key:object.identity.key,content:reference.content) {_ in
                            _=try cache.retain(record,admit:{_ in});try cache.bindProjection(reference,references:refs,admit:{_ in})
                        };seen+=1
                    }
                }}
                batches.append(["objects":result.objects,"seconds":ProcessInfo.processInfo.systemUptime-start]);complete=result.complete
            }
            let prepareSeconds=ProcessInfo.processInfo.systemUptime-prepare;XCTAssertEqual(seen,count);XCTAssertEqual(try hashOriginal(),original)
            let metadata=try store.withRoutineDatabase {db -> [String:Int64] in
                var values=[String:Int64]()
                for (name,sql) in ["versions":"SELECT COUNT(*) FROM personal_sync_versions","projections":"SELECT COUNT(*) FROM personal_sync_version_projection","outbox":"SELECT COUNT(*) FROM personal_sync_outbox","usedBytes":"SELECT used_bytes FROM personal_sync_version_state"] {let row=try db.statement(sql);defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};values[name]=sqlite3_column_int64(row,0)};return values
            }
            for name in ["versions","projections","outbox"] {XCTAssertEqual(metadata[name],Int64(count))}
            try store.close()
            let report:[String:Any]=["librarySchema":Int(MemoryStore.schemaVersion),"count":count,"sourceOriginalSHA256":original,"loadSeconds":loadSeconds,"setupSeconds":setupSeconds,"prepareSeconds":prepareSeconds,"batchLimit":128,"batches":batches,"metadata":metadata,"scope":"One warm authored text-source run; timer includes bounded identity bootstrap, actual canonical row read, typed export, journal and version/projection transactions. Raw SQL population, setup, source checks, models, media and transport excluded. Not sustained capture, physical power or competitor evidence."]
            try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:base.appendingPathComponent("report.json"),options:.withoutOverwriting);results.append(report)
            print("VERSION_PREPARE count=\(count) seconds=\(prepareSeconds)")
        }
        try JSONSerialization.data(withJSONObject:results,options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent("report.json"),options:.withoutOverwriting)
    }
}
