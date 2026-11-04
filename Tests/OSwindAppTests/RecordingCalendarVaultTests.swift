import XCTest
import CSQLite
@testable import OSwindCore
@testable import OSwind

private final class RecordingCalendarWriteGate:@unchecked Sendable {
    let gate=ImportWorkerGate();private let lock=NSLock();private var entered=false
    func once() {let first=lock.withLock {if entered {return false};entered=true;return true};if first {XCTAssertFalse(Thread.isMainThread);try? gate.pause()}}
}
extension VaultSessionTests {
    func testNativeRecordingCalendarReadRemainsJoinedBeforeVaultDetach()async throws {try await calendarLock(mode:0)}
    func testNativeRecordingCalendarWriteCancelsAndRollsBackBeforeVaultDetach()async throws {try await calendarLock(mode:1)}
    func testNativeRecordingCalendarIdleReviewValueDoesNotPinEncryptedImage()async throws {try await calendarLock(mode:2)}
    private func calendarLock(mode:Int)async throws {
        try native();let package=root.appendingPathComponent("Calendar.oswindvault"),secret=UUID().uuidString
        _=try await LibraryVault.create(at:package,name:"Owned calendar test",capacityGiB:1,passphrase:Data(secret.utf8))
        let provider=RecordingCalendarModelTests.Provider()
        let session=AppSession(selection:.init(url:package,requiresExisting:true,origin:"owned-calendar-test"),defaults:defaults,locked:{false},recordingCalendarProvider:provider.source())
        try await finish(session);session.unlock(passphrase:secret,remember:false);try await finish(session)
        let model=try XCTUnwrap(session.model)
        model.settings.captureOnLaunch=false;model.settings.apiEnabled=false;model.settings.routinesEnabled=false;model.settings.entityAutomaticIndex=false;model.settings.automaticMaintenance=false;model.settings.clipboard.enabled=false
        model.settings.meetings.enabled=true;model.settings.meetings.calendarIDs=["owned-calendar"];model.settings.meetings.boundLibrary=try model.store.authorizeMeetingLibrary()
        try model.settings.save(root:model.store.root);model.showOnboarding=false;try await SourceWorkTestJob.settle(model)
        var audio=Memory(id:"owned-calendar-audio",kind:.audio,app:"Owned",title:"Original capture",text:"Authored fixture; no audio or real Calendar provider");audio.audioSessionID="owned-calendar-session";try model.store.insert(audio)
        let source=try XCTUnwrap(model.store.recordedMeetingPage().sources.first),saved=try model.store.saveRecordedMeetingName("Owned name",for:source)
        provider.events=[try .init(calendarID:"owned-calendar",seriesID:"owned-occurrence",start:audio.timestamp,end:audio.timestamp.addingTimeInterval(1800),title:"Authored calendar fixture")]
        let archive=model.recordedMeetings
        archive.allowed={[weak model] in guard let model else {return false};return model.libraryWorkAvailable && !model.showOnboarding && !model.libraryWipe.busy && !model.libraryTransfer.busy}
        archive.activate()
        func settle()async throws {let end=ContinuousClock.now.advanced(by:.seconds(15));while model.libraryWork.busy,ContinuousClock.now<end {try await Task.sleep(for:.milliseconds(5))};XCTAssertFalse(model.libraryWork.busy)}
        try await settle();XCTAssertTrue(archive.names.loaded)
        let calendar=archive.names.calendar,heldValue=try model.store.recordedMeetingCalendarSelection(for:source,replacing:saved),readGate=MeetingsModelTests.Gate(),writeGate=RecordingCalendarWriteGate()
        if mode==0 {provider.state {$0.nextGate=readGate}}
        calendar.open()
        if mode==0 {await fulfillment(of:[readGate.entered],timeout:5)}else {try await settle();XCTAssertTrue(calendar.loaded)}
        defer {writeGate.gate.release();_ = try? model.store.withRoutineDatabase {sqlite3_trace_v2($0.handle,0,nil,nil)};withExtendedLifetime(writeGate) {}}
        if mode==1 {
            calendar.selectedID=calendar.events.first?.id
            try model.store.withRoutineDatabase {db in sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{_,context,_,sql in
                if let context,let sql,String(cString:sql.assumingMemoryBound(to:CChar.self)).hasPrefix("INSERT INTO memories(") {Unmanaged<RecordingCalendarWriteGate>.fromOpaque(context).takeUnretainedValue().once()};return 0
            },Unmanaged.passUnretained(writeGate).toOpaque())}
            calendar.save();await fulfillment(of:[writeGate.gate.entered],timeout:5)
        }
        session.requestLock()
        let end=ContinuousClock.now.advanced(by:.seconds(5));while session.model != nil,ContinuousClock.now<end {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertNil(session.model);XCTAssertFalse(calendar.presented);XCTAssertTrue(calendar.events.isEmpty)
        if mode<2 {
            XCTAssertTrue(session.busy);XCTAssertTrue(model.libraryWork.busy)
            let held=try await LibraryVault(package:package).status();XCTAssertTrue(held.imageAttached);XCTAssertTrue(held.volumeMounted)
        }
        if mode==0 {await readGate.open()}else {writeGate.gate.release()}
        try await finish(session);XCTAssertNil(session.failure);XCTAssertTrue(model.store.isClosed);XCTAssertEqual(session.vaultStatus?.imageAttached,false)
        withExtendedLifetime(heldValue) {}
        session.unlock(passphrase:secret,remember:false);try await finish(session);let fresh=try XCTUnwrap(session.model)
        XCTAssertEqual(try fresh.store.get(audio.id),audio);XCTAssertNil(try fresh.store.get(saved.id)?.recordingDetails?.calendar)
        session.requestLock();try await finish(session);XCTAssertEqual(session.vaultStatus?.imageAttached,false)
    }
}
