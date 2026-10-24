import XCTest
import CSQLite
import Darwin
@testable import OSwindCore

final class LibraryWorkspaceTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try Paths.ensure(root);store=try MemoryStore(root:root.appendingPathComponent("library"))}
    override func tearDownWithError() throws {store=nil;try? FileManager.default.removeItem(at:root)}
    func testAudioInputAndNormalizationStayInsideLibraryAndAreRemoved() throws {
        let input=root.appendingPathComponent("source.wav"),bytes=WAV.data(samples:[Float](repeating:0.1,count:16000));try bytes.write(to:input)
        var clip:AudioClipSnapshot?=try AudioClipSnapshot(source:input,store:store)
        let folder=clip!.file.deletingLastPathComponent();XCTAssertTrue(folder.path.hasPrefix(store.root.appendingPathComponent("audio/.staging").resolvingSymlinksInPath().path+"/"));XCTAssertEqual(clip!.duration,1,accuracy:0.001)
        XCTAssertEqual(try Data(contentsOf:clip!.file),bytes);XCTAssertTrue(FileManager.default.fileExists(atPath:clip!.speechFile.path));XCTAssertNotNil(clip!.mediaActivity)
        clip=nil;XCTAssertFalse(FileManager.default.fileExists(atPath:folder.path));XCTAssertEqual(try Data(contentsOf:input),bytes)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:store.root.appendingPathComponent("audio/.staging").resolvingSymlinksInPath().path).isEmpty)
    }
    func testEachBucketUsesPrivateOwnedStagingAndCleansOnlyItsPayload() throws {
        let outside=root.appendingPathComponent("keep");try Data([9]).write(to:outside)
        for bucket in [LibraryWorkspaceBucket.audio,.video] {
            var workspace:BackupWorkspace?=try store.libraryWorkspace("oswind-visual-recording",bucket:bucket);let path=workspace!.url
            XCTAssertTrue(path.path.hasPrefix(store.root.appendingPathComponent(bucket.rawValue+"/.staging").resolvingSymlinksInPath().path+"/"));try workspace!.tree.write(Data([1]),as:"private")
            let mode=try FileManager.default.attributesOfItem(atPath:path.path)[.posixPermissions] as! NSNumber;XCTAssertEqual(mode.intValue&0o077,0)
            workspace=nil;XCTAssertFalse(FileManager.default.fileExists(atPath:path.path))
        }
        XCTAssertEqual(try Data(contentsOf:outside),Data([9]))
    }
    func testCloseWaitsForWorkspaceWithoutBlockingReadsThenRejectsReuse() async throws {
        try store.insert(Memory(id:"original",text:"Keep this source"));var workspace:BackupWorkspace?=try store.libraryWorkspace("oswind-audio-chunk");XCTAssertNotNil(workspace)
        let local=store!,started=expectation(description:"close started"),done=expectation(description:"close completed");done.isInverted=true
        let worker=Task.detached {started.fulfill();try local.close();done.fulfill()}
        await fulfillment(of:[started],timeout:1);await fulfillment(of:[done],timeout:0.1);XCTAssertFalse(store.isClosed);XCTAssertEqual(try store.stats().count,1)
        workspace=nil;try await worker.value;XCTAssertTrue(store.isClosed);try store.close()
        XCTAssertThrowsError(try store.stats());XCTAssertThrowsError(try store.insert(Memory(text:"Cannot repopulate")));XCTAssertThrowsError(try store.mediaWriteLease());XCTAssertThrowsError(try store.libraryWorkspace("oswind-audio-chunk"));XCTAssertThrowsError(try store.checkpointSearchIndexIfIdle())
        let reopened=try MemoryStore(root:store.root);XCTAssertEqual(try reopened.stats().count,1);XCTAssertEqual(try reopened.get("original")?.text,"Keep this source");try reopened.close()
    }
    func testBusyStatementKeepsConnectionOpenForExplicitRetry() throws {
        try store.insert(Memory(text:"Preserved"));var statement:OpaquePointer?
        try store.withRoutineDatabase {db in XCTAssertEqual(sqlite3_prepare_v2(db.handle,"SELECT * FROM memories",-1,&statement,nil),SQLITE_OK)}
        defer {sqlite3_finalize(statement)}
        XCTAssertThrowsError(try store.close());XCTAssertFalse(store.isClosed);XCTAssertEqual(try store.stats().count,1)
        sqlite3_finalize(statement);statement=nil;try store.close();XCTAssertTrue(store.isClosed)
    }
    func testFullWipeWaitsForActiveStagingAndRemovesAbandonedPlaintext() async throws {
        try store.insert(Memory(text:"Old source"));var workspace:BackupWorkspace?=try store.libraryWorkspace("oswind-audio-import");let folder=workspace!.url;try workspace!.tree.write(Data([2]),as:"temporary.wav")
        let abandoned=store.root.appendingPathComponent("video/.staging/abandoned");try Paths.ensure(abandoned);try Data([3]).write(to:abandoned.appendingPathComponent("orphan.mov"))
        let local=store!,waiting=expectation(description:"wipe waiting"),done=expectation(description:"wipe done");done.isInverted=true
        let worker=Task.detached {let r=try local.wipeLibrary {if $0.phase=="Waiting for active media writers" {waiting.fulfill()}};done.fulfill();return r}
        await fulfillment(of:[waiting],timeout:1);await fulfillment(of:[done],timeout:0.1);XCTAssertTrue(FileManager.default.fileExists(atPath:folder.path));XCTAssertEqual(try store.stats().count,1)
        workspace=nil;let result=try await worker.value;XCTAssertTrue(result.cleanupComplete);XCTAssertEqual(result.erasure.sources,1);XCTAssertFalse(FileManager.default.fileExists(atPath:abandoned.path))
    }
    func testBudgetDoesNotDeleteHistoryToOffsetTemporaryWorkspaceCopies() throws {
        try store.insert(Memory(id:"keep",text:"A fresh source"));let budget=store.diskBytes()+1_000_000
        let workspace=try store.libraryWorkspace("oswind-backup-pins");defer {withExtendedLifetime(workspace){}}
        try workspace.tree.write(Data(repeating:1,count:8_000_000),as:"snapshot.sqlite")
        XCTAssertGreaterThan(store.diskBytes(),budget);XCTAssertLessThan(store.diskBytes(includeStaging:false),budget)
        let result=try store.pruneHistory(before:.distantPast,maxBytes:budget);XCTAssertEqual(result.erasure.sources,0);XCTAssertEqual(result.budgetMet,true);XCTAssertNotNil(try store.get("keep"));XCTAssertTrue(FileManager.default.fileExists(atPath:workspace.url.appendingPathComponent("snapshot.sqlite").path))
    }
    func testSymlinkStagingRefusesCreationAndPreservesOutsideFiles() throws {
        let outside=root.appendingPathComponent("outside");try Paths.ensure(outside);try Data([9]).write(to:outside.appendingPathComponent("keep"))
        try FileManager.default.createSymbolicLink(at:store.root.appendingPathComponent("audio/.staging"),withDestinationURL:outside)
        XCTAssertThrowsError(try store.libraryWorkspace("oswind-audio-import"));XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:outside.path),["keep"])
    }
    func testMovedLibraryCannotCreateScratchInReplacement() throws {
        let location=store.root;try FileManager.default.moveItem(at:location,to:root.appendingPathComponent("moved-library"));try Paths.ensure(location)
        XCTAssertThrowsError(try store.libraryWorkspace("oswind-audio-import"));XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:location.path).isEmpty)
        XCTAssertThrowsError(try store.close());XCTAssertFalse(store.isClosed)
    }
    func testWorkspaceParentIdentityRejectsReplacement() throws {
        let parent=root.appendingPathComponent("parent");try Paths.ensure(parent);let tree=try BackupFileTree(root:parent),identity=try tree.identity()
        try FileManager.default.moveItem(at:parent,to:root.appendingPathComponent("old-parent"));try Paths.ensure(parent)
        XCTAssertThrowsError(try BackupWorkspace(in:parent,label:"oswind-audio-import",parentIdentity:identity));XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:parent.path).isEmpty)
    }
    func testForeignAndReleasedBorrowedReservationsCannotAdmitAudio() throws {
        let file=root.appendingPathComponent("fixture.wav");try WAV.data(samples:[Float](repeating:0.1,count:16000)).write(to:file)
        let transcript=SpeechTranscript(text:"Fixture speech",duration:1,segments:[.init(start:0,end:1,text:"Fixture speech")],model:"fixture")
        var settings=AppSettings();settings.retainAudio=true
        let other=try MemoryStore(root:root.appendingPathComponent("other")),foreign=try other.mediaWriteLease();defer {foreign.release()}
        XCTAssertThrowsError(try AudioAdmission.save(transcript,file:file,store:store,settings:settings,timestamp:Date(),source:"fixture",admission:foreign))
        let released=try store.mediaWriteLease();released.release();XCTAssertThrowsError(try AudioAdmission.save(transcript,file:file,store:store,settings:settings,timestamp:Date(),source:"fixture",admission:released))
        XCTAssertEqual(try store.stats().count,0);XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:store.root.appendingPathComponent("audio").path).isEmpty)
    }
    func testBorrowedReservationKeepsAudioAdmissionInsideWorkspaceLifecycle() throws {
        let file=root.appendingPathComponent("fixture.wav");try WAV.data(samples:[Float](repeating:0.1,count:16000)).write(to:file)
        let clip=try AudioClipSnapshot(source:file,store:store);defer {withExtendedLifetime(clip){}}
        let transcript=SpeechTranscript(text:"Fixture speech",duration:1,segments:[.init(start:0,end:1,text:"Fixture speech")],model:"fixture");var settings=AppSettings();settings.retainAudio=true
        let memory=try AudioAdmission.save(transcript,file:clip.file,store:store,settings:settings,timestamp:Date(),source:"fixture",admission:clip.mediaActivity)
        XCTAssertNotNil(memory.audioPath);XCTAssertEqual(try store.stats().count,1);XCTAssertEqual(try Data(contentsOf:store.assetURL(memory.audioPath!)!),try Data(contentsOf:file))
    }
    func testWhisperOutputsUseGivenLibraryWorkspaceAndCleanOnSuccess() async throws {
        let workspace=try store.libraryWorkspace("oswind-audio-chunk");defer {withExtendedLifetime(workspace){}}
        let binary=root.appendingPathComponent("whisper-fixture"),model=root.appendingPathComponent("model"),observed=root.appendingPathComponent("observed-prefix")
        let script="""
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-of" ]; then out="$2"; shift 2; else shift; fi
        done
        printf '%s' "$out" > '\(observed.path)'
        printf '%s' '{"transcription":[{"offsets":{"from":0,"to":1000},"text":"Fixture speech"}]}' > "$out.json"
        """
        try Data(script.utf8).write(to:binary);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:binary.path);try Data([1]).write(to:model)
        let transcript=try await Whisper.detailed(file:root.appendingPathComponent("unused.wav"),binary:binary.path,model:model.path,workspaceParent:workspace.url)
        XCTAssertEqual(transcript.text,"Fixture speech");let prefix=try String(contentsOf:observed,encoding:.utf8)
        XCTAssertTrue(prefix.hasPrefix(workspace.url.path+"/"));XCTAssertFalse(FileManager.default.fileExists(atPath:URL(fileURLWithPath:prefix).deletingLastPathComponent().path));XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:workspace.url.path).isEmpty)
    }
    func testCancelledWhisperExitsBeforeReturningAndReleasingScratch() async throws {
        let workspace=try store.libraryWorkspace("oswind-audio-chunk");defer {withExtendedLifetime(workspace){}}
        let binary=root.appendingPathComponent("whisper-fixture"),model=root.appendingPathComponent("model"),pidfile=root.appendingPathComponent("owned.pid")
        let script="""
        #!/bin/sh
        printf '%s' "$$" > '\(pidfile.path)'
        trap '' TERM
        exec /bin/sleep 30
        """
        try Data(script.utf8).write(to:binary);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:binary.path);try Data([1]).write(to:model)
        let file=root.appendingPathComponent("unused.wav"),parent=workspace.url
        let worker=Task {try await Whisper.detailed(file:file,binary:binary.path,model:model.path,workspaceParent:parent)}
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while !FileManager.default.fileExists(atPath:pidfile.path),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertTrue(FileManager.default.fileExists(atPath:pidfile.path));worker.cancel()
        do {_=try await worker.value;XCTFail("Cancelled recognition succeeded")} catch is CancellationError {} catch {XCTFail("Unexpected \(error)")}
        let pid=try XCTUnwrap(Int32(String(contentsOf:pidfile,encoding:.utf8)));errno=0;XCTAssertEqual(kill(pid,0),-1);XCTAssertEqual(errno,ESRCH)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:workspace.url.path).isEmpty)
    }

}
