import XCTest
import CSQLite
@testable import OSwindCore

extension SyncOutgoingTests {
    private func explicitRecordingReassignment(publishTarget:Bool=false)throws->(Memory,Memory,Memory) {
        let (audio,caption)=try namedClip();try install();_=try finish()
        var other=audio;other.id="explicit-reassignment-target";other.text="Independent authored recording";try store.insert(other)
        if publishTarget {_=try finish()}
        var changed=caption;changed.recordingDetails = .init(scope:try .init(sourceID:other.id,revision:other.evidenceHash));try store.insert(changed)
        return(audio,other,changed)
    }
    private func reassignment(_ id:String)throws->RecordingReassignmentStore.Intent? {try store.withRoutineDatabase {try RecordingReassignmentStore.read($0,id:id)}}
    func testRecordingReassignmentSurvivesReopenAndPreparesNewTargetBeforeConsumingIntent()throws {
        let (audio,other,changed)=try explicitRecordingReassignment(),intent=try XCTUnwrap(reassignment(changed.id))
        XCTAssertEqual(intent.scope,changed.recordingDetails?.scope)
        XCTAssertNil(try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:changed.id)})
        XCTAssertNil(try cache.catalog.preparedIdentity(.source,primary:[.text(Data(other.id.utf8))]),"The explicit edit must not invent or publish its target identity")
        try store.close();cache=nil;queue=nil;store=try MemoryStore(root:root);try install()
        XCTAssertEqual(try reassignment(changed.id),intent);_=try finish()
        guard case .source(let body)=try recordingPacket(changed.id).body else {return XCTFail("Missing metadata")}
        XCTAssertEqual(body.recordingDetails?.scope.source,try recordingPacket(other.id).reference)
        XCTAssertNotEqual(body.recordingDetails?.scope.source,try recordingPacket(audio.id).reference)
        XCTAssertNil(try reassignment(changed.id));try store.withRoutineDatabase {try RecordingReassignmentStore.checkAccounting($0)}
    }
    func testRecordingReassignmentPolicyFailureRollsBackAndPreservesIntentForRetry()throws {
        let (_,other,changed)=try explicitRecordingReassignment(publishTarget:true),intent=try XCTUnwrap(reassignment(changed.id)),before=try cache.journal.outbox()
        var denied=false
        let refusal=SyncOutgoingProcessor(queue:queue,cache:cache,admitRow:{_,_ in},admitVersion:{record in
            if case .source(let body)=record.body,body.kind == .audio {denied=true;throw SyncPublicationPolicyDenied()}
        },media:{_ in []})
        XCTAssertThrowsError(try finish(refusal)) {XCTAssertTrue($0 is SyncPublicationPolicyDenied)}
        XCTAssertTrue(denied);XCTAssertEqual(try reassignment(changed.id),intent);XCTAssertEqual(try cache.journal.outbox(),before)
        XCTAssertNil(try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:changed.id)})
        _=try finish();guard case .source(let body)=try recordingPacket(changed.id).body else {return XCTFail("Missing metadata")}
        XCTAssertEqual(body.recordingDetails?.scope.source,try recordingPacket(other.id).reference);XCTAssertNil(try reassignment(changed.id))
    }
    func testRecordingReassignmentBudgetFailureRollsBackNativeScopeAndPriorBinding()throws {
        let (audio,caption)=try namedClip();try install();_=try finish()
        let binding=try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)}
        var other=audio;other.id="budget-reassignment-target";try store.insert(other);_=try finish();let before=try cache.journal.outbox()
        var changed=caption;changed.recordingDetails = .init(scope:try .init(sourceID:other.id,revision:other.evidenceHash))
        try sql("UPDATE recording_reassignment_state SET budget=1")
        XCTAssertThrowsError(try store.insert(changed));XCTAssertEqual(try store.get(caption.id),caption);XCTAssertNil(try reassignment(caption.id))
        XCTAssertEqual(try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)},binding)
        XCTAssertEqual(try cache.journal.outbox(),before)
        try sql("UPDATE recording_reassignment_state SET budget=1048576");try store.insert(changed);_=try finish();XCTAssertNil(try reassignment(caption.id))
    }
    func testRecordingReassignmentLaterScopeEditReplacesIntentAndSameScopeCaptionEditPreservesIt()throws {
        let (original,_,changed)=try explicitRecordingReassignment(),first=try XCTUnwrap(reassignment(changed.id))
        var renamed=changed;renamed.title="Renamed while pending";try store.insert(renamed);XCTAssertEqual(try reassignment(changed.id),first)
        var again=renamed;again.recordingDetails = .init(scope:try .init(sourceID:original.id,revision:original.evidenceHash));try store.insert(again)
        let second=try XCTUnwrap(reassignment(changed.id));XCTAssertNotEqual(second.scope,first.scope);XCTAssertEqual(second.owner,first.owner)
        _=try finish();guard case .source(let body)=try recordingPacket(changed.id).body else {return XCTFail("Missing metadata")}
        XCTAssertEqual(body.recordingDetails?.scope.source,try recordingPacket(original.id).reference);XCTAssertNil(try reassignment(changed.id))
    }
    func testRecordingReassignmentCorruptProofRefusesWithoutFallbackOrPublication()throws {
        let (_,_,changed)=try explicitRecordingReassignment(publishTarget:true),before=try cache.journal.outbox()
        try sql("DROP TRIGGER recording_reassignment_immutable")
        try sql("UPDATE recording_reassignments SET checksum=printf('%064d',0)")
        try store.withRoutineDatabase {try $0.execute(RecordingReassignmentStore.schemas["recording_reassignment_immutable"]!)}
        XCTAssertThrowsError(try finish());XCTAssertEqual(try cache.journal.outbox(),before);XCTAssertEqual(try store.get(changed.id),changed)
    }
    func testRecordingReassignmentDeletionAndQuietRestoreDoNotTransferOperationalIntent()throws {
        let (_,_,changed)=try explicitRecordingReassignment(),intent=try XCTUnwrap(reassignment(changed.id))
        let output=root.deletingLastPathComponent().appendingPathComponent("owned-reassignment-backup-"+UUID().uuidString)
        try Paths.ensure(output);defer {if !recordingOriginalRetained {try? FileManager.default.removeItem(at:output)}}
        let archive=output.appendingPathComponent("owned.oswindbackup"),destination=output.appendingPathComponent("quiet-restored")
        let info=try LibraryBackup.create(store:store,destination:archive);_=try LibraryBackup.restore(archive,to:destination,expectedFingerprint:info.archiveFingerprint)
        let restored=try MemoryStore(root:destination);defer {try? restored.close()}
        XCTAssertEqual(try restored.get(changed.id)?.recordingDetails,changed.recordingDetails)
        XCTAssertNil(try restored.withRoutineDatabase {try RecordingReassignmentStore.read($0,id:changed.id)})
        try store.delete(changed.id);XCTAssertNil(try reassignment(changed.id));try store.withRoutineDatabase {try RecordingReassignmentStore.checkAccounting($0)}
        try store.insert(changed);_=try finish();XCTAssertNotEqual(try recordingPacket(changed.id).identity,intent.owner)
    }
    func testRecordingReassignmentStoreInstallsOnOldLibraryWithoutRebuildingExistingAffiliation()throws {
        let (_,caption)=try namedClip();try install();_=try finish()
        let binding=try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)}
        try store.withRoutineDatabase {db in
            for (name,_) in RecordingReassignmentStore.schemas where name != "recording_reassignment_state" && name != "recording_reassignments" {try db.execute("DROP TRIGGER "+name)}
            try db.execute("DROP TABLE recording_reassignments");try db.execute("DROP TABLE recording_reassignment_state")
        }
        try store.close();cache=nil;queue=nil;store=try MemoryStore(root:root);try install()
        XCTAssertEqual(try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)},binding)
        XCTAssertNil(try reassignment(caption.id));try store.withRoutineDatabase {try RecordingReassignmentStore.checkAccounting($0)}
    }
}
