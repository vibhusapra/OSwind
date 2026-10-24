import XCTest
@testable import OSwindCore

final class EntityMetadataTests:XCTestCase {
    var root:URL!,store:MemoryStore!,project:MemoryEntity!,automatic:Memory!,manual:Memory!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-entity-metadata-"+UUID().uuidString);store=try MemoryStore(root:root)
        project=try store.createEntity(kind:.project,name:"Apollo Launch",aliases:["Moon Plan"])
        automatic=Memory(id:"automatic",text:"Apollo Launch will ship this week.");manual=Memory(id:"manual",text:"An independently linked source.")
        try store.insert(automatic);try store.insert(manual);try store.linkEntity(project.id,to:manual.id)
        let plan=try store.entityIndexPlan();try store.indexEntities(automatic.id,plan:plan);try store.indexEntities(manual.id,plan:plan)
    }
    override func tearDownWithError() throws {try store.close();store=nil;try? FileManager.default.removeItem(at:root)}
    func links()throws->Data {let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys;return try encoder.encode(store.entitySources(project.id))}
    func processor()throws->String {try EntityExtractor.processor(store.entityIndexPlan())}
    func assertComplete(_ expected:String,file:StaticString=#filePath,line:UInt=#line)throws {
        XCTAssertEqual(try processor(),expected,file:file,line:line)
        XCTAssertEqual(try store.entityIndexProgress(processor:expected).indexed,2,file:file,line:line)
        XCTAssertTrue(try store.pendingEntitySourceIDs(processor:expected).isEmpty,file:file,line:line)
        XCTAssertEqual(Set(try store.entitySources(project.id).map(\.id)),[automatic.id,manual.id],file:file,line:line)
    }
    func testNotesOnlyEditPreservesAutomaticAnchorsAndCompletion() throws {
        let old=try processor(),before=try links()
        try store.editEntity(project.id,name:project.name,detail:"Updated project notes",aliases:project.aliases)
        try assertComplete(old);XCTAssertEqual(try store.entity(project.id)?.detail,"Updated project notes")
        XCTAssertEqual(try links(),before)
        XCTAssertEqual(try store.search(.init(entityID:project.id),mode:.keyword).count,2)
    }
    func testExistingCreateWithSameAliasesPreservesCompletionAndUpdatesNotes() throws {
        let old=try processor(),same=try store.createEntity(kind:.project,name:project.name,detail:"Revised",aliases:["Moon Plan"])
        XCTAssertEqual(same.id,project.id);XCTAssertEqual(same.detail,"Revised");try assertComplete(old)
    }
    func testAliasOrderAndCaseOnlyEditPreservesPreparedWork() throws {
        let plan=try store.entityIndexPlan(),old=EntityExtractor.processor(plan),result=try EntityExtractor.extract(automatic.text,plan:plan)
        try store.editEntity(project.id,name:project.name,detail:"Display aliases",aliases:["MOON PLAN","Apollo Launch","MOON PLAN"])
        try assertComplete(old);XCTAssertTrue(try store.entity(project.id)!.aliases.contains("MOON PLAN"))
        XCTAssertNoThrow(try store.saveEntityExtraction(memory:automatic,plan:plan,result:result));try assertComplete(old)
    }
    func testNotesEditAllowsAlreadyExtractedSourceWithoutStaleRuleFailure() throws {
        let plan=try store.entityIndexPlan(),result=try EntityExtractor.extract(automatic.text,plan:plan)
        try store.editEntity(project.id,name:project.name,detail:"Notes changed during extraction",aliases:project.aliases)
        XCTAssertNoThrow(try store.saveEntityExtraction(memory:automatic,plan:plan,result:result));try assertComplete(EntityExtractor.processor(plan))
    }
    func testNotesEditPreservesRejectedAutomaticLinkAndCompletion() throws {
        try store.unlinkEntity(project.id,from:automatic.id)
        let plan=try store.entityIndexPlan(),old=EntityExtractor.processor(plan)
        try store.editEntity(project.id,name:project.name,detail:"Keep this source rejected",aliases:project.aliases)
        XCTAssertEqual(try processor(),old);XCTAssertEqual(try store.entityIndexProgress(processor:old).indexed,2)
        try store.indexEntities(automatic.id,plan:plan)
        XCTAssertEqual(try store.entitySources(project.id).map(\.id),[manual.id])
    }
    func testChangedAliasesOrNameStillInvalidateAndRejectOldWork() throws {
        let plan=try store.entityIndexPlan(),result=try EntityExtractor.extract(automatic.text,plan:plan)
        try store.editEntity(project.id,name:project.name,detail:"New rule",aliases:["Brand New Alias"])
        XCTAssertNotEqual(try processor(),EntityExtractor.processor(plan));XCTAssertEqual(try store.entityIndexProgress(processor:processor()).indexed,0)
        XCTAssertEqual(try store.entitySources(project.id).map(\.id),[manual.id]);XCTAssertThrowsError(try store.saveEntityExtraction(memory:automatic,plan:plan,result:result))
        let next=try store.entityIndexPlan();try store.indexEntities(automatic.id,plan:next)
        try store.editEntity(project.id,name:"APOLLO LAUNCH",detail:"Case-only primary rename",aliases:["Brand New Alias"])
        XCTAssertNotEqual(try processor(),EntityExtractor.processor(next));XCTAssertEqual(try store.entitySources(project.id).map(\.id),[manual.id])
    }
    func testNewAliasViaExistingCreateInvalidatesButFailedCollisionDoesNot() throws {
        let old=try processor();_=try store.createEntity(kind:.project,name:"Other",aliases:["Taken"])
        let before=try processor();XCTAssertNotEqual(before,old)
        XCTAssertThrowsError(try store.editEntity(project.id,name:project.name,detail:"Must not commit",aliases:["Taken"]))
        XCTAssertEqual(try processor(),before);XCTAssertEqual(try store.entity(project.id)?.detail,"");XCTAssertEqual(try store.entitySources(project.id).count,2)
        _=try store.createEntity(kind:.project,name:project.name,aliases:["Fresh Alias"])
        XCTAssertNotEqual(try processor(),before);XCTAssertEqual(try store.entityIndexProgress(processor:processor()).indexed,0)
    }
}
