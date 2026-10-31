import XCTest
import CSQLite
@testable import OSwindCore

/// Warm metadata erasure on synthetic archives, explicitly opt-in and retained.
final class HistoricalErasureScaleTests:XCTestCase {
    func testOwnedOriginalScopeAtBoundedScale()throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_HISTORICAL_ERASURE_SCALE_ROOT"] else {throw XCTSkip("Explicit owned original-scope scale fixture")}
        let root=URL(fileURLWithPath:path,isDirectory:true),fm=FileManager.default
        guard root.path==path,root.resolvingSymlinksInPath().path==path,root.standardizedFileURL.path==path,fm.fileExists(atPath:root.deletingLastPathComponent().path),!fm.fileExists(atPath:path) else {throw OSwindError.invalid("Scope scale root must be fresh, absolute and nonsymlink")}
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);try Data("OSwind authored historical erasure scale v1".utf8).write(to:root.appendingPathComponent("owned-fixture"),options:.withoutOverwriting)
        var reports=[[String:Any]]()
        for count in [1000,10000] {
            let base=root.appendingPathComponent("n\(count)");try Paths.ensure(base)
            let library=base.appendingPathComponent("library"),store=try MemoryStore(root:library);defer {try? store.close()}
            let owner=Memory(id:"current-owner",timestamp:Date(timeIntervalSince1970:1800000000),kind:.note,app:"Keep newer",title:"Newer owner",text:"Independent newer current body")
            try store.insert(owner)
            let identity=try SyncObjectIdentity(table:.source,origin:"00000000-0000-0000-0000-000000005201",lifetime:"00000000-0000-0000-0000-000000005202"),load=ProcessInfo.processInfo.systemUptime
            try store.withRoutineDatabase {db in try db.transaction {
                let archive=HistoricalEvidenceStore(database:db)
                for index in 0..<count {
                    try autoreleasepool {
                        let targeted=index%10==0,memory=Memory(id:owner.id,timestamp:Date(timeIntervalSince1970:1700000000+Double(index)),kind:index%2==0 ? .screen:.note,app:targeted ? "Target original":"Other original",bundleID:targeted ? "org.owned.target":"org.owned.other",title:"Original \(index)",url:targeted ? "https://target.example.test/\(index)":"https://keep.example.test/\(index)",text:"Owned archive source \(index) "+String(repeating:"x",count:1024))
                        let body=try SyncSourceBody(memory:memory,origin:identity.origin,media:[]) {_,_ in throw OSwindError.invalid("No scale recap")}
                        try archive.insert(handle:UUID().uuidString.lowercased(),source:owner.id,record:.init(identity:identity,body:.source(body)),paths:[:],parents:[])
                    }
                }
            }}
            let loadSeconds=ProcessInfo.processInfo.systemUptime-load
            try store.close();try fm.copyItem(at:library.appendingPathComponent("memory.sqlite"),to:base.appendingPathComponent("before.sqlite"))
            let measured=try MemoryStore(root:library);defer {try? measured.close()}
            let scopes:[(String,HistoryErasureScope,Int)]=[("app",.init(app:"Target original"),count/10),("domain",.init(domain:"target.example.test"),count/10),("time",.init(start:Date(timeIntervalSince1970:1700000000+Double(count-10)),end:Date(timeIntervalSince1970:1700000000+Double(count))),10),("kind",.init(kind:.screen),count/2)]
            var measurements=[[String:Any]]()
            for (name,scope,expected) in scopes {
                var times=[Double](),selected=[String]()
                for _ in 0..<7 {
                    let start=ProcessInfo.processInfo.systemUptime,p=try measured.previewErasure(scope);times.append(ProcessInfo.processInfo.systemUptime-start)
                    XCTAssertEqual(p.sources,0);XCTAssertEqual(p.historicalVersions,expected);XCTAssertEqual(p.matchedHistoricalVersions,expected)
                }
                try measured.withRoutineDatabase {db in
                    _=try db.prepareErasure(scope);defer {try? db.clearErasureSelection()}
                    let row=try db.statement("SELECT handle FROM temp.erasure_historical_ids ORDER BY handle");defer {sqlite3_finalize(row)};var code=sqlite3_step(row)
                    while code==SQLITE_ROW {selected.append(db.text(row,0));code=sqlite3_step(row)};XCTAssertEqual(code,SQLITE_DONE)
                }
                measurements.append(["scope":name,"seconds":times,"selectedHandles":selected])
            }
            let p=try measured.previewErasure(.init(app:"Target original")),start=ProcessInfo.processInfo.systemUptime,result=try measured.eraseHistory(p.scope,expectedToken:p.token),applySeconds=ProcessInfo.processInfo.systemUptime-start
            XCTAssertEqual(result.historicalVersions,count/10);XCTAssertEqual(result.sources,0);XCTAssertEqual(result.pendingMedia,0);XCTAssertEqual(try measured.get(owner.id),owner)
            try measured.close()
            let report:[String:Any]=["count":count,"librarySchema":MemoryStore.schemaVersion,"loadSeconds":loadSeconds,"measurements":measurements,"applySeconds":applySeconds,"deletedOriginals":result.historicalVersions,"scope":"Seven warm full previews per selector, including dependency closure, preview hashing and authenticated samples. One timed preview-token apply. Synthetic 1KiB text originals under one newer owner; no media, model, capture, disk pressure, cold cache, power, enrollment, transport or competitor ranking."]
            try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:base.appendingPathComponent("report.json"),options:.withoutOverwriting);reports.append(report)
            print("HISTORICAL_ERASURE_SCALE count=\(count) load=\(loadSeconds) apply=\(applySeconds)")
        }
        try JSONSerialization.data(withJSONObject:reports,options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent("report.json"),options:.withoutOverwriting)
    }
}
