import XCTest
@testable import OSwindCore

final class SpeakerAttributionTests:XCTestCase {
    func transcript(_ spans:[(Double,Double)],duration:Double=10) -> SpeechTranscript { SpeechTranscript(text:"Synthetic meeting evidence",duration:duration,segments:spans.map { TranscriptSegment(start:$0.0,end:$0.1,text:"word") },model:"fixture") }
    func testOrderedAnonymousLabelsAndUncoveredWords() throws {
        let source=transcript([(0,1),(2,3),(5,6),(8,9)])
        let turns=[SpeakerTurn(start:0,end:1,speaker:"z"),SpeakerTurn(start:2,end:3,speaker:"a"),SpeakerTurn(start:5,end:6,speaker:"z")]
        let value=try SpeakerAttribution.attach(turns,to:source,model:"fixture")
        XCTAssertEqual(value.segments.map(\.speaker),["Speaker 1","Speaker 2","Speaker 1",nil]);XCTAssertEqual(value.diarization?.detectedSpeakers,2);XCTAssertEqual(value.diarization?.unassignedSegments,1)
        XCTAssertEqual(try SpeakerAttribution.attach(turns.reversed(),to:source,model:"fixture"),value)
    }
    func testMixedOverlapWeakCoverageAndZeroDurationRemainUnknown() throws {
        let source=transcript([(0,1),(2,3),(4,5),(6,6)])
        let turns=[SpeakerTurn(start:0,end:0.5,speaker:"a"),SpeakerTurn(start:0.5,end:1,speaker:"b"),SpeakerTurn(start:2,end:3,speaker:"a"),SpeakerTurn(start:2.2,end:2.8,speaker:"b"),SpeakerTurn(start:4,end:4.3,speaker:"a")]
        let value=try SpeakerAttribution.attach(turns,to:source,model:"fixture")
        XCTAssertTrue(value.segments.allSatisfy{$0.speaker==nil});XCTAssertEqual(value.diarization?.unassignedSegments,4)
    }
    func testDuplicateAndNestedSameSpeakerTurnsCountAsUnion() throws {
        let source=transcript([(0,1),(1,2)])
        let turns=[SpeakerTurn(start:0,end:0.4,speaker:"a"),SpeakerTurn(start:0,end:0.4,speaker:"a"),SpeakerTurn(start:1,end:2,speaker:"a"),SpeakerTurn(start:1.2,end:1.8,speaker:"a")]
        let value=try SpeakerAttribution.attach(turns,to:source,model:"fixture")
        XCTAssertEqual(value.segments.map(\.speaker),[nil,"Speaker 1"])
    }
    func testCoarseMultiSpeakerSegmentIsNotFabricatedIntoWords() throws {
        let value=try SpeakerAttribution.attach([SpeakerTurn(start:0,end:5,speaker:"a"),SpeakerTurn(start:5,end:10,speaker:"b")],to:transcript([(0,10)]),model:"fixture")
        XCTAssertNil(value.segments[0].speaker);XCTAssertEqual(value.segments[0].text,"word");XCTAssertEqual(value.diarization?.detectedSpeakers,2)
    }
    func testInvalidTurnMetadataAndTooManyIdentitiesFail() throws {
        for turn in [SpeakerTurn(start:.nan,end:1,speaker:"a"),SpeakerTurn(start:0,end:.infinity,speaker:"a"),SpeakerTurn(start:-1,end:1,speaker:"a"),SpeakerTurn(start:2,end:1,speaker:"a"),SpeakerTurn(start:0,end:11,speaker:"a"),SpeakerTurn(start:0,end:1,speaker:"")] { XCTAssertThrowsError(try SpeakerAttribution.attach([turn],to:transcript([(0,1)]),model:"fixture")) }
        XCTAssertThrowsError(try SpeakerAttribution.attach((0...256).map{SpeakerTurn(start:0,end:1,speaker:String($0))},to:transcript([(0,1)]),model:"fixture"))
        var invalid=transcript([(0,1)]);invalid.diarization=DiarizationInfo(model:"fixture",detectedSpeakers:1,unassignedSegments:0);XCTAssertThrowsError(try invalid.validated())
        XCTAssertNoThrow(try JSONDecoder().decode(SpeechTranscript.self,from:JSONEncoder().encode(transcript([(0,1)]))))
    }
    func testLongCoarseAndWordTranscriptsUseIndexedCoverage() throws {
        let count=20000,turns=(0..<count).map{SpeakerTurn(start:Double($0),end:Double($0+1),speaker:String($0%3))}
        let coarse=try SpeakerAttribution.attach(turns,to:transcript(Array(repeating:(0,Double(count)),count:10000),duration:Double(count)),model:"fixture")
        XCTAssertEqual(coarse.diarization?.unassignedSegments,10000)
        let words=try SpeakerAttribution.attach(turns,to:transcript((0..<count).map{(Double($0),Double($0+1))},duration:Double(count)),model:"fixture")
        XCTAssertEqual(words.diarization?.unassignedSegments,0);XCTAssertEqual(words.segments[19999].speaker,"Speaker 2")
    }
    func testRedactionBackupAndTextInterchangePreserveSafeSpeakerMetadata() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root.appendingPathComponent("library")),file=root.appendingPathComponent("source.wav");try WAV.data(samples:Array(repeating:0.1,count:16000)).write(to:file)
        var source=transcript([(0,1)],duration:1);source.text="My password is synthetic123";source.segments[0].text=source.text
        let annotated=try SpeakerAttribution.attach([SpeakerTurn(start:0,end:1,speaker:"a")],to:source,model:"fixture")
        var settings=AppSettings();settings.retainAudio=true
        let memory=try AudioAdmission.save(annotated,file:file,store:store,settings:settings,timestamp:Date(),source:"Imported audio",recordedLive:false)
        XCTAssertNil(memory.audioPath);XCTAssertEqual(memory.transcript?.segments[0].text,"[REDACTED]");XCTAssertEqual(memory.transcript?.diarization?.detectedSpeakers,1)
        let archive=root.appendingPathComponent("speaker.oswindbackup");_ = try LibraryBackup.create(store:store,destination:archive)
        let restored=root.appendingPathComponent("restored");_ = try LibraryBackup.restore(archive,to:restored)
        XCTAssertEqual(try MemoryStore(root:restored).get(memory.id)?.transcript,memory.transcript)
        let json=root.appendingPathComponent("speaker.json");try store.exportJSON(to:json)
        let imported=try MemoryStore(root:root.appendingPathComponent("interchange"));XCTAssertEqual(try imported.importJSON(from:json),1);XCTAssertEqual(try imported.get(memory.id)?.transcript,memory.transcript)
    }
}
