import XCTest
import CSQLite
import CryptoKit
import Darwin
@testable import OSwindCore

final class SyncCaptureScaleTests:XCTestCase {
    func testOwnedArchiveScaleAndIncrementalCost()throws {
        let env=ProcessInfo.processInfo.environment
        guard let count=env["OSWIND_TEST_SYNC_CAPTURE_SCALE_ROWS"].flatMap(Int.init),let path=env["OSWIND_TEST_SYNC_CAPTURE_SCALE_OUTPUT"] else {throw XCTSkip("Explicit owned archive scale fixture not requested")}
        guard (1000...1_000_000).contains(count) else {throw OSwindError.invalid("Invalid capture scale size")}
        let base=URL(fileURLWithPath:path,isDirectory:true),fm=FileManager.default
        guard !fm.fileExists(atPath:base.path) else {throw OSwindError.invalid("Capture scale output must be fresh")}
        var volume=statfs();guard statfs(base.deletingLastPathComponent().path,&volume)==0,UInt64(volume.f_bavail)*UInt64(volume.f_bsize)>5*1024*1024*1024 else {throw OSwindError.unavailable("Scale fixture requires five GiB free")}
        try fm.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try Data("OSwind authored capture scale fixture v1".utf8).write(to:base.appendingPathComponent("owned-fixture"),options:.withoutOverwriting)
        let library=base.appendingPathComponent("library"),store=try MemoryStore(root:library);defer {try? store.close()}
        let stamp=Date(timeIntervalSince1970:1_700_000_000),template=Memory(id:"template",timestamp:stamp,kind:.note,app:"Owned capture scale",title:"Scale record",text:"template")
        let data=try JSONEncoder().encode(template),started=ProcessInfo.processInfo.systemUptime
        try store.withRoutineDatabase {db in try db.transaction {
            let insert=try db.statement("""
            WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<?)
            INSERT INTO memories(id,timestamp,kind,app,title,url,text,favorite,payload)
            SELECT 'scale-'||x,1700000000,'note','Owned capture scale','Scale record',NULL,'Owned source '||x,0,
                   CAST(json_set(CAST(? AS TEXT),'$.id','scale-'||x,'$.text','Owned source '||x) AS BLOB) FROM n
            """);defer {sqlite3_finalize(insert)};sqlite3_bind_int(insert,1,Int32(count));data.withUnsafeBytes {_=sqlite3_bind_blob(insert,2,$0.baseAddress,Int32($0.count),db.transient)};try db.done(insert)
        }}
        let loadSeconds=ProcessInfo.processInfo.systemUptime-started
        func originalHash()throws->String {
            try store.withRoutineDatabase {db in
                let row=try db.statement("SELECT id,text FROM memories ORDER BY id COLLATE BINARY");defer {sqlite3_finalize(row)}
                var hash=SHA256(),rows=0,status=sqlite3_step(row)
                while status==SQLITE_ROW {
                    for column:Int32 in 0...1 {
                        let bytes=Int(sqlite3_column_bytes(row,column));guard let p=sqlite3_column_text(row,column) else {throw db.error()}
                        var length=UInt64(bytes).littleEndian;hash.update(data:withUnsafeBytes(of:&length){Data($0)});hash.update(data:Data(bytes:p,count:bytes))
                    }
                    rows+=1;status=sqlite3_step(row)
                }
                guard status==SQLITE_DONE,rows==count else {throw OSwindError.database("Scale source membership differs")}
                return hash.finalize().map {String(format:"%02x",$0)}.joined()
            }
        }
        let before=try originalHash(),scope=try store.withRoutineDatabase {try SyncChangeCapture.activate($0)}
        var mutations=["inactive":[Double](),"active":[Double]()],queries=mutations,requiredQueries=mutations,broadQueries=mutations
        func profile(_ name:String)throws {
            try store.withRoutineDatabase {try $0.execute("UPDATE personal_sync_capture SET enabled=\(name=="active" ? 1:0) WHERE singleton=1")}
        }
        // FULL and recursive trigger mode remain enabled for both controls.
        // Only internal capture is toggled. This is not a production pause/resume
        // protocol, matched competitor run, cold-cache or calibrated energy test.
        for round in 0..<10 {
            for name in (round.isMultiple(of:2) ? ["inactive","active"]:["active","inactive"]) {
                try profile(name)
                for item in 1...50 {
                    let id="scale-\(item+(name=="active" ? 50:0))",start=ProcessInfo.processInfo.systemUptime
                    try store.setFavorite(id,value:round.isMultiple(of:2));mutations[name]!.append((ProcessInfo.processInfo.systemUptime-start)*1000)
                }
                for item in 0..<5 {
                    let index=((round*5+item+1)*7919)%count+1
                    if round==0 {_=try store.search(.init(query:String(index),limit:5),mode:.keyword)}
                    let start=ProcessInfo.processInfo.systemUptime,hits=try store.search(.init(query:String(index),limit:5),mode:.keyword)
                    queries[name]!.append((ProcessInfo.processInfo.systemUptime-start)*1000)
                    var total=0,power=1
                    while index*power<=count {total+=min(count,(index+1)*power-1)-index*power+1;power*=10}
                    guard hits.first?.id=="scale-\(index)",hits.count==min(5,total),hits.allSatisfy({$0.id.dropFirst(6).hasPrefix(String(index))}) else {throw OSwindError.invalid("Default-prefix fixture results differ")}
                    let phrase="\""+String(index)+"\""
                    if round==0 {_=try store.search(.init(query:phrase,limit:5),mode:.keyword)}
                    let phraseStart=ProcessInfo.processInfo.systemUptime,exact=try store.search(.init(query:phrase,limit:5),mode:.keyword)
                    requiredQueries[name]!.append((ProcessInfo.processInfo.systemUptime-phraseStart)*1000)
                    guard exact.map(\.id)==["scale-\(index)"] else {throw OSwindError.invalid("Required-phrase fixture results differ")}
                }
                let broadStart=ProcessInfo.processInfo.systemUptime,broad=try store.search(.init(query:"\"Owned source\"",limit:100),mode:.keyword)
                broadQueries[name]!.append((ProcessInfo.processInfo.systemUptime-broadStart)*1000)
                guard broad.count==100,broad.allSatisfy({$0.id.hasPrefix("scale-") && $0.memory.text.hasPrefix("Owned source ")}) else {throw OSwindError.invalid("Broad archive query differs")}
            }
        }
        try profile("active");guard try store.stats().count==count else {throw OSwindError.invalid("Scale source count differs")}
        let after=try originalHash();guard before==after else {throw OSwindError.invalid("Original scale source text changed")}
        let capture=try store.withRoutineDatabase {db in
            (pending:try db.eraseCount("SELECT COUNT(*) FROM personal_sync_changes"),live:try db.eraseCount("SELECT COUNT(*) FROM personal_sync_changes WHERE after_row IS NOT NULL"),bytes:try db.eraseCount("SELECT used_bytes FROM personal_sync_capture"),invalid:try db.eraseCount("SELECT COUNT(*) FROM memories WHERE id<>'scale-'||CAST(substr(id,7) AS INTEGER) OR text<>'Owned source '||CAST(substr(id,7) AS INTEGER) OR CAST(substr(id,7) AS INTEGER) NOT BETWEEN 1 AND \(count)"))
        }
        guard capture.pending==500,capture.live==50,capture.invalid==0 else {throw OSwindError.invalid("Scale queue membership differs")}
        func summary(_ values:[Double])->[String:Any] {let sorted=values.sorted();return ["observations":values.count,"medianMS":sorted.count.isMultiple(of:2) ? (sorted[sorted.count/2-1]+sorted[sorted.count/2])/2:sorted[sorted.count/2],"p95MS":sorted[min(sorted.count-1,Int(ceil(Double(sorted.count)*0.95))-1)],"rawMS":values]}
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        let report:[String:Any]=["format":"OSwind owned canonical capture scale component v1","state":"completed","rows":count,"libraryPath":library.path,"loadSeconds":loadSeconds,"originalIDTextSHA256Before":before,"originalIDTextSHA256After":after,"mutations":mutations.mapValues(summary),"keywordPrefix":queries.mapValues(summary),"keywordRequiredPhrase":requiredQueries.mapValues(summary),"keywordBroad":broadQueries.mapValues(summary),"pendingIntents":capture.pending,"liveBodies":capture.live,"logicalQueueBytes":capture.bytes,"peakWholeProcessRSSBytes":usage.ru_maxrss,"scope":["One authored archive; original IDs/text independently hashable; no normal history or media/models.","Ten alternating control rounds, 500 per-profile real favorite transactions, 50 warm default-prefix and 50 warm required-phrase and ten 100-result all-source phrase queries; FULL/recursive mode held for both.","Current-format raw SQL builds the baseline with all ordinary source/index triggers. It is not measured API import, GPU, cold cache, capture completeness, full sync or competitive/physical energy evidence.","Fixture-only raw capture toggles do not constitute a delivered pause/resume workflow."]]
        try store.close()
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:base.appendingPathComponent("report.json"),options:.withoutOverwriting)
    }
}
