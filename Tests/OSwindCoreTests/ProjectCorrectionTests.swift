import XCTest
import CSQLite
@testable import OSwindCore

private final class ProjectAdmissionSQL:@unchecked Sendable {
    let lock=NSLock();var values=[String]()
    func append(_ value:String) {lock.lock();defer {lock.unlock()};values.append(value)}
}
final class ProjectCorrectionTests:XCTestCase {
    var root:URL!,store:MemoryStore!,memory:Memory!,project:MemoryEntity!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-project-corrections-"+UUID().uuidString);store=try MemoryStore(root:root)
        memory=Memory(id:"owned-source",kind:.note,text:"Apollo Launch will use ALPHA42 this week.");try store.insert(memory)
        project=try store.createEntity(kind:.project,name:"Apollo Launch",aliases:["ALPHA42"]);try index()
    }
    override func tearDownWithError() throws {try store.close();store=nil;try? FileManager.default.removeItem(at:root)}
    func index()throws {try store.indexEntities(memory.id,plan:store.entityIndexPlan())}
    func reject()throws {try store.unlinkEntity(project.id,from:memory.id);try index();XCTAssertTrue(try store.entitySources(project.id).isEmpty)}
    func rename()throws {try store.editEntity(project.id,name:"Atlas Release",detail:"Same project, new display label",aliases:["Apollo Launch","ALPHA42"])}
    func testRejectedProjectSurvivesPrimaryRenameAndRescan() throws {
        try reject();try rename();try index();XCTAssertTrue(try store.entitySources(project.id).isEmpty)
    }
    func testRejectedProjectSurvivesMergeIntoAnotherProject() throws {
        try reject();let target=try store.createEntity(kind:.project,name:"Atlas Release")
        try store.mergeEntity(project.id,into:target.id);try index();XCTAssertTrue(try store.entitySources(target.id).isEmpty)
    }
    func testManualOverrideRestoresAutomaticMatchingAndSurvivesAnotherRename() throws {
        try reject();try rename();try store.linkEntity(project.id,to:memory.id);try index()
        XCTAssertEqual(try store.entitySources(project.id).first?.origin,"automatic")
        try store.editEntity(project.id,name:"Final Release",detail:"",aliases:["Apollo Launch","ALPHA42"]);try index()
        XCTAssertEqual(try store.entitySources(project.id).map(\.id),[memory.id])
    }
    func testDeletingProjectErasesItsRejectionInsteadOfBanningReusedName() throws {
        try reject();try store.deleteEntity(project.id)
        let replacement=try store.createEntity(kind:.project,name:"Apollo Launch");try index()
        XCTAssertEqual(try store.entitySources(replacement.id).map(\.id),[memory.id])
    }
    func testFavoriteAndTagsPreserveRejectionButSourceRevisionClearsIt() throws {
        try reject();var changed=memory!;changed.favorite=true;changed.tags=["owned"]
        try store.insert(changed);try rename();try index();XCTAssertTrue(try store.entitySources(project.id).isEmpty)
        changed.text="ALPHA42 has a new source revision.";try store.insert(changed);try index()
        XCTAssertEqual(try store.entitySources(project.id).map(\.id),[memory.id])
    }
    func testQuietBackupRestoresRejectedProjectAfterRename() throws {
        try reject();try rename()
        let parent=root.deletingLastPathComponent().appendingPathComponent("project-transfer-"+UUID().uuidString);try Paths.ensure(parent);defer {try? FileManager.default.removeItem(at:parent)}
        let archive=parent.appendingPathComponent("archive.oswindbackup"),destination=parent.appendingPathComponent("restored")
        _=try LibraryBackup.create(store:store,destination:archive);_=try LibraryBackup.restore(archive,to:destination)
        let copy=try MemoryStore(root:destination);defer {try? copy.close()}
        XCTAssertFalse(AppSettings.load(root:destination).entityAutomaticIndex)
        try copy.indexEntities(memory.id,plan:copy.entityIndexPlan());XCTAssertTrue(try copy.entitySources(project.id).isEmpty)
    }
    func testProjectAdmissionDoesNotAggregateExistingMembers() throws {
        let plan=try store.entityIndexPlan(),extraction=try EntityExtractor.extract(memory.text,plan:plan),observed=ProjectAdmissionSQL()
        try store.withRoutineDatabase {db in
            let context=Unmanaged.passUnretained(observed).toOpaque()
            sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{_,context,_,sql in
                if let context,let sql {Unmanaged<ProjectAdmissionSQL>.fromOpaque(context).takeUnretainedValue().append(String(cString:sql.assumingMemoryBound(to:CChar.self)))};return 0
            },context)
            defer {sqlite3_trace_v2(db.handle,0,nil,nil)}
            try store.saveEntityExtraction(memory:memory,plan:plan,result:extraction)
        }
        XCTAssertFalse(observed.values.contains {$0.uppercased().contains("COUNT(") || $0.uppercased().contains("MAX(")},"Admission must validate bounded definition/alias metadata, without scanning accumulated project members")
    }
    func ignoredCount()throws->Int {try store.withRoutineDatabase {Int(try $0.eraseCount("SELECT COUNT(*) FROM entity_project_ignored"))}}
    func makeLegacy21()throws {
        try store.withRoutineDatabase {db in
            try db.execute("INSERT OR IGNORE INTO entity_ignored VALUES('owned-source','project','apollo launch'); INSERT OR IGNORE INTO entity_ignored VALUES('owned-source','project','unmapped legacy'); DROP TRIGGER entity_project_rejection_insert; DROP TRIGGER entity_project_rejection_update; DROP TRIGGER entity_project_rejection_apply; DROP TRIGGER IF EXISTS entity_project_source_revision; DROP TRIGGER entity_source_delete; DROP TRIGGER entity_source_revision; DROP TABLE entity_project_ignored; PRAGMA user_version=21;")
        }
    }
    func testSchema21MigrationRepairsExistingAutomaticLinkWithoutBackfill() throws {
        try rename();try index();try makeLegacy21();try store.close();store=try MemoryStore(root:root)
        XCTAssertEqual(MemoryStore.schemaVersion,22);XCTAssertTrue(try store.entitySources(project.id).isEmpty);XCTAssertEqual(try ignoredCount(),1)
        XCTAssertEqual(try store.entityIndexProgress(processor:EntityExtractor.processor(store.entityIndexPlan())).indexed,1)
        try store.withRoutineDatabase {db in
            XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM entity_ignored WHERE kind='project' AND key='unmapped legacy'"),1)
            XCTAssertEqual(try db.eraseCount("SELECT COUNT(*) FROM entity_ignored WHERE kind='project' AND key='apollo launch'"),0)
        }
    }
    func testSchema21BackupBindsLegacyRejectionBeforeAnyRescan() throws {
        try rename();try index();try makeLegacy21()
        let parent=root.deletingLastPathComponent().appendingPathComponent("legacy-project-transfer-"+UUID().uuidString);try Paths.ensure(parent);defer {try? FileManager.default.removeItem(at:parent)}
        let archive=parent.appendingPathComponent("archive.oswindbackup"),destination=parent.appendingPathComponent("restored")
        let info=try LibraryBackup.create(store:store,destination:archive);XCTAssertEqual(info.sourceSchema,21)
        _=try LibraryBackup.restore(archive,to:destination)
        let copy=try MemoryStore(root:destination);defer {try? copy.close()}
        XCTAssertTrue(try copy.entitySources(project.id).isEmpty)
        try copy.indexEntities(memory.id,plan:copy.entityIndexPlan());XCTAssertTrue(try copy.entitySources(project.id).isEmpty)
        try store.close();store=try MemoryStore(root:root)
    }
    func testPreviouslyUnmappedLegacyNameBindsWhenAliasAppears() throws {
        try store.withRoutineDatabase {try $0.execute("INSERT INTO entity_ignored VALUES('owned-source','project','unmapped legacy')")}
        try store.editEntity(project.id,name:project.name,detail:"",aliases:["ALPHA42","Unmapped Legacy"]);try index()
        XCTAssertTrue(try store.entitySources(project.id).isEmpty);XCTAssertEqual(try ignoredCount(),1)
        try rename();try index();XCTAssertTrue(try store.entitySources(project.id).isEmpty)
        try store.withRoutineDatabase {XCTAssertEqual(try $0.eraseCount("SELECT COUNT(*) FROM entity_ignored WHERE kind='project'"),0)}
    }
    func testSourceRevisionFieldsClearProjectExclusion() throws {
        for field in ["text","title","app","url","time","kind"] {
            try store.insert(memory);try reject();var changed=memory!
            switch field {case "text":changed.text="ALPHA42 has a changed body";case "title":changed.title="Changed";case "app":changed.app="Changed";case "url":changed.url="https://example.com/owned";case "time":changed.timestamp=changed.timestamp.addingTimeInterval(1);default:changed.kind = .audio}
            try store.insert(changed);XCTAssertEqual(try ignoredCount(),0,field);try index();XCTAssertEqual(try store.entitySources(project.id).map(\.id),[memory.id],field)
        }
    }
    func testSourceDeleteAndFullWipeRemoveStableExclusions() throws {
        try reject();XCTAssertEqual(try ignoredCount(),1);try store.delete(memory.id);XCTAssertEqual(try ignoredCount(),0)
        try store.insert(memory);try index();XCTAssertEqual(try store.entitySources(project.id).count,1)
        try reject();XCTAssertTrue(try store.wipeLibrary().cleanupComplete);XCTAssertEqual(try ignoredCount(),0);XCTAssertTrue(try store.entities().isEmpty)
    }
    func testManualLinkActivatesUncuratedProjectRulesAndInvalidatesOldWork() throws {
        try store.withRoutineDatabase {db in
            try db.execute("UPDATE memory_entities SET curated=0 WHERE kind='project'; DELETE FROM entity_mentions WHERE entity_id IN (SELECT id FROM memory_entities WHERE kind='project') AND origin='automatic'");try db.bumpEntityRules()
        }
        let other=Memory(id:"other",kind:.note,text:"Apollo Launch has another source");try store.insert(other)
        let before=try store.entityIndexPlan();XCTAssertFalse(before.projects.contains {$0.id==project.id})
        for id in [memory.id,other.id] {try store.indexEntities(id,plan:before)}
        try store.linkEntity(project.id,to:memory.id);let after=try store.entityIndexPlan();XCTAssertNotEqual(before.revision,after.revision)
        XCTAssertEqual(try store.entityIndexProgress(processor:EntityExtractor.processor(after)).indexed,0)
        XCTAssertThrowsError(try store.saveEntityExtraction(memory:memory,plan:before,result:EntityExtractor.extract(memory.text,plan:before)))
        for id in [memory.id,other.id] {try store.indexEntities(id,plan:after)}
        XCTAssertEqual(Set(try store.entitySources(project.id).map(\.id)),[memory.id,other.id])
    }
    func testIgnoredProjectCannotHideForgedCandidateValidation() throws {
        try reject();let fake=EntityCandidate(kind:.project,name:project.name,start:0,length:13,method:"apple-nameType",projectID:project.id)
        XCTAssertThrowsError(try store.saveEntityExtraction(memory:memory,plan:store.entityIndexPlan(),result:.init(candidates:[fake])))
        XCTAssertTrue(try store.entitySources(project.id).isEmpty)
    }
    func testSQLiteGuardRefusesAutomaticMembershipButRetainsManualLink() throws {
        try reject()
        try store.withRoutineDatabase {db in
            let row=try db.statement("INSERT INTO entity_mentions VALUES(?,?,'automatic',?,0,13,'Apollo Launch','project-alias')");defer {sqlite3_finalize(row)};db.bind(row,1,memory.id);db.bind(row,2,project.id);db.bind(row,3,memory.entityRevision);try db.done(row)
        }
        XCTAssertTrue(try store.entitySources(project.id).isEmpty)
        try store.linkEntity(project.id,to:memory.id);XCTAssertEqual(try ignoredCount(),0)
        XCTAssertEqual(try store.entitySources(project.id).first?.origin,"manual")
    }
    func testBackupRejectsStableExclusionForNonProjectEntity() throws {
        let person=try store.createEntity(kind:.person,name:"Owned Person")
        try store.withRoutineDatabase {db in
            let row=try db.statement("INSERT INTO entity_project_ignored VALUES(?,?)");defer {sqlite3_finalize(row)};db.bind(row,1,memory.id);db.bind(row,2,person.id);try db.done(row)
        }
        let parent=root.deletingLastPathComponent().appendingPathComponent("invalid-project-transfer-"+UUID().uuidString);try Paths.ensure(parent);defer {try? FileManager.default.removeItem(at:parent)}
        let archive=parent.appendingPathComponent("archive.oswindbackup"),destination=parent.appendingPathComponent("restored")
        _=try LibraryBackup.create(store:store,destination:archive)
        XCTAssertThrowsError(try LibraryBackup.restore(archive,to:destination));XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
    }

    func derivedProjectWithOtherRejection()throws->Memory {
        let other=Memory(id:"other-feedback",kind:.note,text:"Apollo Launch has an additional source");try store.insert(other)
        try store.unlinkEntity(project.id,from:other.id)
        try store.withRoutineDatabase {db in try db.execute("UPDATE memory_entities SET curated=0 WHERE kind='project'");try db.bumpEntityRules()}
        return other
    }
    func testDerivedProjectFeedbackSurvivesUnrelatedReindex() throws {
        let other=try derivedProjectWithOtherRejection();try index()
        XCTAssertEqual(try ignoredCount(),1);guard try store.entity(project.id) != nil else {XCTFail("Another source's rejection still owns this derived definition");return}
        try store.editEntity(project.id,name:project.name,detail:"Curated after restoration",aliases:project.aliases)
        try store.indexEntities(other.id,plan:store.entityIndexPlan());XCTAssertFalse(try store.entitySources(project.id).contains {$0.id==other.id})
    }
    func testDerivedProjectFeedbackSurvivesOtherDeleteAndLastFeedbackRevisionPrunesIt() throws {
        let other=try derivedProjectWithOtherRejection();try store.delete(memory.id)
        XCTAssertEqual(try ignoredCount(),1);XCTAssertNotNil(try store.entity(project.id))
        var changed=other;changed.title="New source revision";try store.insert(changed)
        XCTAssertEqual(try ignoredCount(),0);XCTAssertNil(try store.entity(project.id))
    }
    func testDatabaseRejectionWinsOverAutomaticRowsWhileManualRowsRemainAuthoritative() throws {
        try store.linkEntity(project.id,to:memory.id)
        try store.withRoutineDatabase {db in
            let row=try db.statement("INSERT INTO entity_project_ignored VALUES(?,?)");defer {sqlite3_finalize(row)};db.bind(row,1,memory.id);db.bind(row,2,project.id);try db.done(row)
        }
        XCTAssertEqual(try store.entitySources(project.id).first?.origin,"manual")
        let other=Memory(id:"other-positive",kind:.note,text:memory.text);try store.insert(other);try store.indexEntities(other.id,plan:store.entityIndexPlan())
        try store.withRoutineDatabase {db in
            let row=try db.statement("UPDATE entity_mentions SET memory_id=? WHERE memory_id=? AND entity_id=? AND origin='automatic'");defer {sqlite3_finalize(row)};db.bind(row,1,memory.id);db.bind(row,2,other.id);db.bind(row,3,project.id);try db.done(row)
        }
        XCTAssertEqual(Set(try store.entitySources(project.id).map(\.id)),[memory.id,other.id])
        try store.linkEntity(project.id,to:memory.id);XCTAssertEqual(try ignoredCount(),0);try index()
        XCTAssertEqual(try store.entitySources(project.id).first {$0.id==memory.id}?.origin,"automatic")
    }

}
