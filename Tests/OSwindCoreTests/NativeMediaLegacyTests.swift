import XCTest
import CSQLite
import CryptoKit
import Darwin
@testable import OSwindCore

final class NativeMediaLegacyTests:XCTestCase {
    func testInitializedPrior32CannotDrainMediaReservedByCurrentSnapshot() throws {try checkLegacy(forceOldDirty:false)}
    func testInitializedPrior32QueueReadFenceProtectsMediaEvenWithLegacyDirtyMarker() throws {try checkLegacy(forceOldDirty:true)}
    private func checkLegacy(forceOldDirty:Bool) throws {
        guard let supplied=ProcessInfo.processInfo.environment["OSWIND_TEST_PUBLICATION_OLD32_CLI"] else {throw XCTSkip("Requires the exact frozen prior32 CLI")}
        let executable=URL(fileURLWithPath:supplied).resolvingSymlinksInPath(),expected="ce600b7d4c74eaaba65db61050b9b369a05352a9fe80c145e7a438448e01e6e2"
        func hash()throws->String {SHA256.hash(data:try Data(contentsOf:executable)).map {String(format:"%02x",$0)}.joined()}
        guard FileManager.default.isExecutableFile(atPath:executable.path),try hash()==expected else {throw OSwindError.invalid("Use the exact qualified prior32 executable")}
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("owned-legacy-media-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:root)}
        // Bootstrap with the real prior binary before the current client opens
        // or migrates this library. The fixture callback names stay inactive.
        func run(_ arguments:[String])throws->String {
            let process=Process(),out=Pipe(),err=Pipe();process.executableURL=executable;process.arguments=arguments;process.standardOutput=out;process.standardError=err
            var ordinary=ProcessInfo.processInfo.environment;ordinary.removeValue(forKey:"DYLD_INSERT_LIBRARIES");process.environment=ordinary
            try process.run();let data=out.fileHandleForReading.readDataToEndOfFile(),errors=err.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            guard process.terminationStatus==0 else {throw OSwindError.invalid("Owned legacy setup failed: "+String(decoding:errors,as:UTF8.self))};return String(decoding:data,as:UTF8.self)
        }
        let id=try run(["--data",root.path,"note","Owned source evidence"]).trimmingCharacters(in:.whitespacesAndNewlines)
        let image=root.appendingPathComponent("images/owned.png")
        let pixels=try XCTUnwrap(Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aM3sAAAAASUVORK5CYII="));try pixels.write(to:image)
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script="""
        import json,sqlite3,sys
        sys.path.insert(0,sys.argv[3])
        from owned_sqlite_fixture import register_inactive_sync_fixture
        c=sqlite3.connect(sys.argv[1]+'/memory.sqlite');register_inactive_sync_fixture(c)
        assert c.execute('PRAGMA user_version').fetchone()==(32,)
        p=json.loads(c.execute('SELECT payload FROM memories WHERE id=?',(sys.argv[2],)).fetchone()[0])
        p['kind']='screen';p['imagePath']='images/owned.png'
        c.execute("UPDATE memories SET kind='screen',payload=? WHERE id=?",(json.dumps(p).encode(),sys.argv[2]));c.commit();c.close()
        """
        let prepare=Process(),preparedErrors=Pipe();prepare.executableURL=URL(fileURLWithPath:"/usr/bin/env");prepare.arguments=["python3","-c",script,root.path,id,repo.appendingPathComponent("scripts").path];prepare.standardOutput=FileHandle.nullDevice;prepare.standardError=preparedErrors
        try prepare.run();let prepareText=preparedErrors.fileHandleForReading.readDataToEndOfFile();prepare.waitUntilExit();XCTAssertEqual(prepare.terminationStatus,0,String(decoding:prepareText,as:UTF8.self))
        let chatObject=try JSONSerialization.jsonObject(with:Data(run(["--data",root.path,"chat","new"]).utf8)) as? [String:Any]
        let chatID=try XCTUnwrap(chatObject?["id"] as? String)
        let turnObject=try JSONSerialization.jsonObject(with:Data(run(["--data",root.path,"chat","ask",chatID,"--provider","evidence","Owned source evidence"]).utf8)) as? [String:Any]
        let turnID=try XCTUnwrap(turnObject?["id"] as? String)
        let savedObject=try JSONSerialization.jsonObject(with:Data(run(["--data",root.path,"chat","save-recap",chatID,"--turn",turnID]).utf8)) as? [String:Any]
        let recapID=try XCTUnwrap(savedObject?["id"] as? String)
        let child=Process(),input=Pipe(),log=root.appendingPathComponent("legacy.log")
        XCTAssertTrue(fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]))
        let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        child.executableURL=executable;child.arguments=["--data",root.path,"collect","--stdin"];child.standardInput=input;child.standardOutput=output;child.standardError=output
        var env=ProcessInfo.processInfo.environment;env.removeValue(forKey:"DYLD_INSERT_LIBRARIES");child.environment=env
        try child.run();defer {try? input.fileHandleForWriting.close();if child.isRunning {child.terminate();Thread.sleep(forTimeInterval:0.05);if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)}};child.waitUntilExit()}
        let lock=root.appendingPathComponent(".media-admission.lock").resolvingSymlinksInPath(),deadline=ProcessInfo.processInfo.systemUptime+20
        var postOpen=false
        while child.isRunning && ProcessInfo.processInfo.systemUptime<deadline {
            let observe=Process(),bytes=Pipe();observe.executableURL=URL(fileURLWithPath:"/usr/sbin/lsof");observe.arguments=["-a","-p",String(child.processIdentifier),"-Ffln"];observe.standardOutput=bytes;observe.standardError=FileHandle.nullDevice;observe.environment=env
            try observe.run();let data=bytes.fileHandleForReading.readDataToEndOfFile();observe.waitUntilExit()
            let fdObserved=String(decoding:data,as:UTF8.self).split(separator:"\n").contains {line in line.hasPrefix("n") && URL(fileURLWithPath:String(line.dropFirst())).resolvingSymlinksInPath()==lock}
            if fdObserved {
                let fd=Darwin.open(lock.path,O_RDWR|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else {throw OSwindError.invalid("Cannot inspect owned media lock")};defer {Darwin.close(fd)}
                if flock(fd,LOCK_EX|LOCK_NB)==0 {_=flock(fd,LOCK_UN)}
                else if errno==EWOULDBLOCK || errno==EAGAIN,flock(fd,LOCK_SH|LOCK_NB)==0 {postOpen=true;_=flock(fd,LOCK_UN)}
            }
            if postOpen {break};Thread.sleep(forTimeInterval:0.02)
        }
        guard postOpen,child.isRunning else {return XCTFail("Legacy collector did not reach its real post-open shared lease: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing log"))}
        let store=try MemoryStore(root:root),memory=try XCTUnwrap(store.get(id))
        let cache=root.appendingPathComponent(NativeMediaSchema.cacheDirectory+"/owned");try Paths.ensure(cache.deletingLastPathComponent());try Data("owned disposable cache".utf8).write(to:cache)
        let snapshot=try XCTUnwrap(VisualImageSnapshot.make(store:store,id:memory.id));defer {snapshot.release()}
        let deleted=try store.delete(memory.id)
        XCTAssertEqual(deleted.sources,2);XCTAssertEqual(deleted.pendingMedia,1);XCTAssertEqual(deleted.removedMedia,0)
        XCTAssertNil(try store.get(memory.id));XCTAssertNil(try store.get(recapID));XCTAssertEqual(try Data(contentsOf:image),pixels)
        if forceOldDirty {try store.withRoutineDatabase {try $0.execute("INSERT INTO store_metadata(key,value) VALUES('recap_cache_dirty','1') ON CONFLICT(key) DO UPDATE SET value='1'")}}
        let batch:[String:Any]=["format":"OSwind collector batch","version":1,"collectorID":"org.oswind.legacy-media-fixture","records":[["key":"unrelated","timestamp":"2026-10-31T11:00:00Z","text":"Owned unrelated legacy note","app":"Owned","bundleID":"org.oswind.legacy-media-fixture","title":"Owned note"]]]
        try input.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:batch));try input.fileHandleForWriting.close()
        let finish=ProcessInfo.processInfo.systemUptime+25
        while child.isRunning && ProcessInfo.processInfo.systemUptime<finish {Thread.sleep(forTimeInterval:0.01)}
        guard !child.isRunning else {return XCTFail("Owned legacy writer did not finish")};child.waitUntilExit()
        let outcome=try String(contentsOf:log,encoding:.utf8)
        print("NATIVE_LEGACY_MEDIA initializedBeforeUpgrade=true sourceSchema=32 currentSchema=\(MemoryStore.schemaVersion) forcedLegacyDirty=\(forceOldDirty) status=\(child.terminationStatus) mediaReserved=true")
        if child.terminationStatus==0 {XCTAssertEqual(try store.stats().count,1);XCTAssertTrue(outcome.contains("imported"))}
        else {XCTAssertFalse(outcome.isEmpty);XCTAssertEqual(try store.stats().count,0)}
        XCTAssertTrue(fm.fileExists(atPath:image.path),"An unrelated legacy insert must not unlink media held by a current snapshot")
        XCTAssertTrue(fm.fileExists(atPath:cache.path),"Legacy invalidation must not remove a currently reserved cache")
        XCTAssertEqual(try store.withRoutineDatabase {try $0.eraseCount("SELECT count(*) FROM erasure_assets")},1)
        XCTAssertThrowsError(try snapshot.validatedMemory(),"An erased source must still refuse result admission")
        XCTAssertEqual(try hash(),expected)
        snapshot.release();XCTAssertEqual(store.retryErasureCleanup().pendingMedia,0)
    }
}
