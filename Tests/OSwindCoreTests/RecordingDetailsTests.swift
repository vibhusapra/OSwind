import XCTest
import CSQLite
@testable import OSwindCore

final class RecordingDetailsTests:XCTestCase {
    private var root:URL!,store:MemoryStore!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-recording-details-"+UUID().uuidString);store=try MemoryStore(root:root.appendingPathComponent("library"))}
    override func tearDownWithError()throws {try store.close();try FileManager.default.removeItem(at:root)}
    @discardableResult private func audio(_ id:String,session:String?="session",offset:Double=0)throws->Memory {
        var value=Memory(id:id,timestamp:Date(timeIntervalSince1970:100+offset),endTimestamp:Date(timeIntervalSince1970:130+offset),kind:.audio,app:"Authored audio",bundleID:"owned.audio",title:"Original source title",text:"Original authored transcript "+id)
        value.audioSessionID=session;value.transcript = .init(text:value.text,duration:30,segments:[.init(start:0,end:30,text:value.text)],model:"Authored fixture, no ASR")
        try store.insert(value);return value
    }
    private func source(_ id:String)throws->RecordedMeetingSource {try XCTUnwrap(store.recordedMeetingPage().sources.first {$0.memoryID==id})}
    func testRecreatedIdenticalMetadataCannotAcceptItsRetiredEditSnapshot()throws {
        try audio("a");let ref=try source("a"),old=try store.saveRecordedMeetingName("Original",for:ref),body=try XCTUnwrap(store.get(old.id))
        try store.delete(old.id);try store.insert(body)
        XCTAssertThrowsError(try store.saveRecordedMeetingName("Must refuse retired edit",for:ref,replacing:old))
    }
    func testByteDifferentMetadataReplacementCannotReuseCanonicalEquivalentIDSnapshot()throws {
        try audio("a");let ref=try source("a"),first=try store.saveRecordedMeetingName("Original",for:ref)
        var body=try XCTUnwrap(store.get(first.id));try store.delete(first.id);body.id="é";try store.insert(body)
        let old=try XCTUnwrap(store.recordedMeetingDetails(for:ref).first)
        try store.delete(body.id);body.id="e\u{301}";try store.insert(body)
        XCTAssertThrowsError(try store.saveRecordedMeetingName("Must not retarget",for:ref,replacing:old))
    }
    func testNewNameAdvancesRecordingRevisionWithoutChangingAudioSourceReference()throws {
        try audio("a");let ref=try source("a"),before=try store.recordedMeetingRevision()
        _ = try store.saveRecordedMeetingName("Fresh name",for:ref)
        XCTAssertNotEqual(try store.recordedMeetingRevision(),before)
        XCTAssertEqual(try store.recordedMeetingEvidence(ref).id,"a")
    }
    func testPreparedNameCannotPublishAfterAnotherConnectionRenamesIt()throws {
        try audio("a");let ref=try source("a"),old=try store.saveRecordedMeetingName("Old name",for:ref),page=try store.recordedMeetingPage()
        let other=try MemoryStore(root:store.root);defer {try? other.close()}
        let otherRef=try XCTUnwrap(other.recordedMeetingPage().sources.first),current=try XCTUnwrap(other.recordedMeetingDetails(for:otherRef).first)
        _ = try other.saveRecordedMeetingName("New name",for:otherRef,replacing:current)
        var published:String?
        XCTAssertThrowsError(try store.withCurrentRecordedMeetingPage(page) {published=old.name})
        XCTAssertNil(published)
    }
    func testMetadataRollbackPreservesCommittedNameNonceAndRecordingRevision()throws {
        try audio("a");let ref=try source("a"),saved=try store.saveRecordedMeetingName("Before",for:ref),before=try store.recordedMeetingRevision()
        enum OwnedRollback:Error {case stop}
        XCTAssertThrowsError(try store.withRoutineDatabase {db in try db.transaction {
            var body=try XCTUnwrap(store.get(saved.id));body.title="Rolled back";try store.insert(body)
            XCTAssertNotEqual(try store.recordedMeetingRevision(),before);throw OwnedRollback.stop
        }})
        XCTAssertEqual(try store.recordedMeetingRevision(),before);XCTAssertEqual(try store.recordedMeetingDetails(for:ref),[saved])
    }
    func testMetadataTriggerRepairDefersPayloadParsingAndKeepsCanonicalAudioUntouched()throws {
        let audio=try audio("a"),ref=try source("a"),saved=try store.saveRecordedMeetingName("Keep canonical name",for:ref)
        try store.withRoutineDatabase {db in try db.transaction {
            try db.execute("DROP TRIGGER recorded_details_source_update; DELETE FROM recorded_meeting_details")
            XCTAssertEqual(sqlite3_set_authorizer(db.handle,{_,action,table,column,_,_ in
                if action==SQLITE_READ,let table,let column,String(cString:table)=="memories",String(cString:column)=="payload" {return SQLITE_DENY};return SQLITE_OK
            },nil),SQLITE_OK)
            defer {sqlite3_set_authorizer(db.handle,nil,nil)}
            try RecordingDetailsSchema.install(db)
        }}
        let rebuilt=try XCTUnwrap(store.recordedMeetingDetails(for:ref).first)
        XCTAssertEqual(rebuilt.id,saved.id);XCTAssertEqual(rebuilt.name,saved.name);XCTAssertNotEqual(rebuilt.revision,saved.revision)
        XCTAssertEqual(try store.get("a"),audio);XCTAssertThrowsError(try store.saveRecordedMeetingName("Old cache snapshot",for:ref,replacing:saved))
    }
    func testReadyArchiveReadsAndPublicationDenyCanonicalPayloadAndAllSQLWritesWithNamesPresent()throws {
        try audio("a");let named=try store.saveRecordedMeetingName("Thin metadata",for:source("a"))
        try store.withRoutineDatabase {db in
            XCTAssertEqual(sqlite3_set_authorizer(db.handle,{_,action,table,column,_,_ in
                if [SQLITE_INSERT,SQLITE_UPDATE,SQLITE_DELETE].contains(action) {return SQLITE_DENY}
                if action==SQLITE_READ,let table,let column,String(cString:table)=="memories",String(cString:column)=="payload" {return SQLITE_DENY};return SQLITE_OK
            },nil),SQLITE_OK)
        }
        defer {_ = try? store.withRoutineDatabase {sqlite3_set_authorizer($0.handle,nil,nil)}}
        let page=try store.recordedMeetingPage();XCTAssertEqual(page.sources.count,1);_ = try store.recordedMeetingRevision();var published=false
        try store.withCurrentRecordedMeetingPage(page) {published=true};XCTAssertTrue(published)
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT name,details,revision FROM recorded_meeting_details WHERE memory_id=?");defer {sqlite3_finalize(row)};db.bind(row,1,named.id)
            XCTAssertEqual(sqlite3_step(row),SQLITE_ROW);XCTAssertEqual(db.text(row,0),named.name);XCTAssertEqual(db.text(row,2),named.revision)
            XCTAssertEqual(try JSONDecoder().decode(RecordingDetails.self,from:Data(db.text(row,1).utf8)),named.details)
        }
    }
    func testBuiltInSQLWriterRefreshesMetadataNonceAndInvalidatesPreparedNames()throws {
        try audio("a");let ref=try source("a"),first=try store.saveRecordedMeetingName("Before",for:ref),page=try store.recordedMeetingPage()
        var edited=try XCTUnwrap(store.get(first.id));edited.title="Changed through SQL";let data=try JSONEncoder().encode(edited)
        try store.withRoutineDatabase {db in
            let row=try db.statement("UPDATE memories SET payload=?,title=? WHERE id=?");defer {sqlite3_finalize(row)}
            _=data.withUnsafeBytes {sqlite3_bind_blob(row,1,$0.baseAddress,Int32(data.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self))};db.bind(row,2,edited.title);db.bind(row,3,edited.id);try db.done(row)
        }
        let current=try XCTUnwrap(store.recordedMeetingDetails(for:ref).first)
        XCTAssertEqual(current.name,edited.title);XCTAssertNotEqual(current.revision,first.revision);XCTAssertThrowsError(try store.withCurrentRecordedMeetingPage(page) {})
    }
    func testUnrelatedNotesDoNotAdvanceMetadataRevisionAndNameRenameDropsOldEmbedding()throws {
        try audio("a");let ref=try source("a"),first=try store.saveRecordedMeetingName("Before",for:ref),before=try store.recordedMeetingRevision()
        try store.insert(Memory(kind:.note,title:"Unrelated",text:"Ordinary authored note"));XCTAssertEqual(try store.recordedMeetingRevision(),before)
        var body=try XCTUnwrap(store.get(first.id));body.embedding=[1,0,0];body.embeddingModel="owned-previous-caption";try store.insert(body)
        let current=try XCTUnwrap(store.recordedMeetingDetails(for:ref).first),changed=try store.saveRecordedMeetingName("New caption",for:ref,replacing:current)
        XCTAssertNil(try store.get(changed.id)?.embedding);XCTAssertNil(try store.get(changed.id)?.embeddingModel)
    }
    func testNamePersistsWithoutChangingAudioAndFollowsNewClipsInExactSession()throws {
        let a=try audio("a"),b=try audio("b",offset:40),ref=try source("a")
        let saved=try store.saveRecordedMeetingName("  Planning discussion  ",for:ref)
        XCTAssertEqual(saved.name,"Planning discussion");XCTAssertEqual(saved.details.scope.id,"session")
        XCTAssertEqual(try store.get("a"),a);XCTAssertEqual(try store.get("b"),b);XCTAssertEqual(try store.get("a")?.evidenceHash,a.evidenceHash)
        XCTAssertEqual(try store.recordedMeetingDetails(for:ref),[saved]);XCTAssertEqual(try store.recordedMeetingEvidence(ref),a)
        try audio("new",offset:80);XCTAssertEqual(try store.recordedMeetingDetails(for:source("new")),[saved])
        try audio("unrelated",session:"other",offset:80);XCTAssertTrue(try store.recordedMeetingDetails(for:source("unrelated")).isEmpty)
        XCTAssertEqual(try store.recordedMeetingPage().sources.count,4,"The metadata record is not an audio clip")
        XCTAssertEqual(try store.get(saved.id)?.kind,.recordingMetadata)
    }
    func testRenameRequiresExactCurrentSnapshotAcrossConnections()throws {
        try audio("a");let ref=try source("a"),initial=try store.saveRecordedMeetingName("Initial",for:ref)
        let other=try MemoryStore(root:store.root);defer {try? other.close()}
        let otherRef=try XCTUnwrap(other.recordedMeetingPage().sources.first),otherInitial=try XCTUnwrap(other.recordedMeetingDetails(for:otherRef).first)
        let changed=try other.saveRecordedMeetingName("Changed elsewhere",for:otherRef,replacing:otherInitial)
        XCTAssertEqual(changed.id,initial.id)
        XCTAssertThrowsError(try store.saveRecordedMeetingName("Lost update",for:ref,replacing:initial))
        XCTAssertThrowsError(try store.saveRecordedMeetingName("Blind create",for:ref))
        let current=try XCTUnwrap(store.recordedMeetingDetails(for:ref).first);XCTAssertEqual(current.name,"Changed elsewhere")
        let final=try store.saveRecordedMeetingName("Reviewed current edit",for:ref,replacing:current)
        XCTAssertEqual(final.id,initial.id);XCTAssertNotEqual(final.revision,current.revision)
    }
    func testReopenRetainsCanonicalNameAndRefusesPriorStoreSnapshots()throws {
        try audio("a");let prior=try source("a"),saved=try store.saveRecordedMeetingName("Persistent",for:prior),location=store.root
        try store.close();store=try MemoryStore(root:location)
        let current=try source("a"),restored=try XCTUnwrap(store.recordedMeetingDetails(for:current).first)
        XCTAssertEqual(restored.id,saved.id);XCTAssertEqual(restored.revision,saved.revision);XCTAssertEqual(restored.name,saved.name)
        XCTAssertThrowsError(try store.recordedMeetingDetails(for:prior));XCTAssertThrowsError(try store.saveRecordedMeetingName("Old store edit",for:current,replacing:saved))
        XCTAssertEqual(try store.saveRecordedMeetingName("Current store edit",for:current,replacing:restored).id,saved.id)
    }
    func testUngroupedNameIsBoundToExactEvidenceVersion()throws {
        var memory=try audio("legacy",session:nil);try audio("neighbor",session:nil,offset:1)
        let ref=try source("legacy"),saved=try store.saveRecordedMeetingName("Legacy clip name",for:ref)
        XCTAssertEqual(saved.details.scope.selector,.source);XCTAssertEqual(saved.details.scope.revision,memory.evidenceHash)
        XCTAssertTrue(try store.recordedMeetingDetails(for:source("neighbor")).isEmpty)
        memory.title="Changed original evidence";try store.insert(memory)
        XCTAssertThrowsError(try store.recordedMeetingDetails(for:ref));XCTAssertTrue(try store.recordedMeetingDetails(for:source("legacy")).isEmpty)
        XCTAssertNotNil(try store.get(saved.id),"Independent user-authored metadata is not silently rewritten to cite a replacement version")
    }
    func testByteDistinctUnicodeAndNULSessionNamesRemainSeparate()throws {
        for (i,id) in ["é","e\u{301}","\u{0}group","group"].enumerated() {
            try audio("audio-\(i)",session:id);let ref=try source("audio-\(i)");_ = try store.saveRecordedMeetingName("Name \(i)",for:ref)
        }
        for i in 0..<4 {XCTAssertEqual(try store.recordedMeetingDetails(for:source("audio-\(i)")).map(\.name),["Name \(i)"])}
    }
    func testConflictingDefinitionsAreExposedAndNeverChosenByRecency()throws {
        try audio("a");let ref=try source("a"),first=try store.saveRecordedMeetingName("First",for:ref)
        var second=try XCTUnwrap(store.get(first.id));second.id="owned-conflicting-name";second.title="Second";second.timestamp=Date(timeIntervalSince1970:900)
        try store.insert(second)
        XCTAssertEqual(Set(try store.recordedMeetingDetails(for:ref).map(\.name)),["First","Second"])
        XCTAssertThrowsError(try store.saveRecordedMeetingName("Silent winner",for:ref,replacing:first))
        XCTAssertEqual(try store.get(first.id)?.title,"First");XCTAssertEqual(try store.get(second.id)?.title,"Second")
    }
    func testCurrentAudioAndMetadataPrivacyBothRefuseAccessAndMutation()throws {
        try audio("a");let ref=try source("a"),saved=try store.saveRecordedMeetingName("Allowed name",for:ref)
        var settings=AppSettings.load(root:store.root);settings.privacy.excludedApps.append("owned.audio");try settings.save(root:store.root)
        XCTAssertThrowsError(try store.recordedMeetingDetails(for:ref));XCTAssertThrowsError(try store.saveRecordedMeetingName("No bypass",for:ref,replacing:saved))
        settings.privacy.excludedApps.removeAll {$0=="owned.audio"};settings.privacy.excludedApps.append("com.oswind.desktop");try settings.save(root:store.root)
        XCTAssertThrowsError(try store.recordedMeetingDetails(for:ref));XCTAssertThrowsError(try store.saveRecordedMeetingName("No hidden overwrite",for:ref,replacing:saved))
        XCTAssertEqual(try store.get(saved.id)?.title,"Allowed name")
    }
    func testStaleDeletedRegroupedAndForeignAudioReferencesCannotNameSources()throws {
        var memory=try audio("a");let ref=try source("a")
        let other=try MemoryStore(root:store.root);defer {try? other.close()}
        XCTAssertThrowsError(try other.saveRecordedMeetingName("Foreign",for:ref))
        memory.audioSessionID="different";try store.insert(memory);XCTAssertThrowsError(try store.saveRecordedMeetingName("Stale group",for:ref))
        let latest=try source("a");try store.delete("a");try store.insert(memory);XCTAssertThrowsError(try store.saveRecordedMeetingName("Recreated",for:latest))
        XCTAssertEqual(try store.stats(includeDiskUsage:false).count,1)
    }
    func testInvalidNamesAndMixedCapturedMetadataRefuseWithoutSaving()throws {
        try audio("a");let ref=try source("a")
        for name in [""," \n ","Line\nbreak","NUL\u{0}name",String(repeating:"x",count:201),"e"+String(repeating:"\u{301}",count:5000)] {XCTAssertThrowsError(try store.saveRecordedMeetingName(name,for:ref))}
        var invalid=Memory(kind:.recordingMetadata,title:"Missing binding",text:"");XCTAssertThrowsError(try store.insert(invalid))
        invalid.recordingDetails = .init(scope:try .init(sessionID:"session"));invalid.audioPath="audio/not-captured.wav";XCTAssertThrowsError(try store.insert(invalid))
        invalid.audioPath=nil;invalid.kind = .note;XCTAssertThrowsError(try store.insert(invalid))
        invalid.kind = .recordingMetadata;invalid.text=String(repeating:"x",count:32768);XCTAssertThrowsError(try store.insert(invalid))
        XCTAssertTrue(try store.recordedMeetingDetails(for:ref).isEmpty)
    }
    func testRecordingScopeAndCalendarAssociationChangeEvidenceWithoutChangingEmbeddingText()throws {
        var value=Memory(kind:.recordingMetadata,title:"Name",text:"User label")
        value.recordingDetails = .init(scope:try .init(sessionID:"one"));let hash=value.evidenceHash,text=value.contentHash
        value.recordingDetails = .init(scope:try .init(sessionID:"two"));XCTAssertEqual(value.contentHash,text);XCTAssertNotEqual(value.evidenceHash,hash)
        let event=try MeetingOccurrence(calendarID:"calendar",seriesID:"series",originalOccurrence:Date(timeIntervalSince1970:100),start:Date(timeIntervalSince1970:100),end:Date(timeIntervalSince1970:200),title:"Private event title",participants:["Private attendee"],joinURL:URL(string:"https://owned.invalid/secret-token"))
        let link=try RecordingCalendarLink(event:event,libraryIdentity:String(repeating:"a",count:32)),data=try JSONEncoder().encode(link),string=String(decoding:data,as:UTF8.self)
        for forbidden in ["Private event title","Private attendee","secret-token","https://"] {XCTAssertFalse(string.contains(forbidden))}
        XCTAssertEqual(try JSONDecoder().decode(RecordingCalendarLink.self,from:data),link)
        XCTAssertTrue(link.matches(event,libraryIdentity:String(repeating:"a",count:32)));XCTAssertFalse(link.matches(event,libraryIdentity:String(repeating:"b",count:32)))
        let moved=try MeetingOccurrence(calendarID:event.calendarID,seriesID:event.seriesID,originalOccurrence:event.originalOccurrence,start:event.start.addingTimeInterval(30),end:event.end.addingTimeInterval(30),title:event.title,participants:event.participants,joinURL:event.joinURL)
        XCTAssertEqual(moved.id,event.id);XCTAssertFalse(link.matches(moved,libraryIdentity:link.libraryIdentity))
        let before=value.evidenceHash;value.recordingDetails = .init(scope:value.recordingDetails!.scope,calendar:link);XCTAssertNotEqual(value.evidenceHash,before)
    }
    func testMetadataDecodeRefusesUnknownVersionsAndForgedOccurrenceIdentity()throws {
        let details=RecordingDetails(scope:try .init(sessionID:"session")),data=try JSONEncoder().encode(details)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]);object["version"]=2
        XCTAssertThrowsError(try JSONDecoder().decode(RecordingDetails.self,from:JSONSerialization.data(withJSONObject:object)))
        let event=try MeetingOccurrence(calendarID:"calendar",seriesID:"series",start:Date(timeIntervalSince1970:100),end:Date(timeIntervalSince1970:200),title:"")
        let link=try RecordingCalendarLink(event:event,libraryIdentity:String(repeating:"a",count:32))
        var forged=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(link)) as? [String:Any]);forged["occurrenceID"]=String(repeating:"0",count:64)
        XCTAssertThrowsError(try JSONDecoder().decode(RecordingCalendarLink.self,from:JSONSerialization.data(withJSONObject:forged)))
        XCTAssertThrowsError(try RecordingCalendarLink(event:event,libraryIdentity:"wrong"))
    }
    func testBackupRestoreRetainsBothNamesWithoutGrantingCalendarAuthority()throws {
        try audio("grouped");try audio("legacy",session:nil,offset:1)
        let a=try store.saveRecordedMeetingName("Group",for:source("grouped")),b=try store.saveRecordedMeetingName("Legacy",for:source("legacy"))
        let archive=root.appendingPathComponent("owned.oswindbackup"),destination=root.appendingPathComponent("restored"),info=try LibraryBackup.create(store:store,destination:archive)
        XCTAssertEqual(info.memories,4);_ = try LibraryBackup.restore(archive,to:destination,expectedFingerprint:info.archiveFingerprint)
        let restored=try MemoryStore(root:destination);defer {try? restored.close()}
        let page=try restored.recordedMeetingPage()
        for (id,old) in [("grouped",a),("legacy",b)] {let ref=try XCTUnwrap(page.sources.first {$0.memoryID==id}),named=try XCTUnwrap(restored.recordedMeetingDetails(for:ref).first);XCTAssertEqual(named.id,old.id);XCTAssertEqual(named.name,old.name)}
        XCTAssertFalse(AppSettings.load(root:destination).meetings.enabled)
    }
    func testStoredCalendarAssociationSurvivesQuietRestoreWithoutReauthorizingCalendar()throws {
        try audio("a");let ref=try source("a"),saved=try store.saveRecordedMeetingName("Explicit user label",for:ref)
        let library=try store.authorizeMeetingLibrary()
        var settings=AppSettings.load(root:store.root);settings.meetings.enabled=true;settings.meetings.calendarIDs=["owned-calendar"];settings.meetings.boundLibrary=library;try settings.save(root:store.root)
        XCTAssertTrue(settings.meetings.admits(libraryIdentity:library))
        let event=try MeetingOccurrence(calendarID:"owned-calendar",seriesID:"owned-series",originalOccurrence:Date(timeIntervalSince1970:5000),start:Date(timeIntervalSince1970:6000),end:Date(timeIntervalSince1970:6600),title:"Do not copy event title",participants:["Do not copy attendee"],joinURL:URL(string:"https://owned.invalid/do-not-copy-token"))
        let link=try RecordingCalendarLink(event:event,libraryIdentity:library)
        var record=try XCTUnwrap(store.get(saved.id));record.recordingDetails = .init(scope:saved.details.scope,calendar:link);try store.insert(record)
        let archive=root.appendingPathComponent("linked.oswindbackup"),destination=root.appendingPathComponent("linked-restored"),info=try LibraryBackup.create(store:store,destination:archive)
        _=try LibraryBackup.restore(archive,to:destination,expectedFingerprint:info.archiveFingerprint)
        let restored=try MemoryStore(root:destination);defer {try? restored.close()}
        let restoredSource=try XCTUnwrap(restored.recordedMeetingPage().sources.first),restoredName=try XCTUnwrap(restored.recordedMeetingDetails(for:restoredSource).first)
        XCTAssertEqual(restoredName.id,saved.id);XCTAssertEqual(restoredName.details.calendar,link)
        let quiet=AppSettings.load(root:destination).meetings
        XCTAssertFalse(quiet.enabled);XCTAssertNil(quiet.boundLibrary);XCTAssertTrue(quiet.calendarIDs.isEmpty);XCTAssertFalse(quiet.admits(libraryIdentity:link.libraryIdentity))
        XCTAssertEqual(try restored.get("a")?.timestamp,Date(timeIntervalSince1970:100),"The explicitly linked event date does not rewrite recording time")
        let encoded=String(decoding:try JSONEncoder().encode(try XCTUnwrap(restored.get(saved.id))),as:UTF8.self)
        for forbidden in ["Do not copy event title","Do not copy attendee","do-not-copy-token"] {XCTAssertFalse(encoded.contains(forbidden))}
    }
}
