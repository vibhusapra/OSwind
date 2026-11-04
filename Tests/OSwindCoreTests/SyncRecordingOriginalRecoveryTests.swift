import XCTest
import CSQLite
@testable import OSwindCore

extension SyncOutgoingTests {
    private func retainRecordingOriginal(_ record:SyncPortableRecord)throws->HistoricalEvidence {
        try store.withRoutineDatabase {db in
            try store.historicalCatalog(db).adopt(record.reference,cache:cache,pathsFor:{_,_ in [:]},admit:{_ in},verifyMedia:{_,_,_ in})
        }
    }
    private func loseOnlyRecordingWireCache(_ reference:SyncVersionReference)throws {
        try store.withRoutineDatabase {db in
            let row=try db.statement("DELETE FROM personal_sync_versions WHERE object_digest=? AND content_sha=?");defer {sqlite3_finalize(row)}
            db.bind(row,1,try reference.identity.key.digest);db.bind(row,2,reference.content.sha256);try db.done(row)
            XCTAssertEqual(sqlite3_changes(db.handle),1,"The owned fault removes exactly the replaceable body, not canonical history or affiliation")
        }
    }
    func testRecordingNameRecoversOnlyItsExactRetainedOriginalAfterWireCacheLoss()throws {
        let (audio,caption)=try namedClip();try install();_=try finish()
        let original=try recordingPacket(audio.id),retained=try retainRecordingOriginal(original),reference=try original.reference
        try store.setFavorite(audio.id,value:true);_=try finish()
        XCTAssertNotEqual(try recordingPacket(audio.id).reference,reference)
        try loseOnlyRecordingWireCache(reference);XCTAssertNil(try cache.record(reference,admit:{_ in}))
        XCTAssertEqual(try store.withRoutineDatabase {try store.historicalCatalog($0).read(retained.handle,sourceID:audio.id,verifyMedia:{_,_,_ in}).record},original)
        XCTAssertEqual(try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)?.reference},reference)
        let source=try XCTUnwrap(store.recordedMeetingPage().sources.first),expected=try XCTUnwrap(store.recordedMeetingDetails(for:source).first)
        _=try store.saveRecordedMeetingName("Renamed with retained original",for:source,replacing:expected);_=try finish()
        guard case .source(let body)=try recordingPacket(caption.id).body else {return XCTFail("Missing recording metadata")}
        XCTAssertEqual(body.recordingDetails?.scope.source,reference,"Recover the known exact original, never select a newer equivalent audio wire version")
        XCTAssertEqual(try cache.record(reference,admit:{_ in}),original,"The exact recovered body must be available to the outgoing dependency graph")
        XCTAssertEqual(try store.get(audio.id)?.favorite,true)
    }
    func testRecordingNativeTranscriptEditDoesNotRecoverPurgedHistoricalOriginal()throws {
        var (audio,caption)=try namedClip();try install();_=try finish()
        let original=try recordingPacket(audio.id),retained=try retainRecordingOriginal(original)
        audio.text="Authored replacement after deliberate native transcript edit";try store.insert(audio);_=try finish()
        XCTAssertThrowsError(try store.withRoutineDatabase {try store.historicalCatalog($0).read(retained.handle,sourceID:audio.id,verifyMedia:{_,_,_ in})})
        XCTAssertNil(try cache.record(original.reference,admit:{_ in}))
        try store.setFavorite(caption.id,value:true);_=try finish()
        guard case .source(let body)=try recordingPacket(caption.id).body else {return XCTFail("Missing recording metadata")}
        XCTAssertEqual(body.recordingDetails?.scope.selector,.unavailable)
        XCTAssertNil(try cache.record(original.reference,admit:{_ in}),"Recovery must never recreate privacy-purged speech from a label or hash")
    }
}

private enum RecordingRecoveryRefusal:Error,Equatable {case policy,media}
extension SyncOutgoingTests {
    private func lostRecordingBodyFixture()throws->(audio:Memory,caption:Memory,original:SyncPortableRecord,retained:HistoricalEvidence) {
        let (audio,caption)=try namedClip();try install();_=try finish()
        let original=try recordingPacket(audio.id),retained=try retainRecordingOriginal(original)
        try store.setFavorite(audio.id,value:true);_=try finish();try loseOnlyRecordingWireCache(original.reference)
        return(audio,try XCTUnwrap(store.get(caption.id)),original,retained)
    }
    private func recoverRecording(_ memory:Memory,admit:(SyncPortableRecord)throws->Void={_ in},verify:@escaping (HistoricalEvidence)throws->Void={_ in})throws->SyncRecordingSourceResolution? {
        try store.withRoutineDatabase {db in try cache.recordingSourceBinding(memory,historical:store.historicalCatalog(db),admit:admit,verifyOriginal:verify)}
    }
    func testRecordingOriginalRecoveryDoesNotPublishOrMutateCanonicalRows()throws {
        let f=try lostRecordingBodyFixture(),before=try frames(),outbox=try cache.journal.outbox()
        XCTAssertEqual(try recoverRecording(f.caption),.available(try f.original.reference))
        XCTAssertEqual(try frames(),before);XCTAssertEqual(try cache.journal.outbox(),outbox)
    }
    func testRecordingOriginalRecoveryPolicyAndMediaRefusalsPropagateWithoutCacheOrJournalChanges()throws {
        let f=try lostRecordingBodyFixture(),before=try frames(),outbox=try cache.journal.outbox()
        var policy=false,media=false
        XCTAssertThrowsError(try recoverRecording(f.caption,admit:{_ in policy=true;throw RecordingRecoveryRefusal.policy})) {XCTAssertEqual($0 as? RecordingRecoveryRefusal,.policy)}
        XCTAssertTrue(policy);XCTAssertNil(try cache.record(f.original.reference,admit:{_ in}))
        XCTAssertThrowsError(try recoverRecording(f.caption,verify:{_ in media=true;throw RecordingRecoveryRefusal.media})) {XCTAssertEqual($0 as? RecordingRecoveryRefusal,.media)}
        XCTAssertTrue(media);XCTAssertNil(try cache.record(f.original.reference,admit:{_ in}));XCTAssertEqual(try frames(),before);XCTAssertEqual(try cache.journal.outbox(),outbox)
    }
    func testRecordingOriginalRecoveryBudgetRefusesAtomicallyAndCanRetry()throws {
        let f=try lostRecordingBodyFixture(),before=try frames(),outbox=try cache.journal.outbox(),used=try n("SELECT used_bytes FROM personal_sync_version_state")
        XCTAssertGreaterThan(used,0);try sql("UPDATE personal_sync_version_state SET budget=used_bytes")
        XCTAssertThrowsError(try recoverRecording(f.caption));XCTAssertNil(try cache.record(f.original.reference,admit:{_ in}))
        XCTAssertEqual(try n("SELECT used_bytes FROM personal_sync_version_state"),used);XCTAssertEqual(try frames(),before);XCTAssertEqual(try cache.journal.outbox(),outbox)
        try sql("UPDATE personal_sync_version_state SET budget=budget+65536")
        XCTAssertEqual(try recoverRecording(f.caption),.available(try f.original.reference))
    }
    private func recordingRecoveryRejectsReentrantEdit(_ root:Bool)throws {
        let f=try lostRecordingBodyFixture(),before=try frames(),outbox=try cache.journal.outbox();var reached=false
        XCTAssertThrowsError(try recoverRecording(f.caption,admit:{_ in reached=true;try self.store.setFavorite(root ? f.caption.id:f.audio.id,value:root)}))
        XCTAssertTrue(reached);XCTAssertEqual(try frames(),before);XCTAssertEqual(try cache.journal.outbox(),outbox);XCTAssertNil(try cache.record(f.original.reference,admit:{_ in}))
    }
    func testRecordingOriginalRecoveryRejectsReentrantCaptionEditAndRollsBack()throws {try recordingRecoveryRejectsReentrantEdit(true)}
    func testRecordingOriginalRecoveryRejectsReentrantAudioEditAndRollsBack()throws {try recordingRecoveryRejectsReentrantEdit(false)}
    func testRecordingOriginalRecoveryRechecksArchiveAfterAdmissionAndRollsBackLoss()throws {
        let f=try lostRecordingBodyFixture();var reached=false
        XCTAssertThrowsError(try recoverRecording(f.caption,verify:{value in
            reached=true;try self.store.withRoutineDatabase {db in let row=try db.statement("DELETE FROM historical_evidence WHERE handle=?");defer {sqlite3_finalize(row)};db.bind(row,1,value.handle);try db.done(row)}
        }))
        XCTAssertTrue(reached);XCTAssertNil(try cache.record(f.original.reference,admit:{_ in}))
        XCTAssertEqual(try store.withRoutineDatabase {try store.historicalCatalog($0).read(f.retained.handle,sourceID:f.audio.id,verifyMedia:{_,_,_ in}).record},f.original)
    }
    func testRecordingOriginalRecoveryRejectsCorruptCanonicalHistoryWithoutReplacingIt()throws {
        let f=try lostRecordingBodyFixture()
        try store.withRoutineDatabase {db in
            try db.execute("DROP TRIGGER historical_immutable")
            defer {try? db.execute(HistoricalEvidenceStore.schemas["historical_immutable"]!)}
            let row=try db.statement("UPDATE historical_evidence SET projection_sha=? WHERE handle=?");defer {sqlite3_finalize(row)};db.bind(row,1,String(repeating:"0",count:64));db.bind(row,2,f.retained.handle);try db.done(row)
        }
        XCTAssertThrowsError(try recoverRecording(f.caption));XCTAssertNil(try cache.record(f.original.reference,admit:{_ in}))
    }
    func testRecordingOriginalRecoveryRejectsForeignArchiveConnection()throws {
        let f=try lostRecordingBodyFixture(),otherRoot=root.appendingPathComponent("foreign"),other=try MemoryStore(root:otherRoot);defer {try? other.close()}
        XCTAssertThrowsError(try other.withRoutineDatabase {foreign in try cache.recordingSourceBinding(f.caption,historical:other.historicalCatalog(foreign),admit:{_ in XCTFail("Foreign archive must refuse before admission")},verifyOriginal:{_ in XCTFail("Foreign archive media must not be used")})})
        XCTAssertNil(try cache.record(f.original.reference,admit:{_ in}))
    }
    func testRecordingOriginalRecoveryUpgradesOnlyAnActuallyCheckedLegacyProjection()throws {
        let f=try lostRecordingBodyFixture();try sql("DELETE FROM recording_affiliations")
        XCTAssertEqual(try recoverRecording(f.caption),.available(try f.original.reference))
        XCTAssertEqual(try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:f.caption.id)?.reference},try f.original.reference)
    }
    func testRecordingOriginalRecoveryWithLostRootBodyPublishesUnavailableWithoutBlockingUnrelatedRows()throws {
        let f=try lostRecordingBodyFixture(),rootRecord=try recordingPacket(f.caption.id)
        try sql("DELETE FROM recording_affiliations");try loseOnlyRecordingWireCache(rootRecord.reference)
        let source=try XCTUnwrap(store.recordedMeetingPage().sources.first),expected=try XCTUnwrap(store.recordedMeetingDetails(for:source).first)
        _=try store.saveRecordedMeetingName("Still authored after proof loss",for:source,replacing:expected)
        try seed("unrelated-after-proof-loss","Authored independent note");_=try finish()
        guard case .source(let body)=try recordingPacket(f.caption.id).body else {return XCTFail("Missing recording metadata")}
        XCTAssertEqual(body.recordingDetails?.scope.selector,.unavailable);XCTAssertNil(try cache.record(f.original.reference,admit:{_ in}))
        XCTAssertEqual(try recordingPacket("unrelated-after-proof-loss").identity.table,.source)
    }
    func testRecordingOriginalRecoveryCannotReviveDeletedAudioOrItsReplacementLifetime()throws {
        let f=try lostRecordingBodyFixture();_=try store.delete(f.audio.id)
        XCTAssertThrowsError(try recoverRecording(f.caption));XCTAssertNil(try store.get(f.audio.id));XCTAssertNil(try store.get(f.caption.id))
        try store.insert(f.audio);_=try finish();XCTAssertNotEqual(try recordingPacket(f.audio.id).identity, f.original.identity)
        XCTAssertThrowsError(try recoverRecording(f.caption));XCTAssertThrowsError(try cache.record(f.original.reference,admit:{_ in}))
    }
    func testRecordingOriginalRecoveryWithoutAnyPriorBindingProofDoesNotChooseEquivalentCurrentWire()throws {
        let f=try lostRecordingBodyFixture(),identity=try cache.catalog.localIdentity(.source,primary:[.text(Data(f.caption.id.utf8))])
        try store.withRoutineDatabase {db in
            try db.execute("DELETE FROM recording_affiliations")
            let row=try db.statement("DELETE FROM personal_sync_version_projection WHERE object_digest=?");defer {sqlite3_finalize(row)};db.bind(row,1,try identity.key.digest);try db.done(row)
        }
        let before=try cache.journal.outbox();_=try store.setFavorite(f.caption.id,value:true);_=try finish()
        guard case .source(let body)=try recordingPacket(f.caption.id).body else {return XCTFail("Missing metadata")}
        XCTAssertEqual(body.recordingDetails?.scope.selector,.unavailable,"A historical hash alone cannot choose a new wire version after prior binding proof is lost")
        XCTAssertNil(try cache.record(f.original.reference,admit:{_ in}));XCTAssertLessThanOrEqual(before.count,try cache.journal.outbox().count)
    }
}
