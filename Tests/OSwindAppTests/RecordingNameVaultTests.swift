import XCTest
import CSQLite
@testable import OSwindCore
@testable import OSwind

private final class RecordingNameNativeGate:@unchecked Sendable {
    let gate=ImportWorkerGate()
    private let lock=NSLock()
    private var entered=false
    func once() {
        let first=lock.withLock {if entered {return false};entered=true;return true}
        if first {XCTAssertFalse(Thread.isMainThread);try? gate.pause()}
    }
}

extension VaultSessionTests {
    func testNativeRecordingNameReadIsJoinedBeforeVaultDetach()async throws {try await recordingNameLock(write:false)}
    func testNativeRecordingNameWriteIsJoinedAndCancelledBeforeVaultDetach()async throws {try await recordingNameLock(write:true)}
    private func recordingNameLock(write:Bool)async throws {
        try native();let package=root.appendingPathComponent("RecordingNames.oswindvault"),secret=UUID().uuidString
        _=try await LibraryVault.create(at:package,name:"Owned recording names",capacityGiB:1,passphrase:Data(secret.utf8))
        let session=AppSession(selection:.init(url:package,requiresExisting:true,origin:"owned-name-test"),defaults:defaults,locked:{false})
        try await finish(session);session.unlock(passphrase:secret,remember:false);try await finish(session)
        let model=try XCTUnwrap(session.model)
        model.settings.captureOnLaunch=false;model.settings.apiEnabled=false;model.settings.routinesEnabled=false;model.settings.entityAutomaticIndex=false;model.settings.automaticMaintenance=false;model.settings.clipboard.enabled=false;model.settings.meetings.enabled=false
        try model.settings.save(root:model.store.root);model.showOnboarding=false
        try await SourceWorkTestJob.settle(model)
        var audio=Memory(id:"owned-name-audio",kind:.audio,app:"Owned",title:"Original capture",text:"Authored transcript; no capture or ASR")
        audio.audioSessionID="owned-native-name-session";try model.store.insert(audio)
        let source=try XCTUnwrap(model.store.recordedMeetingPage().sources.first)
        if !write {_=try model.store.saveRecordedMeetingName("Owned saved name",for:source)}
        let archive=model.recordedMeetings,probe=RecordingNameNativeGate()
        // Owned lifecycle control only: the ambient desktop lock is not this
        // fixture's input. Real interactive/session-lock acceptance is separate.
        archive.allowed={[weak model] in guard let model else {return false};return model.libraryWorkAvailable && !model.showOnboarding && !model.libraryWipe.busy && !model.libraryTransfer.busy}
        guard archive.allowed() else {throw OSwindError.unavailable("Owned name fixture was not admitted before the worker gate")}
        defer {
            probe.gate.release()
            _ = try? model.store.withRoutineDatabase {db in sqlite3_trace_v2(db.handle,0,nil,nil);sqlite3_set_authorizer(db.handle,nil,nil)}
            withExtendedLifetime(probe) {}
        }
        if !write {
            try model.store.withRoutineDatabase {db in
                sqlite3_set_authorizer(db.handle,{context,action,table,column,_,_ in
                    if action==SQLITE_READ,let context,let table,let column,String(cString:table)=="memories",String(cString:column)=="payload" {
                        Unmanaged<RecordingNameNativeGate>.fromOpaque(context).takeUnretainedValue().once()
                    };return SQLITE_OK
                },Unmanaged.passUnretained(probe).toOpaque())
            }
        }
        archive.activate()
        if write {
            let end=SuspendingClock.now.advanced(by:.seconds(15))
            while archive.busy || archive.names.loading,SuspendingClock.now<end {try await Task.sleep(for:.milliseconds(5))}
            XCTAssertTrue(archive.names.loaded)
            try model.store.withRoutineDatabase {db in
                sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{_,context,_,sql in
                    if let context,let sql,String(cString:sql.assumingMemoryBound(to:CChar.self)).hasPrefix("INSERT INTO memories(") {
                        Unmanaged<RecordingNameNativeGate>.fromOpaque(context).takeUnretainedValue().once()
                    };return 0
                },Unmanaged.passUnretained(probe).toOpaque())
            }
            archive.names.beginEditing();archive.names.draft="Must roll back on lock";archive.names.saveEditor()
        }
        await fulfillment(of:[probe.gate.entered],timeout:10)
        session.requestLock();await fulfillment(of:[probe.gate.cancelled],timeout:10)
        XCTAssertTrue(session.busy);XCTAssertNil(session.model)
        XCTAssertTrue(archive.names.rows.isEmpty);XCTAssertNil(archive.names.editor);XCTAssertTrue(archive.names.draft.isEmpty)
        let held=try await LibraryVault(package:package).status();XCTAssertTrue(held.imageAttached);XCTAssertTrue(held.volumeMounted)
        probe.gate.release();try await finish(session)
        XCTAssertNil(session.failure);XCTAssertTrue(model.store.isClosed);XCTAssertEqual(session.vaultStatus?.imageAttached,false)
        session.unlock(passphrase:secret,remember:false);try await finish(session)
        let fresh=try XCTUnwrap(session.model);XCTAssertEqual(try fresh.store.get(audio.id),audio)
        let current=try XCTUnwrap(fresh.store.recordedMeetingPage().sources.first)
        XCTAssertEqual(try fresh.store.recordedMeetingDetails(for:current).map(\.name),write ? []:["Owned saved name"])
        session.requestLock();try await finish(session);XCTAssertEqual(session.vaultStatus?.imageAttached,false)
    }
}
