import XCTest
import Foundation
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

final class SyncOriginalEvidenceCrashTests:XCTestCase {
    private enum OwnedError:Error {case invalid}
    private let group="00000000-0000-0000-0000-000000000911",epoch="00000000-0000-0000-0000-000000000912"
    func testDeathBeforeCommitPreservesBodyAndRollsBackProjection()throws {try crash("before")}
    func testDeathAfterCommitRetainsOriginalProjectionWithoutEcho()throws {try crash("after")}
    private func context(_ store:MemoryStore,_ replica:String)throws->(SyncVersionStore,SyncOriginalEvidenceStore) {
        try store.withRoutineDatabase {db in
            _=try SyncChangeCapture.activate(db);let c=try SyncIdentityCatalog.install(db),j=try SyncJournal.install(database:db,replica:replica,group:group,epoch:epoch),cache=try SyncVersionStore.install(catalog:c,journal:j)
            return(cache,try SyncOriginalEvidenceStore.install(cache:cache))
        }
    }
    private func crash(_ phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,root=fm.temporaryDirectory.appendingPathComponent("oswind-original-crash-"+nonce,isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:root)}
        try Data(nonce.utf8).write(to:root.appendingPathComponent("owner"),options:.withoutOverwriting);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:root.appendingPathComponent("owner").path)
        let log=root.appendingPathComponent("child.log"),gate=root.appendingPathComponent("ready"),child=Process()
        XCTAssertTrue(fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]));let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        let runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath();guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path) else {throw OwnedError.invalid}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.SyncOriginalEvidenceCrashTests/testCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_ORIGINAL_CRASH_ROOT":root.path,"OSWIND_ORIGINAL_CRASH_NONCE":nonce,"OSWIND_ORIGINAL_CRASH_PHASE":phase]
        for i in 0..<_dyld_image_count() {guard let name=_dyld_get_image_name(i) else {continue};let image=URL(fileURLWithPath:String(cString:name)).resolvingSymlinksInPath();if image.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=image.path}}
        child.environment=env;child.standardOutput=output;child.standardError=output;try child.run();defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let deadline=ProcessInfo.processInfo.systemUptime+30
        while child.isRunning && !fm.fileExists(atPath:gate.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:gate,encoding:.utf8))==phase else {XCTFail("Owned original worker missed gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing"));return}
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let store=try MemoryStore(root:root.appendingPathComponent("library"));defer {try? store.close()};let (cache,evidence)=try context(store,nonce.lowercased()),committed=phase=="after"
        let saved=try JSONDecoder().decode(SyncOriginalEvidenceReceipt.self,from:Data(contentsOf:root.appendingPathComponent("projection.json")))
        func n(_ table:String)throws->Int {let s=try cache.database.statement("SELECT COUNT(*) FROM "+table);defer {sqlite3_finalize(s)};guard sqlite3_step(s)==SQLITE_ROW else {throw cache.database.error()};return Int(sqlite3_column_int(s,0))}
        XCTAssertEqual(try n("memories"),1);XCTAssertEqual(try n("personal_sync_evidence"),committed ? 1:0);XCTAssertEqual(try n("personal_sync_versions"),1);XCTAssertEqual(try cache.journal.outbox().count,1);XCTAssertEqual(try n("personal_sync_changes"),0)
        if committed {XCTAssertEqual(try evidence.read(saved.handle,admit:{_ in},admitMedia:{_,_,_ in}).reference,saved.reference)}
        else {XCTAssertThrowsError(try evidence.read(saved.handle,admit:{_ in},admitMedia:{_,_,_ in}))}
        let recovered=try evidence.prepare(saved.reference,pathsFor:{_,_ in [:]},admit:{_ in},admitMedia:{_,_,_ in})
        if committed {XCTAssertEqual(recovered.handle,saved.handle)}else {XCTAssertNotEqual(recovered.handle,saved.handle)}
        XCTAssertEqual(recovered.memory.text,"Authored original crash evidence");XCTAssertEqual(try store.get("owned")?.text,recovered.memory.text);XCTAssertEqual(try n("personal_sync_evidence"),1);XCTAssertEqual(try cache.journal.outbox().count,1);XCTAssertEqual(try n("personal_sync_changes"),0)
        print("ORIGINAL_CRASH phase=\(phase) recoveredOriginal=1 canonical=1 noEcho=true")
    }
    private struct SyncOriginalEvidenceReceipt:Codable {let handle:String,reference:SyncVersionReference}
    func testCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment,fm=FileManager.default
        guard let path=env["OSWIND_ORIGINAL_CRASH_ROOT"],let nonce=env["OSWIND_ORIGINAL_CRASH_NONCE"],let phase=env["OSWIND_ORIGINAL_CRASH_PHASE"] else {throw XCTSkip("Only run as owned original-evidence crash child")}
        guard UUID(uuidString:nonce)?.uuidString==nonce,["before","after"].contains(phase) else {throw OwnedError.invalid}
        let root=URL(fileURLWithPath:path,isDirectory:true),expected=fm.temporaryDirectory.appendingPathComponent("oswind-original-crash-"+nonce,isDirectory:true)
        guard root.resolvingSymlinksInPath().standardizedFileURL==expected.resolvingSymlinksInPath().standardizedFileURL,try String(contentsOf:root.appendingPathComponent("owner"),encoding:.utf8)==nonce else {throw OwnedError.invalid}
        let store=try MemoryStore(root:root.appendingPathComponent("library"));try store.insert(Memory(id:"owned",timestamp:Date(timeIntervalSince1970:1700000000),kind:.note,text:"Authored original crash evidence"))
        let (cache,evidence)=try context(store,nonce.lowercased()),identity=try cache.catalog.registerExisting(.source,primary:[.text(Data("owned".utf8))]),record=try SyncPortableRecord(identity:identity,body:.source(.init(memory:XCTUnwrap(store.get("owned")),origin:identity.origin,media:[]){_,_ in throw OwnedError.invalid})),ref=try record.reference
        _=try cache.journal.put(key:identity.key,content:ref.content) {_ in _=try cache.retain(record,admit:{_ in})}
        func hold()throws {try Data(phase.utf8).write(to:root.appendingPathComponent("ready"),options:.atomic);Thread.sleep(forTimeInterval:60);XCTFail("Parent did not stop owned original worker")}
        try SyncChangeCapture.transaction(cache.database) {
            let original=try evidence.prepare(ref,pathsFor:{_,_ in [:]},admit:{_ in},admitMedia:{_,_,_ in});try SyncProtocolLimits.encode(SyncOriginalEvidenceReceipt(handle:original.handle,reference:ref)).write(to:root.appendingPathComponent("projection.json"),options:.atomic)
            if phase=="before" {try hold()}
        }
        if phase=="after" {try hold()};try store.close()
    }
}
