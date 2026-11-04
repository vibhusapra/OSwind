import XCTest
@testable import OSwindCore

extension SyncOutgoingTests {
    func namedClip(model:String?=nil)throws->(Memory,Memory) {
        var audio=Memory(id:"owned-named-clip",timestamp:now,kind:.audio,app:"Owned",title:"Authored clip",text:"Authored original speech")
        if let model {audio.transcript = .init(text:audio.text,duration:30,segments:[.init(start:0,end:30,text:audio.text)],model:model)}
        try store.insert(audio)
        let source=try XCTUnwrap(store.recordedMeetingPage().sources.first),name=try store.saveRecordedMeetingName("Authored label",for:source)
        return(audio,try XCTUnwrap(store.get(name.id)))
    }
    func recordingPacket(_ id:String)throws->SyncPortableRecord {
        let identity=try cache.catalog.localIdentity(.source,primary:[.text(Data(id.utf8))])
        return try cache.resolve(identity,content:nil,admit:{_ in})
    }
    func testRecordingMetadataKeepsExactWireVersionAcrossEquivalentAudioWireChanges()throws {
        let (audio,caption)=try namedClip();try install();_=try finish()
        let firstAudio=try recordingPacket(audio.id),firstCaption=try recordingPacket(caption.id)
        try store.setFavorite(audio.id,value:true);_=try finish()
        let changed=try recordingPacket(audio.id)
        XCTAssertNotEqual(try changed.reference,try firstAudio.reference);XCTAssertEqual(try store.get(audio.id)?.evidenceHash,audio.evidenceHash)
        try store.withRoutineDatabase {db in
            for record in [firstAudio,changed] {_=try store.historicalCatalog(db).adopt(record.reference,cache:cache,pathsFor:{_,_ in [:]},admit:{_ in},verifyMedia:{_,_,_ in})}
        }
        try store.setFavorite(caption.id,value:true)
        do {_=try finish()}catch {XCTFail("A proven caption affiliation must survive equivalent audio versions: \(error)");return}
        guard case .source(let body)=try recordingPacket(caption.id).body,case .source(let before)=firstCaption.body else {return XCTFail("Missing metadata body")}
        XCTAssertEqual(body.recordingDetails?.scope.source,before.recordingDetails?.scope.source)
        XCTAssertEqual(body.recordingDetails?.scope.source,try firstAudio.reference)
    }
    func testRecordingMetadataRealRenameRetainsAffiliationAfterEquivalentAudioWireChange()throws {
        let (audio,caption)=try namedClip();try install();_=try finish()
        let original=try recordingPacket(audio.id)
        try store.setFavorite(audio.id,value:true);_=try finish()
        XCTAssertNotEqual(try recordingPacket(audio.id).reference,try original.reference)
        let source=try XCTUnwrap(store.recordedMeetingPage().sources.first),expected=try XCTUnwrap(store.recordedMeetingDetails(for:source).first)
        _=try store.saveRecordedMeetingName("Renamed through the native API",for:source,replacing:expected);_=try finish()
        guard case .source(let body)=try recordingPacket(caption.id).body else {return XCTFail("Missing renamed metadata")}
        XCTAssertEqual(body.title,"Renamed through the native API")
        XCTAssertEqual(body.recordingDetails?.scope.source,try original.reference,"Changing a user-authored name must not replace its admitted source affiliation")
    }
    func testRecordingMetadataLostBeforeFirstEnrollmentProjectsUnavailableAndDoesNotBlockUnrelatedRecords()throws {
        var (audio,caption)=try namedClip();let original=caption.recordingDetails
        audio.text="Authored changed speech before enrollment";try store.insert(audio);try seed("independent","Independent authored note")
        try install()
        do {_=try finish()}catch {XCTFail("Unavailable authored metadata must not stall unrelated publication: \(error)");return}
        guard case .source(let body)=try recordingPacket(caption.id).body else {return XCTFail("Missing metadata body")}
        XCTAssertEqual(body.recordingDetails?.scope.selector,.unavailable);XCTAssertTrue(body.sourceReferences.isEmpty)
        XCTAssertEqual(try store.get(caption.id)?.recordingDetails,original,"Export must not rewrite the authored native association")
        XCTAssertEqual(try recordingPacket("independent").identity.table,.source)
        XCTAssertEqual(try cache.journal.outbox().count,3)
    }
    func testRecordingMetadataRetainsWireAffiliationWhenNativeModelProvenanceWasNormalized()throws {
        var (audio,caption)=try namedClip(model:"/Users/OWNED-AUTHORED-FIXTURE/local-model");try install();_=try finish()
        let original=try recordingPacket(audio.id)
        guard case .source(let firstCaption)=try recordingPacket(caption.id).body else {return XCTFail("Missing initial metadata")}
        XCTAssertEqual(firstCaption.recordingDetails?.scope.source,try original.reference,"Initial native-to-wire source link must be prepared")
        XCTAssertEqual(try cache.recordingSourceBinding(XCTUnwrap(store.get(caption.id)),admit:{_ in}),.available(try original.reference),"Initial stored metadata must prove its native association")
        guard case .source(let originalBody)=original.body else {return XCTFail("Missing audio")}
        let normalized=try originalBody.projectedMemory(id:"projected",paths:[:]) {_ in throw OSwindError.invalid("No parents")}
        XCTAssertNotEqual(normalized.evidenceHash,audio.evidenceHash,"This control needs distinct native and wire evidence domains")
        try store.setFavorite(audio.id,value:true);_=try finish()
        try store.setFavorite(caption.id,value:true)
        do {_=try finish()}catch {XCTFail("Native affiliation proof must retain the admitted wire version: \(error)");return}
        guard case .source(let body)=try recordingPacket(caption.id).body else {return XCTFail("Missing metadata")}
        XCTAssertEqual(body.recordingDetails?.scope.source,try original.reference)
    }
    func testRecordingMetadataTranscriptReplacementCannotRevivePurgedCachedAudioVersion()throws {
        var (audio,caption)=try namedClip(model:"/Users/OWNED-AUTHORED-FIXTURE/local-model");try install();_=try finish()
        let original=try recordingPacket(audio.id),nativeAssociation=caption.recordingDetails
        audio.text="Authored replacement speech";audio.transcript=nil;try store.insert(audio);try seed("independent","Independent note after transcript replacement");_=try finish()
        XCTAssertNil(try cache.record(original.reference,admit:{_ in}),"Native transcript replacement must retain its existing old-cache purge behavior")
        try store.setFavorite(caption.id,value:true);_=try finish()
        guard case .source(let body)=try recordingPacket(caption.id).body else {return XCTFail("Missing metadata")}
        XCTAssertEqual(body.recordingDetails?.scope.selector,.unavailable);XCTAssertTrue(body.sourceReferences.isEmpty)
        XCTAssertEqual(try store.get(caption.id)?.recordingDetails,nativeAssociation)
        XCTAssertEqual(try recordingPacket("independent").identity.table,.source)
        XCTAssertNil(try cache.record(original.reference,admit:{_ in}),"A user-authored name must not reconstruct lost audio evidence")
    }
    func testRecordingMetadataUnavailableDoesNotAttachWhenAudioLaterReusesMatchingEvidence()throws {
        var (audio,caption)=try namedClip();let original=audio
        audio.text="Changed before enrollment";try store.insert(audio);try install();_=try finish()
        guard case .source(let unavailable)=try recordingPacket(caption.id).body else {return XCTFail("Missing metadata")}
        XCTAssertEqual(unavailable.recordingDetails?.scope.selector,.unavailable)
        try store.insert(original);_=try finish();try store.setFavorite(caption.id,value:true);_=try finish()
        XCTAssertEqual(try store.get(original.id)?.evidenceHash,original.evidenceHash)
        guard case .source(let after)=try recordingPacket(caption.id).body else {return XCTFail("Missing metadata")}
        XCTAssertEqual(after.recordingDetails?.scope.selector,.unavailable,"A matching later hash cannot revive a previously unavailable affiliation")
    }
    func testRecordingMetadataExplicitDifferentNativeTargetCannotReuseOldAffiliation()throws {
        let (audio,caption)=try namedClip();try install();_=try finish()
        let old=try recordingPacket(audio.id)
        var other=audio;other.id="explicit-other-clip";try store.insert(other);_=try finish()
        let replacement=try recordingPacket(other.id);XCTAssertEqual(other.evidenceHash,audio.evidenceHash)
        var changed=caption;changed.recordingDetails = .init(scope:try .init(sourceID:other.id,revision:other.evidenceHash));try store.insert(changed);_=try finish()
        guard case .source(let body)=try recordingPacket(caption.id).body else {return XCTFail("Missing metadata")}
        XCTAssertEqual(body.recordingDetails?.scope.source,try replacement.reference);XCTAssertNotEqual(body.recordingDetails?.scope.source,try old.reference)
    }
    func testRecordingMetadataReentrantRootAndTargetEditsRefuseAndRollbackAffiliation()throws {
        let (audio,caption)=try namedClip();try install();_=try finish();try store.setFavorite(caption.id,value:true)
        let current=try XCTUnwrap(store.get(caption.id)),owner=try cache.catalog.localIdentity(.source,primary:[.text(Data(caption.id.utf8))]),target=try cache.catalog.localIdentity(.source,primary:[.text(Data(audio.id.utf8))])
        for identity in [owner,target] {
            var mutated=false
            XCTAssertThrowsError(try cache.recordingSourceBinding(current,admit:{record in
                if !mutated,record.identity==identity {mutated=true;try self.store.setFavorite(identity==owner ? caption.id:audio.id,value:identity==owner ? false:true)}
            }))
            XCTAssertTrue(mutated);XCTAssertEqual(try store.get(caption.id),current);XCTAssertEqual(try store.get(audio.id),audio)
        }
    }
    func testRecordingMetadataPolicyFailuresNeverBecomeUnavailable()throws {
        let (audio,caption)=try namedClip();try install();_=try finish()
        XCTAssertThrowsError(try cache.recordingSourceBinding(XCTUnwrap(store.get(caption.id)),admit:{_ in throw SyncPublicationPolicyDenied()})) {XCTAssertTrue($0 is SyncPublicationPolicyDenied)}
        XCTAssertThrowsError(try cache.currentRecordingSource(localID:audio.id,revision:audio.evidenceHash,prepare:{_ in},admit:{_ in throw SyncPublicationPolicyDenied()})) {XCTAssertTrue($0 is SyncPublicationPolicyDenied)}
    }
    func testRecordingMetadataMissingOwnerProjectsUnavailableWithoutInventingAnAudioIdentity()throws {
        var caption=Memory(id:"missing-owner-caption",kind:.recordingMetadata,app:"OSwind",title:"Authored name",text:"User-authored name")
        caption.recordingDetails = .init(scope:try .init(sourceID:"missing-audio-owner",revision:"authored-unavailable-revision"));try store.insert(caption);try install();_=try finish()
        guard case .source(let body)=try recordingPacket(caption.id).body else {return XCTFail("Missing metadata")}
        XCTAssertEqual(body.recordingDetails?.scope.selector,.unavailable)
        XCTAssertNil(try cache.catalog.preparedIdentity(.source,primary:[.text(Data("missing-audio-owner".utf8))]))
        XCTAssertEqual(try store.stats(includeDiskUsage:false).count,1)
    }
}
