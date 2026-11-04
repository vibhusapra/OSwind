import XCTest
@testable import OSwindCore

extension SyncIncomingSourceTests {
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
