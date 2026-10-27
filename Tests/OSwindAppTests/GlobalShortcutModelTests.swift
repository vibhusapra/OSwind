import XCTest
import Carbon
@testable import OSwind

@MainActor final class GlobalShortcutModelTests:XCTestCase {
    final class Calls {
        var installStatus:OSStatus=0,registerStatus:OSStatus=0,unregisterStatus:OSStatus=0,removeStatus:OSStatus=0
        var giveHandler=true,giveKey=true
        var events=[String](),ids=[UInt32]()
        var system:ShortcutCarbonCalls {
            .init(install:{reference in self.events.append("install");if self.giveHandler {reference=EventHandlerRef(bitPattern:1)};return self.installStatus},register:{identifier,reference in self.events.append("register");self.ids.append(identifier.id);XCTAssertEqual(identifier.signature,0x4f53574e);if self.giveKey {reference=EventHotKeyRef(bitPattern:2)};return self.registerStatus},unregister:{_ in self.events.append("unregister");return self.unregisterStatus},remove:{_ in self.events.append("remove");return self.removeStatus})
        }
    }
    func make(_ calls:Calls)->GlobalShortcutModel {GlobalShortcutModel(driver:NativeShortcutRegistration(calls:calls.system))}
    func testMatchingCurrentTicketOnlyRoutesExplicitShortcut() {
        let calls=Calls(),model=make(calls);var hits=0
        model.configure {hits+=1};XCTAssertEqual(model.state,.registered);XCTAssertEqual(calls.events,["install","register"])
        model.receive(signature:0,id:1);model.receive(signature:0x4f53574e,id:2);XCTAssertEqual(hits,0)
        model.receive(signature:0x4f53574e,id:1);XCTAssertEqual(hits,1)
        XCTAssertTrue(model.message.contains("registered with macOS"));model.stop()
    }
    func testHandlerFailureDoesNotAdoptAnErrorOutParameter() {
        let calls=Calls();calls.installStatus = -50
        let model=make(calls);model.configure {XCTFail("Failed registration routed an event")}
        XCTAssertEqual(model.state,.unavailable);XCTAssertEqual(calls.events,["install"]);XCTAssertTrue(model.diagnostic.contains("-50"))
        XCTAssertFalse(model.keyConflict)
        model.receive(signature:0x4f53574e,id:1);model.stop()
    }
    func testKeyConflictIsVisibleWithoutUnregisteringAnErrorOutParameter() {
        let calls=Calls();calls.registerStatus = -9878
        let model=make(calls);model.configure {XCTFail("Conflicted key routed an event")}
        XCTAssertEqual(model.state,.unavailable);XCTAssertEqual(calls.events,["install","register","remove"])
        XCTAssertTrue(model.keyConflict);XCTAssertTrue(model.message.contains("already in use"))
        XCTAssertTrue(model.diagnostic.contains("-9878"));XCTAssertTrue(model.message.contains("Dock or menu bar"));model.stop()
    }
    func testMissingNativeHandlesNeverCountAsSuccess() {
        for handlerMissing in [true,false] {
            let calls=Calls();calls.giveHandler = !handlerMissing;calls.giveKey=handlerMissing
            let model=make(calls);model.configure {XCTFail("Missing native handle routed an event")}
            XCTAssertEqual(model.state,.unavailable);model.receive(signature:0x4f53574e,id:1);model.stop()
        }
    }
    func testRetryAfterConflictUsesFreshTicketAndDropsQueuedOldEvent() {
        let calls=Calls();calls.registerStatus = -9878;calls.giveKey=false
        let model=make(calls);var hits=0;model.configure {hits+=1}
        calls.registerStatus=0;calls.giveKey=true;model.retry()
        XCTAssertEqual(model.state,.registered);XCTAssertEqual(calls.ids,[1,2]);XCTAssertTrue(model.diagnostic.isEmpty)
        XCTAssertFalse(model.keyConflict)
        model.receive(signature:0x4f53574e,id:1);XCTAssertEqual(hits,0)
        model.receive(signature:0x4f53574e,id:2);XCTAssertEqual(hits,1);model.stop()
    }
    func testFailedKeyCleanupRetainsResourcesAndDoesNotInstallDuplicates() {
        let calls=Calls(),model=make(calls);var hits=0;model.configure {hits+=1}
        calls.unregisterStatus = -50;model.retry();XCTAssertEqual(model.state,.unavailable)
        XCTAssertEqual(calls.events,["install","register","unregister"]);model.receive(signature:0x4f53574e,id:1);XCTAssertEqual(hits,0)
        model.retry();XCTAssertEqual(calls.ids,[1]);XCTAssertFalse(calls.events.contains("remove"))
        calls.unregisterStatus=0;model.retry();XCTAssertEqual(model.state,.registered);XCTAssertEqual(calls.ids,[1,2]);model.stop()
    }
    func testFailedHandlerCleanupRetainsOnlyHandlerAndCanRetrySafely() {
        let calls=Calls(),model=make(calls);model.configure {}
        calls.removeStatus = -50;model.retry();XCTAssertEqual(model.state,.unavailable)
        XCTAssertEqual(calls.events,["install","register","unregister","remove"])
        model.retry();XCTAssertEqual(calls.events.filter {$0=="unregister"}.count,1);XCTAssertEqual(calls.ids,[1])
        calls.removeStatus=0;model.retry();XCTAssertEqual(model.state,.registered);XCTAssertEqual(calls.ids,[1,2]);model.stop()
    }
    func testFailureCleanupIsReportedAndNoEventRoutesUntilFreshSuccessfulRetry() {
        let calls=Calls();calls.registerStatus = -9878;calls.removeStatus = -50
        let model=make(calls);var hits=0;model.configure {hits+=1}
        XCTAssertTrue(model.diagnostic.contains("Shortcut registration"));XCTAssertTrue(model.diagnostic.contains("Event handler cleanup"))
        model.receive(signature:0x4f53574e,id:1);XCTAssertEqual(hits,0)
        calls.registerStatus=0;calls.removeStatus=0;model.retry();model.receive(signature:0x4f53574e,id:2);XCTAssertEqual(hits,1);model.stop()
    }
    func testStopRevokesActionBeforeUnconfirmedCleanupAndRetryWithoutConfigureStaysIdle() {
        let calls=Calls(),model=make(calls);var hits=0;model.configure {hits+=1}
        calls.unregisterStatus = -50;model.stop();XCTAssertEqual(model.state,.unavailable)
        model.receive(signature:0x4f53574e,id:1);XCTAssertEqual(hits,0)
        calls.unregisterStatus=0;model.retry();XCTAssertEqual(model.state,.idle);XCTAssertEqual(calls.ids,[1]);XCTAssertTrue(model.diagnostic.isEmpty)
    }
    func testReconfigurationCleansOldRegistrationBeforeReplacingAction() {
        let calls=Calls(),model=make(calls);var old=0,new=0
        model.configure {old+=1};model.configure {new+=1}
        XCTAssertEqual(calls.events,["install","register","unregister","remove","install","register"])
        model.receive(signature:0x4f53574e,id:1);model.receive(signature:0x4f53574e,id:2)
        XCTAssertEqual(old,0);XCTAssertEqual(new,1);model.stop();XCTAssertEqual(model.state,.idle)
    }
}
