import XCTest
import AppKit
@testable import OSwindCore
@testable import OSwind

@MainActor final class RecordingNamesModelTests:XCTestCase {
    private var root:URL!,store:MemoryStore!,work:LibraryWorkRegistry!,models=[RecordingNamesModel]()
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-recording-names-"+UUID().uuidString)
        store=try MemoryStore(root:root);work=LibraryWorkRegistry()
    }
    override func tearDown()async throws {
        models.forEach {$0.clear()};await work.cancelAndWait();try store.close();try FileManager.default.removeItem(at:root)
    }
    @discardableResult private func audio(_ id:String="audio",session:String="session")throws->Memory {
        var value=Memory(id:id,timestamp:Date(timeIntervalSince1970:100),kind:.audio,app:"Owned",bundleID:"owned.names",title:"Original capture",text:"Authored transcript "+id)
        value.audioSessionID=session;try store.insert(value);return value
    }
    private func source(_ id:String="audio")throws->RecordedMeetingSource {try XCTUnwrap(store.recordedMeetingPage().sources.first {$0.memoryID==id})}
    private func select(_ model:RecordingNamesModel,_ id:String="audio")throws {model.select(try source(id),revision:try store.recordedMeetingRevision())}
    private func model()->RecordingNamesModel {
        let value=RecordingNamesModel(store:store,work:work);value.allowed={true};models.append(value);return value
    }
    private func settle(_ model:RecordingNamesModel)async throws {
        let end=SuspendingClock.now.advanced(by:.seconds(15))
        while model.loading || model.saving,SuspendingClock.now<end {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(model.loading);XCTAssertFalse(model.saving)
    }
    func testNameReadSaveAndRenameRunOffMainActorWithoutChangingAudio()async throws {
        let original=try audio()
        let value=RecordingNamesModel(store:store,work:work,read:{store,source in
            XCTAssertFalse(Thread.isMainThread);return try store.recordedMeetingDetails(for:source)
        },save:{store,name,source,expected in
            XCTAssertFalse(Thread.isMainThread);return try store.saveRecordedMeetingName(name,for:source,replacing:expected)
        });value.allowed={true};models.append(value);try select(value);try await settle(value)
        XCTAssertTrue(value.canEdit);value.beginEditing();value.draft="Design review";value.saveEditor();try await settle(value)
        XCTAssertNil(value.editor);XCTAssertEqual(value.rows.map(\.name),["Design review"])
        value.beginEditing();value.draft="Renamed review";value.saveEditor();try await settle(value)
        XCTAssertEqual(value.rows.map(\.name),["Renamed review"]);XCTAssertEqual(try store.get(original.id),original)
    }
    func testConcurrentRenamePreservesDraftUntilExplicitFreshReview()async throws {
        try audio();let target=try source(),saved=try store.saveRecordedMeetingName("First",for:target),value=model()
        try select(value);try await settle(value);value.beginEditing();value.draft="My draft"
        let fresh=try store.saveRecordedMeetingName("Another edit",for:target,replacing:saved)
        value.saveEditor();try await settle(value)
        XCTAssertNotNil(value.editorError);XCTAssertNotNil(value.editor);XCTAssertEqual(value.draft,"My draft");XCTAssertFalse(value.canSave)
        XCTAssertEqual(try store.recordedMeetingDetails(for:target),[fresh])
        value.reviewLatest();XCTAssertNil(value.editor);value.editorDismissed();try await settle(value)
        XCTAssertEqual(value.editor?.expected,fresh);XCTAssertEqual(value.draft,"My draft")
        value.saveEditor();try await settle(value);XCTAssertEqual(value.rows.map(\.name),["My draft"])
    }
    func testRefreshRequiresReviewBeforeSubmittingADraftAgainstChangedNames()async throws {
        try audio();let target=try source(),saved=try store.saveRecordedMeetingName("First",for:target),value=model()
        try select(value);try await settle(value);value.beginEditing();value.draft="Keep this draft"
        _=try store.saveRecordedMeetingName("Changed elsewhere",for:target,replacing:saved)
        try select(value);try await settle(value)
        XCTAssertEqual(value.draft,"Keep this draft");XCTAssertNotNil(value.editor);XCTAssertTrue(value.reviewRequired);XCTAssertFalse(value.canSave)
        XCTAssertEqual(try store.recordedMeetingDetails(for:target).first?.name,"Changed elsewhere")
        value.reviewLatest();value.editorDismissed();try await settle(value)
        XCTAssertFalse(value.reviewRequired);XCTAssertTrue(value.canSave);XCTAssertEqual(value.editor?.expected?.name,"Changed elsewhere")
    }
    func testConflictingDefinitionsRequireExplicitIndividualRemoval()async throws {
        let original=try audio(),target=try source(),saved=try store.saveRecordedMeetingName("One",for:target)
        var second=try XCTUnwrap(store.get(saved.id));second.id="other-definition";second.title="Two";try store.insert(second)
        let value=model();try select(value);try await settle(value)
        XCTAssertEqual(value.rows.count,2);XCTAssertFalse(value.canEdit);value.beginEditing();XCTAssertNil(value.editor)
        value.requestRemoval(saved);XCTAssertEqual(value.removal?.expected,saved)
        value.confirmRemoval();try await settle(value)
        XCTAssertEqual(value.rows.map(\.name),["Two"]);XCTAssertTrue(value.canEdit)
        XCTAssertEqual(try store.get(original.id),original);XCTAssertNil(try store.get(saved.id));XCTAssertNotNil(try store.get(second.id))
    }
    func testLateReadAfterClearStaysOwnedUntilWorkerActuallyExits()async throws {
        try audio();_=try store.saveRecordedMeetingName("Private authored name",for:source())
        let gate=ImportWorkerGate();defer {gate.release()}
        let value=RecordingNamesModel(store:store,work:work,read:{store,source in let rows=try store.recordedMeetingDetails(for:source);try gate.pause();return rows})
        value.allowed={true};models.append(value);try select(value);await fulfillment(of:[gate.entered],timeout:5)
        value.clear();var joined=false
        let draining=Task {await work.cancelAndWait();joined=true}
        await fulfillment(of:[gate.cancelled],timeout:5);XCTAssertFalse(joined)
        gate.release();await draining.value
        XCTAssertTrue(value.rows.isEmpty);XCTAssertFalse(value.loaded);XCTAssertNil(value.editor)
    }
    func testDepartureCancelsHeldNameWriteAndPreservesCapturedAudio()async throws {
        let original=try audio(),gate=ImportWorkerGate();defer {gate.release()}
        let value=RecordingNamesModel(store:store,work:work,save:{store,name,source,expected in try gate.pause();return try store.saveRecordedMeetingName(name,for:source,replacing:expected)})
        value.allowed={true};models.append(value);try select(value);try await settle(value)
        value.beginEditing();value.draft="Must not appear after departure";value.saveEditor();await fulfillment(of:[gate.entered],timeout:5)
        value.clear();let draining=Task {await work.cancelAndWait()};await fulfillment(of:[gate.cancelled],timeout:5)
        gate.release();await draining.value
        XCTAssertEqual(try store.get(original.id),original);XCTAssertTrue(try store.recordedMeetingDetails(for:source()).isEmpty)
        XCTAssertNil(value.editor);XCTAssertTrue(value.draft.isEmpty);XCTAssertTrue(value.rows.isEmpty)
    }
    func testPrivacyChangeDuringNameReadCannotPublishItsOldLabel()async throws {
        try audio();_=try store.saveRecordedMeetingName("Private name",for:source())
        let gate=ImportWorkerGate();defer {gate.release()}
        let value=RecordingNamesModel(store:store,work:work,read:{store,source in let rows=try store.recordedMeetingDetails(for:source);try gate.pause();return rows})
        value.allowed={true};models.append(value);try select(value);await fulfillment(of:[gate.entered],timeout:5)
        var settings=try AppSettings.load(root:root);settings.privacy.excludedApps.append("com.oswind.desktop");try settings.save(root:root)
        gate.release();try await settle(value)
        XCTAssertTrue(value.rows.isEmpty);XCTAssertFalse(value.loaded);XCTAssertNotNil(value.error);XCTAssertFalse(value.canEdit)
    }
    func testCancelledOldRemovalCannotResetANewRecordingWrite()async throws {
        try audio("first",session:"first");try audio("second",session:"second")
        let saved=try store.saveRecordedMeetingName("Keep first",for:source("first")),removeGate=ImportWorkerGate(),saveGate=ImportWorkerGate()
        defer {removeGate.release();saveGate.release()}
        let value=RecordingNamesModel(store:store,work:work,save:{store,name,source,expected in try saveGate.pause();return try store.saveRecordedMeetingName(name,for:source,replacing:expected)},remove:{store,name,source in try removeGate.pause();return try store.removeRecordedMeetingName(name,for:source)})
        value.allowed={true};models.append(value);try select(value,"first");try await settle(value)
        value.requestRemoval(saved);value.confirmRemoval();await fulfillment(of:[removeGate.entered],timeout:5)
        try select(value,"second")
        let readEnd=SuspendingClock.now.advanced(by:.seconds(10));while value.loading,SuspendingClock.now<readEnd {try await Task.sleep(for:.milliseconds(5))}
        value.beginEditing();value.draft="New second name";value.saveEditor();await fulfillment(of:[saveGate.entered],timeout:5)
        removeGate.release()
        let end=SuspendingClock.now.advanced(by:.seconds(10));while work.count(kinds:[.recordedMeetings])>1,SuspendingClock.now<end {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertTrue(value.saving);XCTAssertNotNil(value.editor)
        saveGate.release();try await settle(value)
        XCTAssertEqual(value.rows.map(\.name),["New second name"]);XCTAssertNotNil(try store.get(saved.id))
    }
}
