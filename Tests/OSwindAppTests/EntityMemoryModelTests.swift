import XCTest
@testable import OSwind
@testable import OSwindCore

private final class EntityWorkerGate:@unchecked Sendable {
    let entered=XCTestExpectation(description:"first entity worker entered")
    private let condition=NSCondition()
    private var released=false,calls=0,active=0,maximum=0
    func run(_ id:String,_ plan:EntityIndexPlan)throws->Bool {
        condition.lock();calls+=1;active+=1;maximum=max(maximum,active)
        if calls==1 {entered.fulfill();while !released {condition.wait()}}
        active-=1;condition.unlock();try Task.checkCancellation();return true
    }
    func release() {condition.lock();released=true;condition.broadcast();condition.unlock()}
    var count:Int {condition.lock();defer {condition.unlock()};return calls}
    var peak:Int {condition.lock();defer {condition.unlock()};return maximum}
}
@MainActor final class EntityMemoryModelTests:XCTestCase {
    func fixture()throws->(URL,MemoryStore) {let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-entity-model-"+UUID().uuidString);return(root,try MemoryStore(root:root))}
    func wait(_ condition:@escaping ()->Bool) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while !condition(),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertTrue(condition())
    }
    func testCancelledProducerMustExitBeforeQueuedCaptureStarts() async throws {
        let (root,store)=try fixture(),gate=EntityWorkerGate();defer {gate.release();try? store.close();try? FileManager.default.removeItem(at:root)}
        let model=EntityMemoryModel(store:store,indexSource:{try gate.run($0,$1)},canIndex:{true});defer {model.clear()}
        model.enqueue(Memory(id:"a",text:"Owned"));await fulfillment(of:[gate.entered],timeout:5)
        model.cancel();model.enqueue(Memory(id:"b",text:"Owned"))
        XCTAssertTrue(model.indexing);XCTAssertEqual(gate.count,1)
        gate.release();try await wait {gate.count==2 && !model.indexing}
        XCTAssertEqual(gate.peak,1)
    }
    func testClearCancelsLateMutationWithoutPublishingNamesOrCommitting() async throws {
        let (root,store)=try fixture(),gate=EntityWorkerGate();defer {gate.release();try? store.close();try? FileManager.default.removeItem(at:root)}
        let model=EntityMemoryModel(store:store)
        model.mutate {database in _=try gate.run("owned",database.entityIndexPlan());_=try database.createEntity(kind:.person,name:"Must not commit")}
        await fulfillment(of:[gate.entered],timeout:5);model.clear();gate.release()
        try await Task.sleep(for:.milliseconds(120))
        XCTAssertTrue(model.entities.isEmpty);XCTAssertNil(model.selected);XCTAssertNil(model.error);XCTAssertTrue(try store.entities().isEmpty)
    }
    func testPowerDeferralDoesNotEnterExtractorAndManualResumeIndexes() async throws {
        let (root,store)=try fixture(),gate=EntityWorkerGate();defer {gate.release();try? store.close();try? FileManager.default.removeItem(at:root)}
        let deferred=EntityMemoryModel(store:store,indexSource:{try gate.run($0,$1)},canIndex:{false});deferred.enqueue(Memory(id:"owned",text:"Owned"));XCTAssertFalse(deferred.indexing);XCTAssertEqual(gate.count,0)
        try store.insert(Memory(id:"owned",text:"Apollo Launch update"));_=try store.createEntity(kind:.project,name:"Apollo Launch")
        let model=EntityMemoryModel(store:store,canIndex:{true});defer {model.clear()};model.build()
        try await wait {!model.indexing && model.progress.indexed==1};XCTAssertEqual(try store.entities(kind:.project).first?.sourceCount,1)
    }
    func testEntityNavigationKeepsVisibleScopeAndClearsOnOtherSection() throws {
        let (root,store)=try fixture();defer {try? store.close();try? FileManager.default.removeItem(at:root)}
        let app=try AppModel(root:root,startServices:false,preparedStore:store);defer {app.prepareForLibrarySwitch()}
        let entity=try store.createEntity(kind:.project,name:"Owned")
        app.browseEntity(entity,ask:false);XCTAssertEqual(app.section,"Memories");XCTAssertEqual(app.filter.entityID,entity.id)
        app.section="Ask";XCTAssertEqual(app.filter.entityID,entity.id)
        app.section="Calendar";XCTAssertNil(app.filter.entityID)
        app.browseEntity(entity,ask:true);app.clearForVaultLock();XCTAssertNil(app.entityScope);XCTAssertTrue(app.entityMemory.entities.isEmpty)
    }
}
