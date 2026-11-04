import XCTest
import CSQLite
@testable import OSwindCore

extension SyncOutgoingTests {
    func testRecordingAffiliationUpgradesExistingProjectionBeforeNativeRenamePurgesIt()throws {
        let (audio,caption)=try namedClip();try install();_=try finish()
        let original=try recordingPacket(audio.id),oldCaption=try recordingPacket(caption.id)
        // An older enrolled library has the checked wire projection but no
        // durable affiliation row. Do not recreate old content after rename.
        try sql("DELETE FROM recording_affiliations")
        try store.setFavorite(audio.id,value:true);_=try finish()
        let source=try XCTUnwrap(store.recordedMeetingPage().sources.first),expected=try XCTUnwrap(store.recordedMeetingDetails(for:source).first)
        _=try store.saveRecordedMeetingName("Renamed after upgrade",for:source,replacing:expected)
        XCTAssertNil(try cache.record(oldCaption.reference,admit:{_ in}))
        XCTAssertEqual(try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)?.reference},try original.reference)
        _=try finish()
        guard case .source(let body)=try recordingPacket(caption.id).body else {return XCTFail("No renamed metadata")}
        XCTAssertEqual(body.recordingDetails?.scope.source,try original.reference)
    }
    func testRecordingAffiliationSurvivesRealRenameAndReopenWithoutKeepingOldCaptionBody()throws {
        let (audio,caption)=try namedClip();try install();_=try finish()
        let original=try recordingPacket(audio.id),oldCaption=try recordingPacket(caption.id)
        try store.setFavorite(audio.id,value:true);_=try finish()
        let source=try XCTUnwrap(store.recordedMeetingPage().sources.first),expected=try XCTUnwrap(store.recordedMeetingDetails(for:source).first)
        _=try store.saveRecordedMeetingName("New authored name",for:source,replacing:expected)
        XCTAssertNil(try cache.record(oldCaption.reference,admit:{_ in}),"Renaming still purges the old private caption wire body")
        let bound=try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)}
        XCTAssertEqual(bound?.reference,try original.reference)
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT CAST(owner AS TEXT)||CAST(scope AS TEXT)||COALESCE(CAST(reference AS TEXT),'') FROM recording_affiliations WHERE memory_id=?");defer {sqlite3_finalize(row)};db.bind(row,1,caption.id)
            XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertFalse(db.text(row,0).contains(caption.title))
            try RecordingAffiliationStore.checkAccounting(db)
        }
        _=try finish()
        guard case .source(let renamed)=try recordingPacket(caption.id).body else {return XCTFail("No renamed metadata")}
        XCTAssertEqual(renamed.title,"New authored name");XCTAssertEqual(renamed.recordingDetails?.scope.source,try original.reference)
        try store.close();cache=nil;queue=nil;store=try MemoryStore(root:root);try install();_=try finish()
        XCTAssertEqual(try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)},bound)
        guard case .source(let reopened)=try recordingPacket(caption.id).body else {return XCTFail("No reopened metadata")}
        XCTAssertEqual(reopened,renamed)
    }
    func testRecordingAffiliationScopeChangeAndNativeDeleteInvalidateItsLifetime()throws {
        let (audio,caption)=try namedClip();try install();_=try finish()
        let old=try XCTUnwrap(store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)})
        var other=audio;other.id="explicit-new-target";try store.insert(other);_=try finish()
        var changed=caption;changed.recordingDetails = .init(scope:try .init(sourceID:other.id,revision:other.evidenceHash));try store.insert(changed)
        XCTAssertNil(try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)},"A changed native scope must clear the prior binding before publication")
        _=try finish();let selected=try recordingPacket(other.id)
        XCTAssertEqual(try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)?.reference},try selected.reference)
        try store.delete(caption.id)
        XCTAssertNil(try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)})
        try store.withRoutineDatabase {db in try RecordingAffiliationStore.checkAccounting(db);XCTAssertEqual(try db.eraseCount("SELECT used_bytes FROM recording_affiliation_state WHERE singleton=1"),0)}
        try store.insert(changed);_=try finish()
        let recreated=try XCTUnwrap(store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)})
        XCTAssertNotEqual(recreated.owner,old.owner);XCTAssertEqual(recreated.reference,try selected.reference)
        XCTAssertNotNil(try store.get(audio.id));XCTAssertNotNil(try store.get(other.id))
    }
    func testRecordingAffiliationBudgetFailureRollsBackMetadataJournalAndBindingThenRetries()throws {
        let (_,caption)=try namedClip();try install()
        try sql("UPDATE recording_affiliation_state SET budget=1 WHERE singleton=1")
        XCTAssertThrowsError(try finish())
        let identity=try cache.catalog.localIdentity(.source,primary:[.text(Data(caption.id.utf8))])
        XCTAssertTrue(try cache.journal.state(for:identity.key).heads.isEmpty)
        XCTAssertNil(try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)})
        XCTAssertEqual(try n("SELECT used_bytes FROM recording_affiliation_state WHERE singleton=1"),0)
        XCTAssertEqual(try store.get(caption.id)?.title,caption.title)
        try sql("UPDATE recording_affiliation_state SET budget=8388608 WHERE singleton=1");_=try finish()
        XCTAssertNotNil(try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)})
        try store.withRoutineDatabase {try RecordingAffiliationStore.checkAccounting($0)}
        XCTAssertEqual(try cache.journal.state(for:identity.key).heads.count,1)
    }
    func testRecordingAffiliationChecksumCorruptionRefusesInsteadOfBecomingUnavailable()throws {
        let (_,caption)=try namedClip();try install();_=try finish()
        try store.withRoutineDatabase {db in
            try db.execute("DROP TRIGGER recording_affiliation_immutable")
            try db.execute("UPDATE recording_affiliations SET checksum='"+String(repeating:"0",count:64)+"'")
            try db.execute(RecordingAffiliationStore.schemas["recording_affiliation_immutable"]!)
        }
        XCTAssertThrowsError(try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)})
        XCTAssertThrowsError(try cache.recordingSourceBinding(XCTUnwrap(store.get(caption.id)),admit:{_ in}))
    }
    func testRecordingAffiliationReadyInstallAndReadDenyCanonicalPayloadAndAllDML()throws {
        let (_,caption)=try namedClip();try install();_=try finish()
        let expected=try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)}
        try store.withRoutineDatabase {db in
            sqlite3_set_authorizer(db.handle,{_,op,a,b,_,_ in
                if op==SQLITE_INSERT || op==SQLITE_UPDATE || op==SQLITE_DELETE {return SQLITE_DENY}
                if op==SQLITE_READ,let a,let b,String(cString:a)=="memories",String(cString:b)=="payload" {return SQLITE_DENY}
                return SQLITE_OK
            },nil);defer {sqlite3_set_authorizer(db.handle,nil,nil)}
            try RecordingAffiliationStore.install(db)
            XCTAssertEqual(try RecordingAffiliationStore.read(db,id:caption.id),expected)
        }
    }
    func testRecordingAffiliationBackupQuietRestoreKeepsAuthoredNameWithoutOperationalAuthority()throws {
        let (_,caption)=try namedClip();try install();_=try finish()
        XCTAssertNotNil(try store.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)})
        let output=root.deletingLastPathComponent().appendingPathComponent("owned-affiliation-backup-"+UUID().uuidString)
        try Paths.ensure(output);defer {try? FileManager.default.removeItem(at:output)}
        let archive=output.appendingPathComponent("owned-affiliation.oswindbackup"),destination=output.appendingPathComponent("quiet-restored")
        let info=try LibraryBackup.create(store:store,destination:archive)
        _=try LibraryBackup.restore(archive,to:destination,expectedFingerprint:info.archiveFingerprint)
        let restored=try MemoryStore(root:destination);defer {try? restored.close()}
        XCTAssertEqual(try restored.get(caption.id)?.recordingDetails,caption.recordingDetails)
        let source=try XCTUnwrap(restored.recordedMeetingPage().sources.first)
        XCTAssertEqual(try restored.recordedMeetingDetails(for:source).map(\.name),[caption.title])
        XCTAssertNil(try restored.withRoutineDatabase {try RecordingAffiliationStore.read($0,id:caption.id)})
        try restored.withRoutineDatabase {db in try RecordingAffiliationStore.checkAccounting(db);XCTAssertEqual(try db.eraseCount("SELECT used_bytes FROM recording_affiliation_state WHERE singleton=1"),0)}
    }
}
