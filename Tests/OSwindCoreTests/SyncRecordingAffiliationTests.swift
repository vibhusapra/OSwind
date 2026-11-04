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
        guard case .source(let originalBody)=original.body else {return XCTFail("Missing audio")}
        let normalized=try originalBody.projectedMemory(id:"projected",paths:[:]) {_ in throw OSwindError.invalid("No parents")}
        XCTAssertNotEqual(normalized.evidenceHash,audio.evidenceHash,"This control needs distinct native and wire evidence domains")
        audio.text="Authored replacement speech";audio.transcript=nil;try store.insert(audio);_=try finish()
        try store.setFavorite(caption.id,value:true)
        do {_=try finish()}catch {XCTFail("Native affiliation proof must retain the admitted wire version: \(error)");return}
        guard case .source(let body)=try recordingPacket(caption.id).body else {return XCTFail("Missing metadata")}
        XCTAssertEqual(body.recordingDetails?.scope.source,try original.reference)
    }
}
