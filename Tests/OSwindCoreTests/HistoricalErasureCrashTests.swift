import XCTest
import Foundation
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

/// SIGKILL at SQLite's precommit and postcommit hooks; no production crash gate.
final class HistoricalErasureCrashTests:XCTestCase {
    private final class Gate {
        let root:URL,phase:String
        init(_ root:URL,_ phase:String) {self.root=root;self.phase=phase}
        func hold()->Int32 {
            do {try Data(phase.utf8).write(to:root.appendingPathComponent("ready"),options:.atomic)}
            catch {return 1}
            Thread.sleep(forTimeInterval:45)
            return 1
        }
    }
    func testDeathBeforeCommitRetainsOriginalsRecapTurnsAndMedia()throws {try crash("before")}
    func testDeathAfterCommitRetainsDeletionAndDurableMediaQueue()throws {try crash("after")}
    private func crash(_ phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,root=fm.temporaryDirectory.appendingPathComponent("oswind-historical-erasure-crash-"+nonce,isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:root)}
        try Data(nonce.utf8).write(to:root.appendingPathComponent("owner"),options:.withoutOverwriting)
        let log=root.appendingPathComponent("child.log"),child=Process()
        XCTAssertTrue(fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]));let out=try FileHandle(forWritingTo:log);defer {try? out.close()}
        let runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath()
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path) else {throw OSwindError.invalid("Owned XCTest runner required")}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.HistoricalErasureCrashTests/testCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_HISTORY_ERASURE_CRASH_ROOT":root.path,"OSWIND_HISTORY_ERASURE_CRASH_NONCE":nonce,"OSWIND_HISTORY_ERASURE_CRASH_PHASE":phase]
        for i in 0..<_dyld_image_count() {guard let raw=_dyld_get_image_name(i) else {continue};let image=URL(fileURLWithPath:String(cString:raw)).resolvingSymlinksInPath();if image.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=image.path}}
        child.environment=env;child.standardOutput=out;child.standardError=out;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let gate=root.appendingPathComponent("ready"),deadline=ProcessInfo.processInfo.systemUptime+30
        while child.isRunning && !fm.fileExists(atPath:gate.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:gate,encoding:.utf8))==phase else {XCTFail("Owned erasure worker missed gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing log"));return}
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let library=root.appendingPathComponent("library"),committed=phase=="after"
        let media=library.appendingPathComponent("images/crash-original.bin"),bytes=Data("Owned historical media awaiting cleanup".utf8)
        XCTAssertEqual(try Data(contentsOf:media),bytes)
        // Inspect recovered WAL state before MemoryStore's startup cleanup.
        guard let resolved=realpath(library.appendingPathComponent("memory.sqlite").path,nil) else {throw OSwindError.invalid("Owned database missing")};defer {free(resolved)}
        var raw:OpaquePointer?;XCTAssertEqual(sqlite3_open_v2(resolved,&raw,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX|SQLITE_OPEN_NOFOLLOW,nil),SQLITE_OK)
        let inspection=RoutineDatabase(handle:try XCTUnwrap(raw))
        do {
            XCTAssertEqual(try inspection.eraseCount("SELECT count(*) FROM erasure_assets"),committed ? 1:0)
            XCTAssertEqual(try inspection.eraseCount("SELECT count(*) FROM historical_evidence"),committed ? 1:3)
            XCTAssertEqual(try inspection.eraseCount("SELECT count(*) FROM historical_scope_revoked_versions"),committed ? 2:0)
        } catch {sqlite3_close(raw);throw error};XCTAssertEqual(sqlite3_close(raw),SQLITE_OK)
        let store=try MemoryStore(root:library);defer {try? store.close()}
        XCTAssertEqual(try store.get("source")?.text,"Newer independent current body")
        XCTAssertEqual(try store.get("linked-recap") == nil,committed)
        try store.withRoutineDatabase {db in
            for (table,before,after) in [("historical_evidence",3,1),("chat_turns",1,0),("chat_sources",1,0),("recap_sources",1,0),("erasure_assets",0,0)] {
                XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM "+table),committed ? after:before,table)
            }
            XCTAssertEqual(try db.eraseCount("SELECT used_bytes FROM historical_evidence_state"),try db.eraseCount("SELECT coalesce(sum(256+length(body)+length(paths)+length(parents)+128*json_array_length(CAST(parents AS TEXT))),0) FROM historical_evidence"))
            let check=try db.statement("PRAGMA foreign_key_check");defer {sqlite3_finalize(check)};XCTAssertEqual(sqlite3_step(check),SQLITE_DONE)
        }
        let handles=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:root.appendingPathComponent("handles.json")))
        XCTAssertEqual(try store.historicalMemory(XCTUnwrap(handles["sibling"])).app,"Keep original")
        if committed {XCTAssertThrowsError(try store.historicalMemory(XCTUnwrap(handles["media"])))}
        else {XCTAssertEqual(try store.historicalMemory(XCTUnwrap(handles["media"])).app,"Safari")}
        if !committed {XCTAssertEqual(try Data(contentsOf:media),bytes)}
        if !committed {let p=try store.previewErasure(.init(app:"Safari"));XCTAssertEqual(p.historicalVersions,2);_=try store.eraseHistory(p.scope,expectedToken:p.token)}
        else {let cleanup=store.retryErasureCleanup();XCTAssertEqual(cleanup.removedMedia,0);XCTAssertEqual(cleanup.pendingMedia,0)}
        XCTAssertFalse(fm.fileExists(atPath:media.path));XCTAssertEqual(try store.get("source")?.text,"Newer independent current body")
        try store.withRoutineDatabase {db in XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM historical_evidence"),1);XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM erasure_assets"),0)}
        print("HISTORICAL_ERASURE_CRASH phase=\(phase) newerOwner=1 sibling=1 mediaCleanupRecovered=true")
    }
    func testCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment,fm=FileManager.default
        guard let path=env["OSWIND_HISTORY_ERASURE_CRASH_ROOT"],let nonce=env["OSWIND_HISTORY_ERASURE_CRASH_NONCE"],let phase=env["OSWIND_HISTORY_ERASURE_CRASH_PHASE"] else {throw XCTSkip("Only run as owned historical erasure crash child")}
        guard UUID(uuidString:nonce)?.uuidString==nonce,["before","after"].contains(phase) else {throw OSwindError.invalid("Invalid owned crash scope")}
        let root=URL(fileURLWithPath:path,isDirectory:true),expected=fm.temporaryDirectory.appendingPathComponent("oswind-historical-erasure-crash-"+nonce,isDirectory:true)
        guard root.resolvingSymlinksInPath().standardizedFileURL==expected.resolvingSymlinksInPath().standardizedFileURL,try String(contentsOf:root.appendingPathComponent("owner"),encoding:.utf8)==nonce else {throw OSwindError.invalid("Invalid owned crash marker")}
        let fixture=try XCTUnwrap(Bundle.module.url(forResource:"original-scope-schema26",withExtension:"sqlite",subdirectory:"HistoricalErasureMigration")),library=root.appendingPathComponent("library")
        try Paths.ensure(library);try fm.copyItem(at:fixture,to:library.appendingPathComponent("memory.sqlite"))
        let store=try MemoryStore(root:library),bytes=Data("Owned historical media awaiting cleanup".utf8),media="images/crash-original.bin"
        try bytes.write(to:library.appendingPathComponent(media))
        var handles=[String:String]()
        try store.withRoutineDatabase {db in
            let archive=HistoricalEvidenceStore(database:db),old=try db.statement("SELECT handle FROM historical_evidence LIMIT 1");guard sqlite3_step(old)==SQLITE_ROW else {sqlite3_finalize(old);throw db.error()};let original=try archive.read(db.text(old,0),verifyMedia:{_,_,_ in});sqlite3_finalize(old)
            for (key,app) in [("media","Safari"),("sibling","Keep original")] {
                let hasMedia=key=="media",memory=Memory(id:"source",timestamp:Date(timeIntervalSince1970:150),kind:.screen,app:app,text:"Owned "+key,imagePath:hasMedia ? media:nil)
                let ref=try SyncContentReference(data:bytes),manifest=SyncMediaManifest(role:.image,sha256:ref.sha256,bytes:Int64(bytes.count),chunks:[ref])
                let body=try SyncSourceBody(memory:memory,origin:original.record.identity.origin,media:hasMedia ? [manifest]:[]) {_,_ in throw OSwindError.invalid("No recap")}
                let record=try SyncPortableRecord(identity:original.record.identity,body:.source(body)),handle=UUID().uuidString.lowercased()
                try archive.insert(handle:handle,source:"source",record:record,paths:hasMedia ? [.image:media]:[:],parents:[]);handles[key]=handle
            }
        }
        try SyncProtocolLimits.encode(handles).write(to:root.appendingPathComponent("handles.json"),options:.atomic)
        let preview=try store.previewErasure(.init(app:"Safari"));XCTAssertEqual(preview.historicalVersions,2)
        let gate=Gate(root,phase),pointer=Unmanaged.passUnretained(gate).toOpaque()
        try store.withRoutineDatabase {db -> Void in
            if phase=="before" {_ = sqlite3_commit_hook(db.handle,{raw in guard let raw else {return 1};return Unmanaged<Gate>.fromOpaque(raw).takeUnretainedValue().hold()},pointer)}
            else {_ = sqlite3_wal_hook(db.handle,{raw,_,_,_ in guard let raw else {return 1};return Unmanaged<Gate>.fromOpaque(raw).takeUnretainedValue().hold()},pointer)}
        }
        try withExtendedLifetime(gate) {XCTAssertThrowsError(try store.eraseHistory(preview.scope,expectedToken:preview.token),"Parent must kill this worker at its exact commit hook")}
        try store.close()
    }
}
