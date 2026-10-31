import XCTest
import Foundation
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

/// Actual typed versions, projections, journal output and capture acknowledgement
/// commit together across owned-child death. Not physical-power or two-Mac proof.
final class SyncVersionCrashTests:XCTestCase {
    private enum FixtureError:Error {case invalidOwnership}
    private let group="00000000-0000-0000-0000-000000000731",epoch="00000000-0000-0000-0000-000000000732"
    func testProcessDeathBeforeCommitRollsBackTypedBodyAndLeavesIntent()throws {try crash(mode:"process",phase:"before")}
    func testProcessDeathAfterCommitRetainsTypedBodyAndAcknowledgement()throws {try crash(mode:"process",phase:"after")}
    func testBootstrapDeathBeforeCommitRollsBackTypedBodyAndCursor()throws {try crash(mode:"bootstrap",phase:"before")}
    func testBootstrapDeathAfterCommitResumesTypedBodiesWithoutDuplicates()throws {try crash(mode:"bootstrap",phase:"after")}
    private func originals(_ db:RoutineDatabase)throws->[Data] {
        let row=try db.statement("SELECT "+SyncCanonicalTable.source.schema.snapshot("t")+" FROM memories t ORDER BY id COLLATE BINARY");defer {sqlite3_finalize(row)};var frames=[Data](),code=sqlite3_step(row)
        while code==SQLITE_ROW {guard let p=sqlite3_column_blob(row,0) else {throw db.error()};frames.append(Data(bytes:p,count:Int(sqlite3_column_bytes(row,0))));code=sqlite3_step(row)};guard code==SQLITE_DONE else {throw db.error()};return frames
    }
    @discardableResult private func prepare(_ identity:SyncObjectIdentity,db:RoutineDatabase,journal:SyncJournal,cache:SyncVersionStore)throws->SyncVersionReference {
        let mapped=try XCTUnwrap(cache.catalog.object(identity)),primary=try XCTUnwrap(mapped.primary)
        let refs=SyncPortableReferences(identity:{table,key in guard table == .source,key==primary else {throw FixtureError.invalidOwnership};return identity},source:{_,_ in throw FixtureError.invalidOwnership},media:{_ in []},recipe:{_,_ in throw FixtureError.invalidOwnership},session:{_ in nil})
        guard case .text(let key)=primary[0] else {throw FixtureError.invalidOwnership}
        let row=try db.statement("SELECT "+SyncCanonicalTable.source.schema.snapshot("t")+" FROM memories t WHERE id IS ?");defer {sqlite3_finalize(row)};key.withUnsafeBytes {_ = sqlite3_bind_text64(row,1,$0.baseAddress?.assumingMemoryBound(to:CChar.self),UInt64(key.count),db.transient,UInt8(SQLITE_UTF8))}
        guard sqlite3_step(row)==SQLITE_ROW,let p=sqlite3_column_blob(row,0) else {throw db.error()};let packet=try SyncPortableExporter(references:refs).record(identity:identity,row:.decode(Data(bytes:p,count:Int(sqlite3_column_bytes(row,0))))),ref=try packet.reference
        _=try journal.put(key:identity.key,content:ref.content) {_ in _=try cache.retain(packet,admit:{_ in});try cache.bindProjection(ref,references:refs,admit:{_ in})};return ref
    }
    private func crash(mode:String,phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,root=fm.temporaryDirectory.appendingPathComponent("oswind-version-crash-"+nonce,isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:root)}
        try Data(nonce.utf8).write(to:root.appendingPathComponent("owner"),options:.withoutOverwriting);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:root.appendingPathComponent("owner").path)
        let child=Process(),log=root.appendingPathComponent("child.log"),gate=root.appendingPathComponent("ready")
        XCTAssertTrue(fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]));let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        let runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath();guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path) else {throw FixtureError.invalidOwnership}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.SyncVersionCrashTests/testCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_VERSION_CRASH_ROOT":root.path,"OSWIND_VERSION_CRASH_NONCE":nonce,"OSWIND_VERSION_CRASH_PHASE":phase,"OSWIND_VERSION_CRASH_MODE":mode]
        for i in 0..<_dyld_image_count() {guard let name=_dyld_get_image_name(i) else {continue};let path=URL(fileURLWithPath:String(cString:name)).resolvingSymlinksInPath();if path.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=path.path}}
        child.environment=env;child.standardOutput=output;child.standardError=output;try child.run();defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let deadline=ProcessInfo.processInfo.systemUptime+30
        while child.isRunning && !fm.fileExists(atPath:gate.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:gate,encoding:.utf8))==mode+"-"+phase else {XCTFail("Owned version worker did not reach gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing log"));return}
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let committed=phase=="after",store=try MemoryStore(root:root.appendingPathComponent("library"));defer {try? store.close()}
        let saved=try JSONDecoder().decode(SyncVersionReference.self,from:Data(contentsOf:root.appendingPathComponent("reference.json"))),frames=try JSONDecoder().decode([Data].self,from:Data(contentsOf:root.appendingPathComponent("originals.json")))
        try store.withRoutineDatabase {db in
            let c=try SyncIdentityCatalog.install(db),j=try SyncJournal.install(database:db,replica:nonce.lowercased(),group:group,epoch:epoch),cache=try SyncVersionStore.install(catalog:c,journal:j)
            func n(_ table:String)throws->Int {let row=try db.statement("SELECT COUNT(*) FROM "+table);defer {sqlite3_finalize(row)};guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return Int(sqlite3_column_int(row,0))}
            XCTAssertEqual(try originals(db),frames);XCTAssertEqual(try n("personal_sync_versions"),committed ? 1:0);XCTAssertEqual(try n("personal_sync_version_projection"),committed ? 1:0);XCTAssertEqual(try j.outbox().count,committed ? 1:0)
            if committed {XCTAssertNotNil(try cache.record(saved,admit:{_ in}))}else {XCTAssertThrowsError(try cache.record(saved,admit:{_ in}))}
            XCTAssertEqual(try SyncChangeCapture.changes(db,scope:c.scope).count,mode=="process" && !committed ? 1:0)
            if mode=="process" {
                XCTAssertEqual(try c.process {batch in for value in batch {_=try prepare(XCTUnwrap(value.after),db:db,journal:j,cache:cache)}},committed ? 0:1)
            }else {
                var resumed=0
                while try !c.bootstrap(.source,limit:1,consume:{batch in for value in batch {_=try prepare(value.identity,db:db,journal:j,cache:cache);resumed+=1}}).complete {}
                XCTAssertEqual(resumed,committed ? 1:2)
            }
            let expected=mode=="process" ? 1:2
            XCTAssertEqual(try n("personal_sync_versions"),expected);XCTAssertEqual(try n("personal_sync_version_projection"),expected);XCTAssertEqual(try j.outbox().count,expected);XCTAssertEqual(try originals(db),frames);XCTAssertTrue(try SyncChangeCapture.changes(db,scope:c.scope).isEmpty)
            print("VERSION_CRASH mode=\(mode) phase=\(phase) recoveredTypedBodies=\(expected) pending=0")
        }
    }
    func testCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment,fm=FileManager.default
        guard let path=env["OSWIND_VERSION_CRASH_ROOT"],let nonce=env["OSWIND_VERSION_CRASH_NONCE"],let phase=env["OSWIND_VERSION_CRASH_PHASE"],let mode=env["OSWIND_VERSION_CRASH_MODE"] else {throw XCTSkip("Only run as an owned typed-version crash child")}
        guard UUID(uuidString:nonce)?.uuidString==nonce,["before","after"].contains(phase),["process","bootstrap"].contains(mode) else {throw FixtureError.invalidOwnership}
        let root=URL(fileURLWithPath:path,isDirectory:true),expected=fm.temporaryDirectory.appendingPathComponent("oswind-version-crash-"+nonce,isDirectory:true)
        guard root.resolvingSymlinksInPath().standardizedFileURL==expected.resolvingSymlinksInPath().standardizedFileURL,try String(contentsOf:root.appendingPathComponent("owner"),encoding:.utf8)==nonce else {throw FixtureError.invalidOwnership}
        let store=try MemoryStore(root:root.appendingPathComponent("library"))
        if mode=="bootstrap" {for id in ["owned-a","owned-b"] {try store.insert(Memory(id:id,text:"Authored version crash body "+id))}}
        try store.withRoutineDatabase {db in
            _=try SyncChangeCapture.activate(db);let c=try SyncIdentityCatalog.install(db),j=try SyncJournal.install(database:db,replica:nonce.lowercased(),group:group,epoch:epoch),cache=try SyncVersionStore.install(catalog:c,journal:j)
            if mode=="process" {try store.insert(Memory(id:"owned-a",text:"Authored version crash body owned-a"))}
            try SyncProtocolLimits.encode(originals(db)).write(to:root.appendingPathComponent("originals.json"),options:.atomic)
            func hold()throws {try Data((mode+"-"+phase).utf8).write(to:root.appendingPathComponent("ready"),options:.atomic);Thread.sleep(forTimeInterval:60);XCTFail("Parent did not stop its owned version worker")}
            func consume(_ id:SyncObjectIdentity)throws {let ref=try prepare(id,db:db,journal:j,cache:cache);try SyncProtocolLimits.encode(ref).write(to:root.appendingPathComponent("reference.json"),options:.atomic)}
            if mode=="process" {try c.process {batch in for value in batch {try consume(XCTUnwrap(value.after))};if phase=="before" {try hold()}}}
            else {try c.bootstrap(.source,limit:1) {batch in for value in batch {try consume(value.identity)};if phase=="before" {try hold()}}}
            if phase=="after" {try hold()}
        };try store.close()
    }
}
