import XCTest
@testable import OSwindCore

extension SyncIncomingSourceTests {
    func testIncomingRecordingNameChangedOwnerKindKeepsReplacementNoteOutsideAudioScope()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID)
        defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var audio=Memory(id:"kind-changing-clip",timestamp:now,kind:.audio,app:"Owned",title:"Original capture",text:"Authored original speech")
        try a.insert(audio);try drain(a,ac)
        let audioOp=try XCTUnwrap(ac.journal.outbox().first),original=try packet(audioOp,ac)
        let clipID=try receive(audioOp,original,b,bc,fetch:{_ in original})
        let source=try XCTUnwrap(a.recordedMeetingPage().sources.first),saved=try a.saveRecordedMeetingName("Original audio label",for:source)
        try drain(a,ac)
        let identity=try ac.catalog.localIdentity(.source,primary:[.text(Data(saved.id.utf8))])
        let nameOp=try XCTUnwrap(ac.journal.outbox().first {$0.key == (try? identity.key)}),name=try packet(nameOp,ac)
        let nameID=try receive(nameOp,name,b,bc,fetch:{ref in XCTAssertEqual(ref,try original.reference);return original})
        let nativeName=try XCTUnwrap(b.get(nameID))
        audio.kind = .note;audio.text="Independent replacement note";try a.insert(audio);try drain(a,ac)
        let noteOp=try XCTUnwrap(ac.journal.outbox().first {$0.key==audioOp.key && $0.content != audioOp.content}),note=try packet(noteOp,ac)
        _=try receive(noteOp,note,b,bc,fetch:{_ in original})
        let current=try XCTUnwrap(b.get(clipID))
        XCTAssertEqual(current.kind,.note);XCTAssertEqual(current.text,audio.text)
        XCTAssertEqual(try b.get(nameID),nativeName)
        XCTAssertFalse(try XCTUnwrap(nativeName.recordingDetails?.scope).matches(current))
        XCTAssertTrue(try b.recordedMeetingPage().sources.isEmpty)
        XCTAssertThrowsError(try a.saveRecordedMeetingName("Must not label the replacement note",for:source,replacing:saved))
        try a.setFavorite(saved.id,value:true);try drain(a,ac)
        let lateOp=try XCTUnwrap(ac.journal.outbox().first {$0.key==nameOp.key && $0.content != nameOp.content}),late=try packet(lateOp,ac)
        _=try receive(lateOp,late,b,bc,fetch:{ref in XCTAssertEqual(ref,try original.reference);return original})
        let lateName=try XCTUnwrap(b.get(nameID))
        XCTAssertEqual(try b.get(clipID),current,"Late metadata must not rewrite a note into captured audio")
        XCTAssertFalse(try XCTUnwrap(lateName.recordingDetails?.scope).matches(current))
        XCTAssertTrue(try b.recordedMeetingPage().sources.isEmpty)
        XCTAssertEqual(try count(b,"memories"),2)
        XCTAssertEqual(try bc.resolve(late.identity,content:nil,admit:{_ in}),late)
    }
    func testIncomingRecordingNameSessionErasureRetiresKnownNameOnlyAfterLastClipWithoutNameTombstone()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var first=Memory(id:"session-first",timestamp:now,kind:.audio,app:"Owned",title:"First",text:"First authored speech");first.audioSessionID="shared-owned-session"
        var second=first;second.id="session-second";second.timestamp=now.addingTimeInterval(30);second.text="Second authored speech"
        try a.insert(first);try a.insert(second)
        let source=try XCTUnwrap(a.recordedMeetingPage().sources.first),name=try a.saveRecordedMeetingName("Authored session name",for:source);try drain(a,ac)
        let nameIdentity=try ac.catalog.localIdentity(.source,primary:[.text(Data(name.id.utf8))]),nameKey=try nameIdentity.key
        for operation in try ac.journal.outbox() {
            let body=try packet(operation,ac)
            _=try receive(operation,body,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
        }
        let localName=try XCTUnwrap(bc.catalog.object(nameIdentity)?.primary?.first)
        guard case .text(let bytes)=localName,let nameID=String(data:bytes,encoding:.utf8) else {return XCTFail("No projected name")}
        let through=try XCTUnwrap(ac.journal.outbox().last).dot.counter
        try a.delete(first.id);try drain(a,ac)
        for operation in try ac.journal.outbox(after:through) {try receiveDeletion(operation,b,bc)}
        XCTAssertNotNil(try b.get(nameID));XCTAssertFalse(try bc.journal.state(for:nameKey).isDeleted)
        // A valid source tombstone alone must retire the known dependent name.
        // Do not depend on a later separate name tombstone from the producer.
        let secondIdentity=try ac.catalog.localIdentity(.source,primary:[.text(Data(second.id.utf8))]),deleted=try ac.journal.delete(key:secondIdentity.key)
        try receiveDeletion(deleted,b,bc)
        XCTAssertNil(try b.get(nameID));XCTAssertTrue(try bc.journal.state(for:nameKey).isDeleted)
        XCTAssertTrue(try XCTUnwrap(bc.catalog.object(nameIdentity)).deleted)
        XCTAssertTrue(try bc.journal.outbox().contains {$0.key==nameKey && $0.content==nil},"The derived name retirement must have a durable journal barrier")
        try b.withRoutineDatabase {try RecordingAffiliationStore.checkAccounting($0)}
    }
    func testIncomingRecordingMetadataPolicyDenialRollsBackReceiptAndDerivedName()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var memory=Memory(id:"owned-caption",kind:.recordingMetadata,app:"OSwind",title:"Private browsing caption",text:"User-authored label")
        memory.recordingDetails = .init(scope:.unavailable);try a.insert(memory);try drain(a,ac)
        let operation=try XCTUnwrap(ac.journal.outbox().first),record=try packet(operation,ac),admission=try b.mediaWriteLease();defer {admission.release()}
        let policy=SyncServicePolicy(settings:AppSettings())
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:policy.admit,pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        XCTAssertThrowsError(try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in
            _=try writer.apply(record,admission:admission,fetchExactSource:{_ in throw OSwindError.invalid("No evidence dependency")})
        })
        XCTAssertEqual(try count(b,"memories"),0);XCTAssertEqual(try count(b,"recorded_meeting_details"),0)
        XCTAssertEqual(try count(b,"personal_sync_versions"),0);XCTAssertEqual(try bc.journal.outbox().count,0)
        XCTAssertNil(try bc.catalog.object(record.identity));XCTAssertTrue(try bc.journal.state(for:record.identity.key).heads.isEmpty)
    }
    func testIncomingRecordingNameRemapsExactClipAndRetainsOldVersionAfterAudioChanges()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var audio=Memory(id:"owned-single-clip",timestamp:now,kind:.audio,app:"Owned",title:"Original clip",text:"Authored first speech")
        try a.insert(audio);try drain(a,ac)
        let audioOp=try XCTUnwrap(ac.journal.outbox().first),original=try packet(audioOp,ac)
        let clipID=try receive(audioOp,original,b,bc,fetch:{_ in original})
        let source=try XCTUnwrap(a.recordedMeetingPage().sources.first),saved=try a.saveRecordedMeetingName("Reviewed caption",for:source)
        try drain(a,ac)
        let metadataIdentity=try ac.catalog.localIdentity(.source,primary:[.text(Data(saved.id.utf8))])
        let metadataOp=try XCTUnwrap(ac.journal.outbox().first {$0.key == (try? metadataIdentity.key)}),metadata=try packet(metadataOp,ac)
        let captionID=try receive(metadataOp,metadata,b,bc,fetch:{ref in XCTAssertEqual(ref,try original.reference);return original})
        let projected=try XCTUnwrap(b.get(captionID))
        XCTAssertEqual(projected.recordingDetails?.scope,try .init(sourceID:clipID,revision:audio.evidenceHash))
        XCTAssertEqual(try b.get(clipID)?.text,audio.text);XCTAssertEqual(try bc.resolve(metadata.identity,content:nil,admit:{_ in}),metadata)
        XCTAssertEqual(try b.recordedMeetingDetails(for:XCTUnwrap(b.recordedMeetingPage().sources.first)).map(\.name),["Reviewed caption"])
        audio.text="Authored changed speech";try a.insert(audio);try drain(a,ac)
        let updatedOp=try XCTUnwrap(ac.journal.outbox().first {$0.key==audioOp.key && $0.content != audioOp.content}),updated=try packet(updatedOp,ac)
        _=try receive(updatedOp,updated,b,bc,fetch:{_ in original})
        let fresh=try XCTUnwrap(b.recordedMeetingPage().sources.first)
        XCTAssertTrue(try b.recordedMeetingDetails(for:fresh).isEmpty,"An old clip name must not attach to changed evidence")
        XCTAssertEqual(try b.get(captionID),projected,"Authored metadata remains independently stored")
        try b.setFavorite(captionID,value:true);try drain(b,bc)
        let republished=try bc.resolve(metadata.identity,content:nil,admit:{_ in})
        guard case .source(let body)=republished.body else {return XCTFail("Missing caption body")}
        XCTAssertEqual(body.recordingDetails?.scope.source,try original.reference,"Metadata edits must retain the original clip version")
        let archival=try b.withRoutineDatabase {db in try b.historicalCatalog(db).adopt(republished.reference,cache:bc,pathsFor:{_,_ in [:]},admit:{_ in},verifyMedia:{_,_,_ in})}
        XCTAssertEqual(archival.memory.kind,.recordingMetadata)
        XCTAssertNotEqual(archival.memory.recordingDetails?.scope.id,clipID,"Historical metadata must use its exact original, not current audio")
        XCTAssertEqual(try b.withRoutineDatabase {db in try b.historicalCatalog(db).read(archival.handle,sourceID:captionID,verifyMedia:{_,_,_ in}).memory},archival.memory)
        let through=try XCTUnwrap(ac.journal.outbox().last).dot.counter
        try a.delete(audio.id);try drain(a,ac)
        for operation in try ac.journal.outbox(after:through) {try receiveDeletion(operation,b,bc)}
        XCTAssertNil(try b.get(clipID));XCTAssertNil(try b.get(captionID),"Peer source erasure must remove dependent names, including locally edited versions")
        XCTAssertEqual(try count(b,"recorded_meeting_details"),0)
        XCTAssertThrowsError(try b.withRoutineDatabase {db in try b.historicalCatalog(db).read(archival.handle,sourceID:captionID,verifyMedia:{_,_,_ in})})
    }

    func testIncomingRecordingNameBeforeAudioQueuesAndReplaysWithExactRecordWithoutEcho()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let audio=Memory(id:"owned-clip",timestamp:now,kind:.audio,app:"Owned",title:"Original",text:"Authored speech")
        try a.insert(audio);try drain(a,ac)
        let audioOp=try XCTUnwrap(ac.journal.outbox().first),original=try packet(audioOp,ac)
        let ref=try XCTUnwrap(a.recordedMeetingPage().sources.first),saved=try a.saveRecordedMeetingName("Caption",for:ref);try drain(a,ac)
        let identity=try ac.catalog.localIdentity(.source,primary:[.text(Data(saved.id.utf8))]),key=try identity.key
        let operation=try XCTUnwrap(ac.journal.outbox().first {$0.key==key}),metadata=try packet(operation,ac)
        let held=try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in XCTFail("A causal successor must remain queued")}
        XCTAssertEqual(held.applied,0)
        XCTAssertEqual(try count(b,"memories"),0);XCTAssertEqual(try count(b,"historical_evidence"),0);XCTAssertEqual(try bc.journal.outbox().count,0)
        let admission=try b.mediaWriteLease();defer {admission.release()}
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        var projected=[String:String]()
        let replay=try bc.journal.receive(audioOp,contentAvailable:{_ in true}) {change in
            let record=change.revision.key==audioOp.key ? original:metadata
            XCTAssertEqual(change.revision.content,try record.reference.content)
            projected[try record.identity.key.digest]=try writer.apply(record,admission:admission,fetchExactSource:{_ in original})
        }
        XCTAssertEqual(replay.applied,2)
        let localAudio=try XCTUnwrap(projected[audioOp.key.digest]),localCaption=try XCTUnwrap(projected[key.digest])
        XCTAssertEqual(try b.get(localCaption)?.recordingDetails?.scope.id,localAudio)
        XCTAssertEqual(try count(b,"memories"),2);XCTAssertEqual(try bc.journal.outbox().count,0)
        let duplicate=try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in XCTFail("A duplicate must not project twice")}
        XCTAssertEqual(duplicate.applied,0)
    }
}
