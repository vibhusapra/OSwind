import XCTest
@testable import OSwindCore
@testable import OSwind

@MainActor final class SourceWriteLifecycleTests:XCTestCase {
    var root:URL!,app:AppModel!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-source-write-"+UUID().uuidString)
        app=try AppModel(root:root,startServices:false)
        app.settings.captureOnLaunch=false;app.settings.apiEnabled=false;app.settings.automaticMaintenance=false
        app.settings.routinesEnabled=false;app.settings.entityAutomaticIndex=false;app.settings.search.visual.enabled=false
        try app.store.insert(Memory(id:"original",app:"Owned fixture",text:"An authored original for recap and note lifetime tests."))
    }
    override func tearDown()async throws {
        app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait();try app.store.close();app=nil
        try? FileManager.default.removeItem(at:root)
    }
    func testRetiredModelRejectsQueuedQuickNote()async throws {
        app.prepareForLibrarySwitch();app.addNote("An old view must not write this note",title:"Retired callback")
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while try app.store.stats(includeDiskUsage:false).count==1,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,1,"A retired view must not launch a note writer")
    }
    func testRetiredModelRejectsQueuedRecapSave()async throws {
        let source=try XCTUnwrap(app.store.get("original"))
        let answer=Answer(text:"An authored recap [1].",sources:[.init(memory:source,score:1,match:"owned")],provider:"owned",duration:0)
        app.prepareForLibrarySwitch();app.saveAnswer(answer)
        XCTAssertFalse(app.savingRecap,"A retired model cannot accept a new recap save")
        for _ in 0..<1000 where app.savingRecap {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,1)
        XCTAssertFalse(app.recapSaveStatus?.hasPrefix("Saved") ?? false)
    }
    func testRetiredModelRejectsQueuedJSONImport()async throws {
        let file=root.appendingPathComponent("owned-import.json")
        try JSONEncoder().encode([Memory(id:"late-import",app:"Owned fixture",text:"This retired import must not write")]).write(to:file)
        app.prepareForLibrarySwitch();app.importJSONFile(file)
        XCTAssertFalse(app.importingJSON,"A retired model cannot accept a new import")
        for _ in 0..<1000 where app.importingJSON {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertNil(try app.store.get("late-import"));XCTAssertFalse(app.importStatus.hasPrefix("Imported"))
    }
    func recap()throws->Answer {
        .init(text:"An authored recap [1].",sources:[.init(memory:try XCTUnwrap(app.store.get("original")),score:1,match:"owned")],provider:"owned",duration:0)
    }
    func start(_ recap:Bool,before:(@Sendable ()throws->Void)?=nil,after:(@Sendable ()->Void)?=nil)throws {
        if recap {app.saveAnswer(try self.recap(),observeWorker:before,observeCompletion:after)}
        else {app.addNote("Owned quick-note lifetime",observeWorker:before,observeCompletion:after)}
    }
    func drain(_ recap:Bool,cancelCaller:Bool=false)async throws {
        let gate=ImportWorkerGate();defer {gate.release()}
        try start(recap,before:{try gate.pause()});await fulfillment(of:[gate.entered],timeout:5)
        XCTAssertTrue(app.hasPendingExitWork,"The real writer must participate in exit ownership")
        app.prepareForLibrarySwitch();var finished=false
        let drain=Task {await self.app.cancelExternalWorkAndWait();finished=true}
        await fulfillment(of:[gate.cancelled],timeout:5);if cancelCaller {drain.cancel()}
        try await Task.sleep(for:.milliseconds(50));XCTAssertFalse(finished)
        gate.release();await drain.value;XCTAssertTrue(finished);XCTAssertFalse(app.hasPendingExitWork)
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,1)
    }
    func testNoteDrainJoinsActualWorkerBeforeSQL()async throws {try await drain(false)}
    func testRecapDrainJoinsActualWorkerBeforeSQL()async throws {try await drain(true)}
    func testCancelledNoteDrainCallerStillWaitsForActualWorker()async throws {try await drain(false,cancelCaller:true)}
    func testCancelledRecapDrainCallerStillWaitsForActualWorker()async throws {try await drain(true,cancelCaller:true)}
    func committed(_ recap:Bool,retired:Bool)async throws {
        let gate=ImportWorkerGate();defer {gate.release()}
        try start(recap,after:{try? gate.pause()});await fulfillment(of:[gate.entered],timeout:5)
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,2,"The actual insert already committed")
        let priorStatus=app.recapSaveStatus
        if retired {app.prepareForLibrarySwitch()}else {app.settings.privacy.retentionDays+=1}
        let drain=Task {await self.app.cancelExternalWorkAndWait()}
        await fulfillment(of:[gate.cancelled],timeout:5);gate.release();await drain.value
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,2,"Cancellation cannot roll back an actual committed source")
        XCTAssertFalse(app.hasPendingExitWork)
        if retired {XCTAssertEqual(app.recapSaveStatus,priorStatus)}
        else if recap {XCTAssertTrue(app.recapSaveStatus?.contains("committed") ?? false)}
    }
    func testRetiredNoteCompletionPreservesCommitWithoutLatePublication()async throws {try await committed(false,retired:true)}
    func testRetiredRecapCompletionPreservesCommitWithoutLatePublication()async throws {try await committed(true,retired:true)}
    func testCurrentNotePolicyCancellationPreservesActualCommit()async throws {try await committed(false,retired:false)}
    func testCurrentRecapPolicyCancellationReportsActualCommit()async throws {try await committed(true,retired:false)}
    func testPrivacyChangeCancelsBothActualUncommittedWriters()async throws {
        let note=ImportWorkerGate(),recap=ImportWorkerGate();defer {note.release();recap.release()}
        try start(false,before:{try note.pause()});try start(true,before:{try recap.pause()})
        await fulfillment(of:[note.entered,recap.entered],timeout:5)
        app.settings.privacy.retentionDays+=1
        await fulfillment(of:[note.cancelled,recap.cancelled],timeout:5)
        note.release();recap.release();await app.cancelExternalWorkAndWait()
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,1);XCTAssertFalse(app.hasPendingExitWork)
    }
    func testWipeWaitsForActualNoteWorkerAndCannotBeRepopulated()async throws {
        let gate=ImportWorkerGate();defer {gate.release()}
        try start(false,before:{try gate.pause()});await fulfillment(of:[gate.entered],timeout:5)
        app.wipeLocalLibrary();await fulfillment(of:[gate.cancelled],timeout:5)
        XCTAssertTrue(app.libraryWipe.busy);XCTAssertNil(app.libraryWipe.result)
        XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,1)
        gate.release()
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while app.libraryWipe.busy,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(app.libraryWipe.busy);XCTAssertEqual(try app.store.stats(includeDiskUsage:false).count,0)
        XCTAssertFalse(app.libraryWork.busy)
    }
    func testClosedModelRejectsBothWriteKinds()throws {
        let answer=try recap();try app.store.close()
        app.addNote("Must not start");app.saveAnswer(answer)
        XCTAssertFalse(app.libraryWork.busy);XCTAssertFalse(app.savingRecap)
    }
}
