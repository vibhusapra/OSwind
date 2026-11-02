import XCTest
import CSQLite
@testable import OSwindCore

final class AudioSettingsAdmissionTests:XCTestCase {
    var root:URL!,file:URL!,store:MemoryStore!,config:AppSettings!
    let bytes=WAV.data(samples:Array(repeating:Float(0.05),count:16000))
    var transcript:SpeechTranscript {.init(text:"Owned authored audio admission fixture",duration:1,segments:[],model:"owned fake decoder")}
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-audio-settings-"+UUID().uuidString);try Paths.ensure(root)
        file=root.appendingPathComponent("input.wav");try bytes.write(to:file)
        store=try MemoryStore(root:root.appendingPathComponent("library"));config=AppSettings();config.retainAudio=true;try config.save(root:store.root)
    }
    override func tearDownWithError()throws {try store.close();store=nil;try? FileManager.default.removeItem(at:root)}
    func retainedFiles()throws->[URL] {
        let directory=store.root.appendingPathComponent("audio")
        guard let enumerator=FileManager.default.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey]) else {return []}
        return try enumerator.compactMap {$0 as? URL}.filter {try $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true}
    }
    func assertRejected(expectedSources:Int=0,retainedNames:Set<String>=[])throws {
        XCTAssertEqual(try store.stats(includeDiskUsage:false).count,expectedSources);XCTAssertEqual(Set(try retainedFiles().map(\.lastPathComponent)),retainedNames)
        XCTAssertEqual(try Data(contentsOf:file),bytes)
        let lease=try MediaAdmissionLease.acquire(root:store.root,exclusive:true,timeout:0);lease.release()
    }
    func testChangedSavedPolicyRejectsSourceAndRemovesOnlyNewRetainedCopy()throws {
        let snapshot=try LibrarySettingsSnapshot.capture(root:store.root);defer {snapshot.release()}
        var changed=config!;changed.privacy.redactSecrets.toggle();try changed.save(root:store.root)
        XCTAssertThrowsError(try AudioAdmission.save(transcript,file:file,store:store,settings:config,timestamp:Date(),source:"Owned audio",settingsSnapshot:snapshot))
        try assertRejected()
    }
    func testIdenticalAtomicSettingsSaveInvalidatesPinnedVersion()throws {
        let snapshot=try LibrarySettingsSnapshot.capture(root:store.root);defer {snapshot.release()};try config.save(root:store.root)
        XCTAssertThrowsError(try AudioAdmission.save(transcript,file:file,store:store,settings:config,timestamp:Date(),source:"Owned audio",settingsSnapshot:snapshot))
        try assertRejected()
    }
    func testCancellationDuringActualSourceInsertRollsBackFileAndSource()async throws {
        let store=self.store!,file=self.file!,config=self.config!,transcript=self.transcript,snapshot=try LibrarySettingsSnapshot.capture(root:store.root)
        let control=store.root.appendingPathComponent("audio/unrelated.wav");try Paths.ensure(control.deletingLastPathComponent());try bytes.write(to:control)
        try store.insert(Memory(id:"keep",kind:.audio,text:"Owned unrelated retained audio",audioPath:"audio/unrelated.wav"))
        defer {snapshot.release();try? store.withRoutineDatabase {sqlite3_trace_v2($0.handle,0,nil,nil)}}
        try store.withRoutineDatabase {db in
            sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{_,_,_,sql in
                if let sql,String(cString:sql.assumingMemoryBound(to:CChar.self)).hasPrefix("INSERT INTO memories(") {withUnsafeCurrentTask {$0?.cancel()}}
                return 0
            },nil)
        }
        let worker=Task.detached {try AudioAdmission.save(transcript,file:file,store:store,settings:config,timestamp:Date(),source:"Owned interrupted audio",settingsSnapshot:snapshot)}
        do {_ = try await worker.value;XCTFail("Cancelled configured audio committed")}
        catch is CancellationError {}catch {XCTFail("Expected cooperative cancellation")}
        try assertRejected(expectedSources:1,retainedNames:["unrelated.wav"]);XCTAssertEqual(try Data(contentsOf:control),bytes);XCTAssertNotNil(try store.get("keep"))
    }
    func testConfiguredAdmissionRefusesOuterTransactionAndPreservesCallerCommit()throws {
        let snapshot=try LibrarySettingsSnapshot.capture(root:store.root);defer {snapshot.release()}
        let unrelated=try store.withRoutineDatabase {db in try db.transaction {
            let chat=try store.createChat(title:"Owned unrelated explicit conversation")
            XCTAssertThrowsError(try AudioAdmission.save(transcript,file:file,store:store,settings:config,timestamp:Date(),source:"Owned rejected audio",settingsSnapshot:snapshot))
            return chat
        }}
        XCTAssertEqual(try store.chats().map(\.id),[unrelated.id]);try assertRejected()
    }
}
