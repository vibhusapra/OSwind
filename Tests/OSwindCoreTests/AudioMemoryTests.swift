import XCTest
import AVFoundation
import CSQLite
@testable import OSwindCore

final class AudioMemoryTests: XCTestCase {
    var root: URL!, store: MemoryStore!, file: URL!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try Paths.ensure(root)
        store=try MemoryStore(root:root.appendingPathComponent("library")); file=root.appendingPathComponent("source.wav"); try WAV.data(samples:Array(repeating:0.1,count:16000)).write(to:file)
    }
    override func tearDownWithError() throws { store=nil; try? FileManager.default.removeItem(at:root) }
    func transcript(_ text: String="Maya owns the Friday checklist") -> SpeechTranscript { SpeechTranscript(text:text,duration:1,segments:[TranscriptSegment(start:0,end:1,text:text,speaker:"Speaker 1")],model:"fixture") }
    func testOptInRetentionPlaybackMetadataErasureAndBackupRoundTrip() throws {
        var settings=AppSettings(); settings.retainAudio=true
        let original=try AudioAdmission.save(transcript(),file:file,store:store,settings:settings,timestamp:Date(timeIntervalSince1970:100),source:"Microphone",sessionID:"meeting-1")
        let retained=try XCTUnwrap(original.audioPath), retainedURL=try XCTUnwrap(store.assetURL(retained))
        XCTAssertEqual(try Data(contentsOf:retainedURL),try Data(contentsOf:file)); XCTAssertEqual(try store.get(original.id)?.transcript,transcript()); XCTAssertEqual(original.audioSessionID,"meeting-1")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:retainedURL.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        let archive=root.appendingPathComponent("audio.oswindbackup"), restoredURL=root.appendingPathComponent("restored")
        _ = try LibraryBackup.create(store:store,destination:archive); _ = try LibraryBackup.restore(archive,to:restoredURL)
        let restored=try MemoryStore(root:restoredURL), memory=try XCTUnwrap(restored.get(original.id))
        XCTAssertEqual(memory.transcript,original.transcript); XCTAssertEqual(memory.audioSessionID,"meeting-1"); XCTAssertNotNil(memory.audioPath)
        try store.delete(original.id); XCTAssertFalse(FileManager.default.fileExists(atPath:retainedURL.path)); XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
    }
    func testDefaultAndRedactedTranscriptsNeverRetainRawAudio() throws {
        let ordinary=try AudioAdmission.save(transcript(),file:file,store:store,settings:AppSettings(),timestamp:Date(),source:"Microphone")
        XCTAssertNil(ordinary.audioPath)
        var settings=AppSettings(); settings.retainAudio=true
        var value=transcript("Safe full text"); value.segments[0].text="password=synthetic123"
        let secret=try AudioAdmission.save(value,file:file,store:store,settings:settings,timestamp:Date(),source:"System audio")
        XCTAssertNil(secret.audioPath); XCTAssertEqual(secret.transcript?.segments[0].text,"[REDACTED]")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:store.root.appendingPathComponent("audio").path),[])
        var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(settings)) as! [String:Any]; json.removeValue(forKey:"retainAudio")
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self,from:JSONSerialization.data(withJSONObject:json)).retainAudio)
    }
    func testInvalidTimestampsMismatchedPayloadAndSymlinksFailWithoutAssets() throws {
        var bad=transcript(); bad.segments[0].end=2; XCTAssertThrowsError(try bad.validated())
        bad=transcript(); bad.duration = .nan; XCTAssertThrowsError(try bad.validated())
        bad=transcript(); bad.segments[0].start = -.infinity; XCTAssertThrowsError(try bad.validated())
        var memory=Memory(kind:.audio,text:"Different"); memory.transcript=transcript(); XCTAssertThrowsError(try store.insert(memory))
        var settings=AppSettings(); settings.retainAudio=true
        let alias=root.appendingPathComponent("alias.wav"); try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:file)
        XCTAssertThrowsError(try AudioAdmission.save(transcript(),file:alias,store:store,settings:settings,timestamp:Date(),source:"Imported audio"))
        XCTAssertEqual(try store.matchingCount(),0); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:store.root.appendingPathComponent("audio").path).isEmpty)
    }
    func testWhisperOffsetsAndUntrustedOutputValidation() throws {
        let json=Data(#"{"transcription":[{"offsets":{"from":0,"to":400},"text":" Hello"},{"offsets":{"from":400,"to":1000},"text":" world."}]}"#.utf8)
        let value=try Whisper.parseJSON(json,model:"fixture"); XCTAssertEqual(value.text,"Hello world."); XCTAssertEqual(value.duration,1); XCTAssertEqual(value.segments[1].start,0.4)
        XCTAssertThrowsError(try Whisper.parseJSON(Data(#"{"transcription":[{"offsets":{"from":2000,"to":1000},"text":"Bad"}]}"#.utf8),model:"fixture"))
        XCTAssertThrowsError(try Whisper.parseJSON(Data(#"{"transcription":[]}"#.utf8),model:"fixture"))
    }
    func testTextInterchangeRedactsStructuredTranscriptAndStripsAudio() throws {
        var settings=AppSettings(); settings.retainAudio=true; settings.privacy.redactSecrets=false
        let original=try AudioAdmission.save(transcript("password=synthetic123"),file:file,store:store,settings:settings,timestamp:Date(),source:"Imported audio",recordedLive:false)
        XCTAssertNil(original.endTimestamp)
        let exported=root.appendingPathComponent("text.json"); try store.exportJSON(to:exported)
        let target=try MemoryStore(root:root.appendingPathComponent("text-import")); XCTAssertEqual(try target.importJSON(from:exported),1)
        let memory=try XCTUnwrap(target.get(original.id)); XCTAssertNil(memory.audioPath); XCTAssertEqual(memory.text,"[REDACTED]"); XCTAssertEqual(memory.transcript?.text,memory.text); XCTAssertEqual(memory.transcript?.segments[0].text,"[REDACTED]")
    }
    func testImportSnapshotSurvivesOriginalRewriteAndCleansOwnedFiles() throws {
        var clip: AudioClipSnapshot?=try AudioClipSnapshot(source:file)
        let url=clip!.file, original=try Data(contentsOf:file)
        try Data("external rewrite".utf8).write(to:file)
        XCTAssertEqual(try Data(contentsOf:url),original)
        try FileManager.default.removeItem(at:file)
        XCTAssertEqual(try Data(contentsOf:url),original)
        clip=nil; XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
    }
    func testCancelledAdmissionLeavesNoRecordOrRetainedAsset() async throws {
        var settings=AppSettings(); settings.retainAudio=true
        let store=try XCTUnwrap(store), file=try XCTUnwrap(file), value=transcript()
        let task=Task.detached { () throws -> Memory in
            withUnsafeCurrentTask { $0?.cancel() }
            return try AudioAdmission.save(value,file:file,store:store,settings:settings,timestamp:Date(),source:"Microphone")
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try store.matchingCount(),0); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:store.root.appendingPathComponent("audio").path).isEmpty)
    }

    func testStereoAACImportNormalizesToMono16kAndPreservesOriginal() throws {
        let aac=root.appendingPathComponent("meeting.m4a")
        do {
            let writer=try AVAudioFile(forWriting:aac,settings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:96000])
            let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:writer.processingFormat,frameCapacity:48000)); buffer.frameLength=48000
            let channels=try XCTUnwrap(buffer.floatChannelData)
            for i in 0..<48000 { channels[0][i]=Float(sin(Double(i)*0.03))*0.1; channels[1][i]=Float(cos(Double(i)*0.03))*0.1 }
            try writer.write(from:buffer)
        }
        let original=try Data(contentsOf:aac), clip=try AudioClipSnapshot(source:aac); defer { withExtendedLifetime(clip) {} }
        let decoded=try AVAudioFile(forReading:clip.speechFile)
        XCTAssertEqual(decoded.fileFormat.sampleRate,16000); XCTAssertEqual(decoded.fileFormat.channelCount,1); XCTAssertEqual(clip.duration,1,accuracy:0.1)
        XCTAssertEqual(try Data(contentsOf:clip.file),original)
        XCTAssertEqual(try Data(contentsOf:clip.speechFile).prefix(4),Data("RIFF".utf8))
    }
    func testInvalidAudioPreparationDoesNotLeakWorkspace() throws {
        let parent=FileManager.default.temporaryDirectory
        let before=Set(try FileManager.default.contentsOfDirectory(atPath:parent.path).filter {$0.hasPrefix(".oswind-audio-import-")})
        let invalid=root.appendingPathComponent("invalid.wav"); try Data("not audio".utf8).write(to:invalid)
        XCTAssertThrowsError(try AudioClipSnapshot(source:invalid)); XCTAssertEqual(try store.matchingCount(),0)
        let after=Set(try FileManager.default.contentsOfDirectory(atPath:parent.path).filter {$0.hasPrefix(".oswind-audio-import-")})
        XCTAssertTrue(after.subtracting(before).isEmpty)
    }

    func testDatabaseFailureRemovesOnlyNewlyCopiedAudio() throws {
        var handle: OpaquePointer?; XCTAssertEqual(sqlite3_open(store.root.appendingPathComponent("memory.sqlite").path,&handle),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle,"CREATE TRIGGER reject_audio BEFORE INSERT ON memories WHEN new.kind='audio' BEGIN SELECT RAISE(ABORT,'synthetic insert failure'); END;",nil,nil,nil),SQLITE_OK); sqlite3_close(handle)
        let existing=store.root.appendingPathComponent("audio/keep.wav"); try Data("keep".utf8).write(to:existing)
        var settings=AppSettings(); settings.retainAudio=true
        XCTAssertThrowsError(try AudioAdmission.save(transcript(),file:file,store:store,settings:settings,timestamp:Date(),source:"Microphone"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:store.root.appendingPathComponent("audio").path),["keep.wav"])
        XCTAssertEqual(try Data(contentsOf:existing),Data("keep".utf8)); XCTAssertTrue(FileManager.default.fileExists(atPath:file.path)); XCTAssertEqual(try store.matchingCount(),0)
    }

    func testSpokenCredentialsAndValuesSplitAcrossSegmentsCannotLeak() throws {
        var settings=AppSettings(); settings.retainAudio=true
        for parts in [["password:","synthetic123"],["My password","is synthetic123"],["The access token","is synthetic123"]] {
            let text=parts.joined(separator:" ")
            let value=SpeechTranscript(text:text,duration:1,segments:[TranscriptSegment(start:0,end:0.5,text:parts[0]),TranscriptSegment(start:0.5,end:1,text:parts[1])],model:"fixture")
            let memory=try AudioAdmission.save(value,file:file,store:store,settings:settings,timestamp:Date(),source:"Microphone")
            XCTAssertNil(memory.audioPath,text)
            let encoded=String(decoding:try JSONEncoder().encode(memory),as:UTF8.self)
            XCTAssertFalse(encoded.contains("synthetic123"),text)
        }
        settings.privacy.redactSecrets=false
        let unsafe=try AudioAdmission.save(transcript("My password is synthetic123"),file:file,store:store,settings:settings,timestamp:Date(),source:"Microphone")
        let exported=root.appendingPathComponent("spoken.json"); try store.exportJSON(to:exported)
        let target=try MemoryStore(root:root.appendingPathComponent("spoken-import")); _ = try target.importJSON(from:exported)
        let restored=try XCTUnwrap(target.get(unsafe.id)); XCTAssertEqual(restored.text,"[REDACTED SENSITIVE SPEECH]")
        XCTAssertEqual(restored.transcript?.text,restored.text); XCTAssertFalse(String(decoding:try JSONEncoder().encode(restored),as:UTF8.self).contains("synthetic123"))
    }

    func testTrustedParentAliasesResolveWithoutFollowingFinalFileLinks() throws {
        let alias=root.appendingPathComponent("parent-alias"); try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:root)
        let clip=try AudioClipSnapshot(source:alias.appendingPathComponent("source.wav")); defer { withExtendedLifetime(clip) {} }
        XCTAssertEqual(try Data(contentsOf:clip.file),try Data(contentsOf:file))
        let fileAlias=root.appendingPathComponent("final-alias.wav"); try FileManager.default.createSymbolicLink(at:fileAlias,withDestinationURL:file)
        XCTAssertThrowsError(try AudioClipSnapshot(source:fileAlias))
    }

}
