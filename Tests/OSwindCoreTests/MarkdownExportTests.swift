import XCTest
@testable import OSwindCore

final class MarkdownExportTests: XCTestCase {
    var root: URL!, store: MemoryStore!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Paths.ensure(root); store = try MemoryStore(root:root.appendingPathComponent("library"))
    }
    override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at:root) }
    var output: URL { root.appendingPathComponent("Markdown") }
    func sourceURL(_ id: String) -> URL { output.appendingPathComponent("sources/"+BackupSHA256.hex(Data(id.utf8))+".md") }
    func asset(_ path: String) throws { let url = store.root.appendingPathComponent(path); try Paths.ensure(url.deletingLastPathComponent()); try Data("owned synthetic media".utf8).write(to:url) }
    func answer(_ memory: Memory) -> Answer { Answer(text:"Maya owns capture [1].",sources:[SearchHit(memory:memory,score:1,match:"keyword")],provider:"fixture",duration:0) }
    func texts(_ folder: String) throws -> String { try FileManager.default.contentsOfDirectory(at:output.appendingPathComponent(folder),includingPropertiesForKeys:nil).sorted(by:{$0.path<$1.path}).map { try String(contentsOf:$0,encoding:.utf8) }.joined(separator:"\n") }
    func testPortableSourcesTimedTextCitationsAndPrivatePermissions() throws {
        try asset("images/a.jpg"); try asset("audio/a.wav"); try asset("video/a.mov")
        let body = "<script>alert('source')</script>\n![remote](https://example.invalid/pixel)\n```\nMaya owns capture."
        let memory = Memory(id:"../odd/[source]",kind:.note,app:"Notes",title:"A [bracket] <title>",text:body,imagePath:"images/a.jpg",favorite:true,tags:["work","x\ny"])
        try store.insert(memory)
        var speech = Memory(id:"speech",kind:.audio,app:"Microphone",title:"Meeting",text:"Maya speaks",audioPath:"audio/a.wav")
        speech.transcript = SpeechTranscript(text:speech.text,duration:2,segments:[TranscriptSegment(start:0.25,end:1.5,text:speech.text,speaker:"Maya")],model:"fixture")
        try store.insert(speech)
        var replay = Memory(id:"replay",title:"Replay",text:"Frame text")
        replay.visualRecording = VisualRecording(duration:1,width:1280,height:720,codec:"hevc",hardwareRequired:true,frames:[VisualFrame(time:0,text:replay.text,regions:[])])
        replay.videoPath = "video/a.mov"; try store.insert(replay)
        let chat = try store.createChat(); _ = try store.appendChatTurn(sessionID:chat.id,question:"Who?",answer:answer(memory))
        try Data("never exported token".utf8).write(to:store.root.appendingPathComponent("api-token"))
        let info = try MarkdownExport.create(store:store,destination:output,policy:PrivacyPolicy(),includeMedia:true)
        XCTAssertEqual(info.memories,3); XCTAssertEqual(info.turns,1); XCTAssertEqual(info.mediaFiles,3)
        let source = try String(contentsOf:sourceURL(memory.id)); XCTAssertTrue(source.contains("````text\n"+body)); XCTAssertTrue(source.contains("favorite: true")); XCTAssertTrue(source.contains("[Open retained image](../media/"))
        XCTAssertTrue(try texts("sources").contains("### 0.250 s – 1.500 s")); XCTAssertTrue(try texts("sources").contains("Speaker: Maya")); XCTAssertTrue(try texts("sources").contains("## Sampled replay frames"))
        let conversation = try texts("conversations"); XCTAssertTrue(conversation.contains("[1] [A \\[bracket\\] \\<title\\>](../sources/")); XCTAssertTrue(conversation.contains("### Search scope"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.appendingPathComponent("api-token").path)); XCTAssertFalse(FileManager.default.fileExists(atPath:output.appendingPathComponent("memory.sqlite").path))
        let enumerator = FileManager.default.enumerator(at:output,includingPropertiesForKeys:nil)!
        for case let file as URL in enumerator { let permissions = try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as! NSNumber; XCTAssertEqual(permissions.intValue & 0o077,0) }
        XCTAssertEqual(try JSONDecoder().decode(MarkdownExportInfo.self,from:Data(contentsOf:output.appendingPathComponent("export.json"))).memories,3)
        try store.delete(memory.id); XCTAssertTrue(FileManager.default.fileExists(atPath:sourceURL(memory.id).path))
    }
    func testCurrentPrivacyExcludesDependentTurnsAndSuppressesSecretMedia() throws {
        try asset("images/raw.jpg"); try asset("audio/private.wav")
        let hidden = Memory(id:"hidden",bundleID:"private.app",title:"Hidden title",text:"hidden factual answer")
        let secret = Memory(id:"secret",title:"Credential",text:"api_key=abcdefghijklmnopqrstuvwxyz012345",imagePath:"images/raw.jpg")
        var speech = Memory(id:"spoken",kind:.audio,text:"My password is banana",audioPath:"audio/private.wav")
        speech.transcript = SpeechTranscript(text:speech.text,duration:2,segments:[TranscriptSegment(start:0,end:2,text:speech.text)],model:"fixture")
        try store.insert(hidden); try store.insert(secret); try store.insert(speech)
        let chat = try store.createChat(); _ = try store.appendChatTurn(sessionID:chat.id,question:"Hidden question title",answer:answer(hidden))
        var policy = PrivacyPolicy(); policy.excludedApps.append("private.app")
        let info = try MarkdownExport.create(store:store,destination:output,policy:policy,includeMedia:true)
        XCTAssertEqual(info.memories,2); XCTAssertEqual(info.excludedMemories,1); XCTAssertEqual(info.excludedTurns,1); XCTAssertEqual(info.turns,0); XCTAssertEqual(info.mediaFiles,0)
        let exported = try texts("sources")+texts("conversations")
        XCTAssertFalse(exported.contains("abcdefghijklmnopqrstuvwxyz012345")); XCTAssertFalse(exported.contains("banana")); XCTAssertFalse(exported.contains("Hidden question")); XCTAssertFalse(exported.contains("hidden factual")); XCTAssertTrue(exported.contains("[REDACTED"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:sourceURL(hidden.id).path)); XCTAssertFalse(FileManager.default.fileExists(atPath:output.appendingPathComponent("media").path))
    }
    func testSnapshotIsConsistentAndDoesNotHoldLiveStoreLock() throws {
        try store.insert(Memory(id:"first",text:"First")); try store.insert(Memory(id:"second",text:"Second"))
        var changed = false
        let info = try MarkdownExport.create(store:store,destination:output,policy:PrivacyPolicy()) { event in
            if event.phase == "Exporting sources",!changed { changed = true; try self.store.delete("second"); try self.store.insert(Memory(id:"late",text:"Late insert")) }
        }
        XCTAssertTrue(changed); XCTAssertEqual(info.memories,2); XCTAssertTrue(FileManager.default.fileExists(atPath:sourceURL("second").path)); XCTAssertFalse(FileManager.default.fileExists(atPath:sourceURL("late").path))
        XCTAssertNil(try store.get("second")); XCTAssertNotNil(try store.get("late"))
    }
    func testExistingDestinationsSourceOverlapAndSymlinkMediaAreRefused() throws {
        try Paths.ensure(output); try Data("keep".utf8).write(to:output.appendingPathComponent("keep"))
        XCTAssertThrowsError(try MarkdownExport.create(store:store,destination:output,policy:PrivacyPolicy()))
        XCTAssertEqual(try String(contentsOf:output.appendingPathComponent("keep")),"keep")
        XCTAssertThrowsError(try MarkdownExport.create(store:store,destination:store.root.appendingPathComponent("export"),policy:PrivacyPolicy()))
        let outside = root.appendingPathComponent("outside.jpg"); try Data("outside".utf8).write(to:outside)
        try asset("images/link.jpg")
        try store.insert(Memory(id:"link",text:"Allowed text",imagePath:"images/link.jpg"))
        try FileManager.default.removeItem(at:store.root.appendingPathComponent("images/link.jpg"))
        try FileManager.default.createSymbolicLink(at:store.root.appendingPathComponent("images/link.jpg"),withDestinationURL:outside)
        let bad = root.appendingPathComponent("bad")
        XCTAssertThrowsError(try MarkdownExport.create(store:store,destination:bad,policy:PrivacyPolicy(),includeMedia:true)); XCTAssertFalse(FileManager.default.fileExists(atPath:bad.path))
        let textOnly = root.appendingPathComponent("text-only"); XCTAssertEqual(try MarkdownExport.create(store:store,destination:textOnly,policy:PrivacyPolicy()).memories,1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).allSatisfy { !$0.hasPrefix(".oswind-markdown-") && !$0.hasPrefix(".oswind-job-") })
    }
    func testCancellationBeforePublicationRemovesStagingAndPreservesLibrary() throws {
        try store.insert(Memory(id:"one",text:"One"))
        for phase in ["Exporting sources","Publishing Markdown export"] {
            XCTAssertThrowsError(try MarkdownExport.create(store:store,destination:output,policy:PrivacyPolicy()) { if $0.phase == phase { throw CancellationError() } })
            XCTAssertFalse(FileManager.default.fileExists(atPath:output.path)); XCTAssertNotNil(try store.get("one"))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).allSatisfy { !$0.hasPrefix(".oswind-markdown-") && !$0.hasPrefix(".oswind-job-") })
        }
    }
    func testAllRecordsAndMoreThanOneThousandTurnsExportWithoutSearchLimits() throws {
        for i in 0..<205 { try store.insert(Memory(id:"source-\(i)",kind:.note,title:"Source \(i)",text:"Text \(i)")) }
        let chat = try store.createChat(), answer = Answer(text:"No cited evidence",sources:[],provider:"fixture",duration:0)
        for i in 0..<1005 { _ = try store.appendChatTurn(sessionID:chat.id,question:"Question \(i)",answer:answer) }
        let info = try MarkdownExport.create(store:store,destination:output,policy:PrivacyPolicy())
        XCTAssertEqual(info.memories,205); XCTAssertEqual(info.turns,1005); XCTAssertTrue(try texts("conversations").contains("Question 1004"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:output.appendingPathComponent("sources").path).count,205)
    }
}
