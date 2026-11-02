import XCTest
@testable import OSwindCore
@testable import OSwind

extension VaultSessionTests {
    func answerWorkLock(_ committed:Bool)async throws {
        try native();let package=root.appendingPathComponent("AnswerWork.oswindvault"),secret=UUID().uuidString
        _=try await LibraryVault.create(at:package,name:"Owned answer work",capacityGiB:1,passphrase:Data(secret.utf8))
        let session=AppSession(selection:.init(url:package,requiresExisting:true,origin:"owned-test"),defaults:defaults,locked:{false});try await finish(session)
        session.unlock(passphrase:secret,remember:false);try await finish(session);let model=try XCTUnwrap(session.model)
        model.settings.automaticMaintenance=false;model.settings.entityAutomaticIndex=false;model.settings.ai.provider = .evidence;model.settings.ai.allowRemote=false
        try await SourceWorkTestJob.settle(model);try model.store.insert(Memory(id:"keep",kind:.note,text:"The owned encrypted observatory launch is Thursday."))
        let gate=ImportWorkerGate();defer {gate.release()}
        let completion:(@Sendable ()->Void)?
        if committed {completion={try? gate.pause()}}else {completion=nil}
        model.ask("When is the observatory launch?",interpretation:false,observeWorker:{if !committed,$0 == .answerReady {try gate.pause()}},observeCompletion:completion)
        await fulfillment(of:[gate.entered],timeout:10);XCTAssertEqual(try model.store.chats().count,committed ? 1:0)
        session.requestLock();await fulfillment(of:[gate.cancelled],timeout:10)
        XCTAssertTrue(session.busy);XCTAssertNil(session.model);XCTAssertFalse(model.store.isClosed);XCTAssertTrue(model.hasPendingExitWork)
        let held=try await LibraryVault(package:package).status();XCTAssertTrue(held.imageAttached);XCTAssertTrue(held.volumeMounted)
        gate.release();try await finish(session)
        XCTAssertNil(session.failure);XCTAssertTrue(model.store.isClosed);XCTAssertFalse(model.hasPendingExitWork)
        XCTAssertNil(model.answer);XCTAssertNil(model.currentChatID);XCTAssertNil(model.answerStatus);XCTAssertNil(model.savedAnswerID)
        XCTAssertEqual(session.vaultStatus?.state,.locked);XCTAssertEqual(session.vaultStatus?.imageAttached,false)
        session.unlock(passphrase:secret,remember:false);try await finish(session)
        XCTAssertNil(session.failure);let current=try XCTUnwrap(session.model);let chats=try current.store.chats()
        XCTAssertEqual(chats.count,committed ? 1:0);XCTAssertNotNil(try current.store.get("keep"))
        if committed {XCTAssertEqual(try current.store.chatTurns(try XCTUnwrap(chats.first?.id)).count,1)}
        session.requestLock();try await finish(session);XCTAssertNil(session.failure);XCTAssertEqual(session.vaultStatus?.imageAttached,false)
    }
    func testNativeLockJoinsAnswerBeforeConversationAdmission()async throws {try await answerWorkLock(false)}
    func testNativeLockJoinsAnswerAfterActualCommittedTurn()async throws {try await answerWorkLock(true)}
}
