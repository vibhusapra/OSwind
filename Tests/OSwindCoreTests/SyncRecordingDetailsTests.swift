import XCTest
@testable import OSwindCore

final class SyncRecordingDetailsTests:XCTestCase {
    let origin="00000000-0000-0000-0000-000000009101"
    let peer="00000000-0000-0000-0000-000000009102"
    func identity(_ number:Int)throws->SyncObjectIdentity {try .init(table:.source,origin:origin,lifetime:String(format:"00000000-0000-0000-0000-%012d",number))}
    func audio()throws->(Memory,SyncPortableRecord) {
        let memory=Memory(id:"private-local-clip",timestamp:Date(timeIntervalSince1970:100),kind:.audio,app:"Owned",title:"Original",text:"Authored speech")
        return (memory,try .init(identity:identity(1),body:.source(.init(memory:memory,origin:origin,media:[]) {_,_ in throw OSwindError.invalid("No parent")})))
    }
    func metadata(_ scope:RecordingScope)->Memory {
        var memory=Memory(id:"private-local-caption",kind:.recordingMetadata,app:"OSwind",title:"Reviewed recording name",text:"User-authored name")
        memory.recordingDetails = .init(scope:scope);return memory
    }
    func testSessionUsesAudioOriginRatherThanCaptionOriginAndReexportsUnchanged()throws {
        let token=try SyncSessionToken(origin:origin,localID:"private-session")
        let memory=metadata(try .init(sessionID:"private-session"))
        let body=try SyncSourceBody(memory:memory,origin:peer,media:[],recordingSession:{id in XCTAssertEqual(id,"private-session");return token}) {_,_ in throw OSwindError.invalid("No clip")}
        XCTAssertEqual(body.recordingDetails?.scope.session,token);XCTAssertEqual(body.sourceReferences,[])
        let restored=try body.projectedMemory(id:"receiver-caption",paths:[:]) {_ in throw OSwindError.invalid("No clip")}
        XCTAssertEqual(restored.recordingDetails?.scope.id,token.localProjection)
        let again=try SyncSourceBody(memory:restored,origin:peer,media:[]) {_,_ in throw OSwindError.invalid("No clip")}
        XCTAssertEqual(try SyncProtocolLimits.encode(again),try SyncProtocolLimits.encode(body))
        let bytes=String(decoding:try SyncProtocolLimits.encode(body),as:UTF8.self)
        XCTAssertFalse(bytes.contains("private-session"));XCTAssertFalse(bytes.contains("private-local-caption"))
    }
    func testSingleClipCarriesExactWireVersionAndRemapsLocalID()throws {
        let (clip,record)=try audio(),reference=try record.reference
        let body=try SyncSourceBody(memory:metadata(.init(sourceID:clip.id,revision:clip.evidenceHash)),origin:peer,media:[]) {id,revision in
            XCTAssertEqual(id,clip.id);XCTAssertEqual(revision,clip.evidenceHash);return reference
        }
        let packet=try SyncPortableRecord(identity:identity(2),body:.source(body))
        XCTAssertEqual(packet.dependencies,[.init(identity:record.identity,content:reference.content)])
        try packet.validateDependencies {id,version in XCTAssertEqual(id,record.identity);XCTAssertEqual(version,reference.content);return record}
        let projected=try body.projectedMemory(id:"receiver-caption",paths:[:]) {ref in XCTAssertEqual(ref,reference);return("receiver-clip",clip.evidenceHash)}
        XCTAssertEqual(projected.recordingDetails?.scope,try .init(sourceID:"receiver-clip",revision:clip.evidenceHash))
        XCTAssertFalse(String(decoding:try packet.encoded(),as:UTF8.self).contains(clip.id))
        XCTAssertEqual(try SyncPortableRecord.decode(packet.encoded()),packet)
    }
    func testMissingClipNeverFallsBackAndUnavailableNeverCallsResolver()throws {
        let (clip,_)=try audio()
        XCTAssertThrowsError(try SyncSourceBody(memory:metadata(.init(sourceID:clip.id,revision:clip.evidenceHash)),origin:origin,media:[]) {_,_ in throw OSwindError.unavailable("Exact original missing")})
        let body=try SyncSourceBody(memory:metadata(.unavailable),origin:origin,media:[]) {_,_ in XCTFail("Unavailable must not resolve evidence");throw OSwindError.invalid("No evidence")}
        XCTAssertEqual(try body.projectedMemory(id:"caption",paths:[:]) {_ in XCTFail("Unavailable must not resolve evidence");return("wrong","wrong")}.recordingDetails?.scope,.unavailable)
    }
    func testNonAudioDependencyAndSelfReferenceRefuse()throws {
        let (clip,_)=try audio()
        var note=clip;note.kind = .note
        let record=try SyncPortableRecord(identity:identity(1),body:.source(.init(memory:note,origin:origin,media:[]) {_,_ in throw OSwindError.invalid("No parent")}))
        let body=try SyncSourceBody(memory:metadata(.init(sourceID:clip.id,revision:clip.evidenceHash)),origin:origin,media:[]) {_,_ in try record.reference}
        let packet=try SyncPortableRecord(identity:identity(2),body:.source(body))
        XCTAssertThrowsError(try packet.validateDependencies {_,_ in record})
        XCTAssertThrowsError(try body.validateSourceParents([record]))
        XCTAssertThrowsError(try SyncPortableRecord(identity:record.identity,body:.source(body)))
    }
    func testWrongKindMissingDetailsAndCapturedAssetsRefuse()throws {
        var value=metadata(.unavailable);value.kind = .note
        XCTAssertThrowsError(try SyncSourceBody(memory:value,origin:origin,media:[]) {_,_ in throw OSwindError.invalid("No evidence")})
        value.kind = .recordingMetadata;value.recordingDetails=nil
        XCTAssertThrowsError(try SyncSourceBody(memory:value,origin:origin,media:[]) {_,_ in throw OSwindError.invalid("No evidence")})
        value=metadata(.unavailable);value.audioPath="audio/capture.wav"
        XCTAssertThrowsError(try SyncSourceBody(memory:value,origin:origin,media:[]) {_,_ in throw OSwindError.invalid("No evidence")})
    }
    func testExistingSourceFormatOmitsOptionalRecordingField()throws {
        let (_,record)=try audio(),bytes=try record.encoded()
        XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("recordingDetails"))
        XCTAssertEqual(try SyncPortableRecord.decode(bytes).encoded(),bytes)
    }
    func testCalendarReferenceRemainsBoundToReviewedLibraryAndOmitsEventContents()throws {
        let library=String(repeating:"a",count:32),other=String(repeating:"b",count:32)
        let event=try MeetingOccurrence(calendarID:"owned-calendar",seriesID:"owned-series",start:Date(timeIntervalSince1970:500),end:Date(timeIntervalSince1970:600),title:"Private event title",participants:["Private attendee"],joinURL:URL(string:"https://owned.invalid/private-join-token"))
        let link=try RecordingCalendarLink(event:event,libraryIdentity:library)
        var memory=metadata(.unavailable);memory.recordingDetails = .init(scope:.unavailable,calendar:link)
        let body=try SyncSourceBody(memory:memory,origin:origin,media:[]) {_,_ in throw OSwindError.invalid("No source")}
        let projected=try body.projectedMemory(id:"peer-caption",paths:[:]) {_ in throw OSwindError.invalid("No source")}
        XCTAssertEqual(projected.recordingDetails?.calendar,link)
        XCTAssertFalse(try XCTUnwrap(projected.recordingDetails?.calendar).matches(event,libraryIdentity:other))
        let bytes=String(decoding:try SyncProtocolLimits.encode(body),as:UTF8.self)
        for content in [event.title,"Private attendee","private-join-token"] {XCTAssertFalse(bytes.contains(content))}
        XCTAssertNotEqual(projected.timestamp,event.start,"A caption does not inherit a calendar recording timestamp")
    }
    func testCalendarOpaqueIdentifiersStillPassCurrentSecretPolicyBeforeSync()throws {
        let event=try MeetingOccurrence(calendarID:"api_key=owned-calendar-fixture-secret",seriesID:"owned-series",start:Date(timeIntervalSince1970:500),end:Date(timeIntervalSince1970:600),title:"")
        var memory=metadata(.unavailable);memory.recordingDetails = .init(scope:.unavailable,calendar:try .init(event:event,libraryIdentity:String(repeating:"a",count:32)))
        let policy=SyncServicePolicy(settings:AppSettings())
        XCTAssertThrowsError(try policy.admit(memory))
        let record=try SyncPortableRecord(identity:identity(2),body:.source(.init(memory:memory,origin:origin,media:[]) {_,_ in throw OSwindError.invalid("No source")}))
        XCTAssertThrowsError(try policy.admit(record))
    }
    func testUnknownDetailsVersionAndDetailsOnOldKindRefuseDecodedWire()throws {
        let body=try SyncSourceBody(memory:metadata(.unavailable),origin:origin,media:[]) {_,_ in throw OSwindError.invalid("No source")}
        let encoded=try SyncProtocolLimits.encode(body),json=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        var unknown=json,details=try XCTUnwrap(json["recordingDetails"] as? [String:Any]);details["version"]=2;unknown["recordingDetails"]=details
        let unknownBody=try JSONDecoder().decode(SyncSourceBody.self,from:JSONSerialization.data(withJSONObject:unknown))
        XCTAssertThrowsError(try unknownBody.validate())
        var oldKind=json;oldKind["kind"]="note"
        let wrongBody=try JSONDecoder().decode(SyncSourceBody.self,from:JSONSerialization.data(withJSONObject:oldKind))
        XCTAssertThrowsError(try wrongBody.validate())
    }
}
