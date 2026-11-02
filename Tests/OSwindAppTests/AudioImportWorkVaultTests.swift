import XCTest
@testable import OSwindCore
@testable import OSwind

extension VaultSessionTests {
    func audioImportLock(_ committed:Bool)async throws {
        try native();let package=root.appendingPathComponent("AudioImport.oswindvault"),secret=UUID().uuidString,file=root.appendingPathComponent("authored.wav")
        let bytes=WAV.data(samples:Array(repeating:Float(0.05),count:16000));try bytes.write(to:file)
        _=try await LibraryVault.create(at:package,name:"Owned audio import",capacityGiB:1,passphrase:Data(secret.utf8))
        let session=AppSession(selection:.init(url:package,requiresExisting:true,origin:"owned-test"),defaults:defaults,locked:{false});try await finish(session)
        session.unlock(passphrase:secret,remember:false);try await finish(session);let model=try XCTUnwrap(session.model)
        model.settings.automaticMaintenance=false;model.settings.entityAutomaticIndex=false;model.settings.speech.engine = .parakeet
        model.settings.speech.modelDirectory="/synthetic/authored-decoder";model.settings.retainAudio=true
        try await SourceWorkTestJob.settle(model);try model.store.insert(Memory(id:"keep",kind:.note,text:"Owned independent encrypted original"))
        let gate=AudioImportGate(),backend=AuthoredImportBackend(gate:committed ? nil:gate),recognizer=SpeechRecognizer(loader:{_ in backend})
        defer {Task {await gate.open()}}
        let completion:(@Sendable ()async->Void)?
        if committed {completion={await gate.wait()}}else {completion=nil}
        model.importAudioFile(file,recognizer:recognizer,observeCompletion:completion)
        await fulfillment(of:[gate.entered],timeout:10);XCTAssertEqual(try model.store.stats(includeDiskUsage:false).count,committed ? 2:1)
        XCTAssertThrowsError(try MediaAdmissionLease.acquire(root:model.store.root,exclusive:true,timeout:0))
        let status=model.audioImportStatus;session.requestLock();await fulfillment(of:[gate.cancelled],timeout:10)
        XCTAssertTrue(session.busy);XCTAssertNil(session.model);XCTAssertFalse(model.store.isClosed);XCTAssertTrue(model.importingAudio)
        let held=try await LibraryVault(package:package).status();XCTAssertTrue(held.imageAttached);XCTAssertTrue(held.volumeMounted)
        await gate.open();try await finish(session)
        XCTAssertNil(session.failure);XCTAssertTrue(model.store.isClosed);XCTAssertFalse(model.hasPendingExitWork);XCTAssertFalse(model.importingAudio)
        XCTAssertEqual(model.audioImportStatus,status);XCTAssertEqual(session.vaultStatus?.state,.locked);XCTAssertEqual(session.vaultStatus?.imageAttached,false)
        session.unlock(passphrase:secret,remember:false);try await finish(session);XCTAssertNil(session.failure)
        let current=try XCTUnwrap(session.model);XCTAssertEqual(try current.store.stats(includeDiskUsage:false).count,committed ? 2:1);XCTAssertNotNil(try current.store.get("keep"))
        if committed {
            let source=try XCTUnwrap(current.store.search(SearchFilter(query:"",limit:10)).first(where:{$0.memory.kind == .audio})?.memory)
            XCTAssertNotNil(source.transcript);let retained=try XCTUnwrap(source.audioPath);XCTAssertEqual(try Data(contentsOf:current.store.root.appendingPathComponent(retained)),bytes)
        }
        session.requestLock();try await finish(session);XCTAssertNil(session.failure);XCTAssertEqual(session.vaultStatus?.imageAttached,false)
    }
    func testNativeLockJoinsActualDecoderAndClipBeforeAudioAdmission()async throws {try await audioImportLock(false)}
    func testNativeLockJoinsActualCommittedAudioImportAndRetainsItsBytes()async throws {try await audioImportLock(true)}
}
