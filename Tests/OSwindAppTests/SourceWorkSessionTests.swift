import XCTest
import AppKit
@testable import OSwindCore
@testable import OSwind

enum SourceWorkTestJob:CaseIterable {
    case note,recap,statistics,storage,answer,audioImport,selectedPII,sourceOpening,historicalValidation
    @MainActor func start(_ model:AppModel,gate:ImportWorkerGate,committed:Bool=false)throws {
        switch self {
        case .selectedPII:
            let store=model.store;model.selected=try XCTUnwrap(store.get("keep"))
            model.refreshSelectedPIIScan(read:{memory in try? gate.pause();return try store.piiScanStatus(memory.id,matching:memory)})
        case .sourceOpening:
            model.openMemory(try XCTUnwrap(model.store.get("keep")),query:"owned",observeRead:{try? gate.pause()})
        case .historicalValidation:
            let store=model.store,memory=try XCTUnwrap(store.get("keep")),origin="00000000-0000-0000-0000-000000004102"
            let body=try SyncSourceBody(memory:memory,origin:origin,media:[]){_,_ in throw OSwindError.invalid("No parent")}
            let record=try SyncPortableRecord(identity:.init(table:.source,origin:origin,lifetime:UUID().uuidString.lowercased()),body:.source(body))
            let original=try store.withRoutineDatabase {db in
                let history=HistoricalEvidenceStore(database:db),handle=UUID().uuidString.lowercased()
                try history.insert(handle:handle,source:memory.id,record:record,paths:[:],parents:[])
                return try history.read(handle,verifyMedia:{_,_,_ in}).memory
            }
            model.selected=original;model.watchSelectedOriginal(read:{memory in try? gate.pause();return try store.hydrate(memory)})
        case .note:
            if committed {model.addNote("Owned authored note",observeCompletion:{try? gate.pause()})}
            else {model.addNote("Owned authored note",observeWorker:{try gate.pause()})}
        case .recap:
            let source=try XCTUnwrap(model.store.get("keep"))
            let answer=Answer(text:"Owned source-linked recap [1].",sources:[.init(memory:source,score:1,match:"owned")],provider:"owned",duration:0)
            if committed {model.saveAnswer(answer,observeCompletion:{try? gate.pause()})}
            else {model.saveAnswer(answer,observeWorker:{try gate.pause()})}
        case .statistics:model.refreshStatistics(force:true,observeWorker:{try gate.pause()})
        case .storage:model.invalidateStorageEstimate();model.refreshStatistics(force:true,observeStorage:{try gate.pause()})
        case .answer:model.ask("Owned source",interpretation:false,observeWorker:{if $0 == .started {try gate.pause()}})
        case .audioImport:
            let file=model.store.root.appendingPathComponent("owned-import.wav");try WAV.data(samples:Array(repeating:Float(0.05),count:16000)).write(to:file)
            model.settings.speech.engine = .parakeet;model.settings.speech.modelDirectory="/synthetic/authored-decoder"
            let backend=AuthoredImportBackend(),recognizer=SpeechRecognizer(loader:{_ in backend})
            model.importAudioFile(file,recognizer:recognizer,observePhase:{if $0 == .started {try gate.pause()}})
        }
    }
    @MainActor static func settle(_ model:AppModel)async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while model.hasPendingStatistics || model.refreshing,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(model.hasPendingStatistics);XCTAssertFalse(model.refreshing)
    }
}

@MainActor final class SourceWorkSessionTests:XCTestCase {
    var root:URL!,session:AppSession!,defaults:UserDefaults!,suite:String!
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-source-work-session-"+UUID().uuidString);try Paths.ensure(root)
        let prepared=try MemoryStore(root:root);try prepared.close()
        var settings=AppSettings();settings.captureOnLaunch=false;settings.apiEnabled=false;settings.automaticMaintenance=false;settings.routinesEnabled=false;settings.entityAutomaticIndex=false
        try settings.save(root:root)
        suite="com.oswind.tests.source-work."+UUID().uuidString;defaults=UserDefaults(suiteName:suite)!
        session=AppSession(selection:.init(url:root,requiresExisting:true,origin:"owned-test"),defaults:defaults,locked:{false})
    }
    override func tearDown()async throws {
        if let model=session.model {model.prepareForLibrarySwitch();await model.cancelExternalWorkAndWait();try model.store.close();session.model=nil}
        session=nil;defaults.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)
    }
    func finish()async throws {
        let deadline=SuspendingClock.now.advanced(by:.seconds(30))
        while session.busy,SuspendingClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertFalse(session.busy);XCTAssertNil(session.failure)
    }
    func prepared()async throws->AppModel {
        try await finish();let model=try XCTUnwrap(session.model);try await SourceWorkTestJob.settle(model)
        try model.store.insert(Memory(id:"keep",text:"Owned source survives cancellation"));return model
    }
    func quit(_ kind:SourceWorkTestJob)async throws {
        let model=try await prepared(),gate=ImportWorkerGate();defer {gate.release()}
        try kind.start(model,gate:gate);await fulfillment(of:[gate.entered],timeout:5)
        let delegate=AppDelegate(),done=expectation(description:"Actual source work drained before Quit reply");var finished=false
        delegate.finishTermination={_ in finished=true;done.fulfill()}
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateCancel)
        await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertFalse(finished);XCTAssertTrue(model.hasPendingExitWork)
        gate.release();await fulfillment(of:[done],timeout:10)
        XCTAssertTrue(finished);XCTAssertFalse(model.hasPendingExitWork);XCTAssertEqual(try model.store.stats(includeDiskUsage:false).count,1)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared),.terminateNow)
    }
    func switched(_ kind:SourceWorkTestJob)async throws {
        let old=try await prepared(),gate=ImportWorkerGate();defer {gate.release()}
        let next=root.appendingPathComponent("next"),prepared=try MemoryStore(root:next);try prepared.close()
        try kind.start(old,gate:gate);await fulfillment(of:[gate.entered],timeout:5);session.open(next,persist:false)
        await fulfillment(of:[gate.cancelled],timeout:5)
        XCTAssertTrue(session.busy);XCTAssertNil(session.model);XCTAssertFalse(old.store.isClosed)
        gate.release();try await finish();XCTAssertTrue(old.store.isClosed);XCTAssertFalse(old.hasPendingExitWork)
        XCTAssertEqual(session.model?.store.root,next);XCTAssertEqual(try session.model?.store.stats(includeDiskUsage:false).count,0)
        let previous=try MemoryStore(root:root);defer {try? previous.close()};XCTAssertEqual(try previous.stats(includeDiskUsage:false).count,1)
    }
    func testPlainQuitWaitsForActualNoteWorker()async throws {try await quit(.note)}
    func testPlainQuitWaitsForActualRecapWorker()async throws {try await quit(.recap)}
    func testPlainQuitWaitsForActualStatisticsWorker()async throws {try await quit(.statistics)}
    func testPlainQuitWaitsForActualStorageWorker()async throws {try await quit(.storage)}
    func testLibrarySwitchWaitsForActualNoteWorker()async throws {try await switched(.note)}
    func testLibrarySwitchWaitsForActualRecapWorker()async throws {try await switched(.recap)}
    func testLibrarySwitchWaitsForActualStatisticsWorker()async throws {try await switched(.statistics)}
    func testLibrarySwitchWaitsForActualStorageWorker()async throws {try await switched(.storage)}
    func testPlainQuitWaitsForActualAnswerWorker()async throws {try await quit(.answer)}
    func testLibrarySwitchWaitsForActualAnswerWorker()async throws {try await switched(.answer)}
    func testPlainQuitWaitsForActualAudioImportWorker()async throws {try await quit(.audioImport)}
    func testLibrarySwitchWaitsForActualAudioImportWorker()async throws {try await switched(.audioImport)}
    func testPlainQuitWaitsForActualSelectedMetadataReader()async throws {try await quit(.selectedPII)}
    func testPlainQuitWaitsForActualSourceHydration()async throws {try await quit(.sourceOpening)}
    func testPlainQuitWaitsForActiveHistoricalValidation()async throws {try await quit(.historicalValidation)}
    func testLibrarySwitchWaitsForActualSelectedMetadataReader()async throws {try await switched(.selectedPII)}
    func testLibrarySwitchWaitsForActualSourceHydration()async throws {try await switched(.sourceOpening)}
    func testLibrarySwitchWaitsForActiveHistoricalValidation()async throws {try await switched(.historicalValidation)}
}
