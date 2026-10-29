import XCTest
@testable import OSwindCore

final class PrivacyMaskUnionTests:XCTestCase {
    static let key="sk-"+String(repeating:"a",count:20)
    static let overlap=key+"-password=OwnedOverlapSecret"
    static let privateKey="-----BEGIN PRIVATE KEY-----\nOwnedPrivatePayload\n-----END PRIVATE KEY-----"
    func testEarlierAPIKeyMatchCannotHideAnyLaterCredentialTrigger() {
        let policy=PrivacyPolicy()
        for trigger in ["password","passwd","api_key","api key","secret","access token"] {
            let source=Self.key+"-"+trigger+"=OwnedOverlapSecret",result=policy.sanitize(source)
            XCTAssertEqual(result.text,"[REDACTED]",trigger);XCTAssertTrue(result.redacted)
            XCTAssertFalse(result.text.contains("OwnedOverlapSecret"),trigger)
        }
    }
    func testEarlierAPIKeyMatchCannotHidePrivateKeyHeader() {
        let result=PrivacyPolicy().sanitize(Self.key+Self.privateKey)
        XCTAssertEqual(result.text,"[REDACTED]");XCTAssertTrue(result.redacted)
        XCTAssertFalse(result.text.contains("OwnedPrivatePayload"))
    }
    func testPrivateKeyMaskExpandsThroughTrailingCombiningCharacter() {
        let prefix="Cafe\u{301} 🦊 before ",suffix=" after 👩🏽‍💻",source=prefix+Self.privateKey+"\u{301}"+suffix
        let result=PrivacyPolicy().sanitize(source)
        XCTAssertEqual(Array(result.text.utf8),Array((prefix+"[REDACTED]"+suffix).utf8))
    }
    func testDisjointPatternsPreserveOriginalSeparatorsAndUnmaskedBytes() {
        let prefix="\u{feff}Cafe\u{301} 🦊\n",source=prefix+"password=OwnedPassword; credit 4111 1111 1111 1111 | 123-45-6789\nend"
        let result=PrivacyPolicy().sanitize(source)
        XCTAssertEqual(Array(result.text.utf8),Array((prefix+"[REDACTED]; credit [REDACTED] | [REDACTED]\nend").utf8))
        XCTAssertTrue(result.redacted)
    }
    func testPatternOnlyInspectionAndProductionMasksHaveSameOriginalSourceUnion() throws {
        let policy=PrivacyPolicy()
        for source in [Self.overlap,Self.key+Self.privateKey,Self.privateKey+"\u{301}","safe [REDACTED]", "password=OwnedPassword; api_key=OwnedOtherValue", "Cafe\u{301} 123-45-6789 👩🏽‍💻"] {
            let expected=try PIIDecoding.mask(source,ranges:policy.sensitiveRanges(in:source)),actual=policy.sanitize(source)
            XCTAssertEqual(Array(actual.text.utf8),Array(expected.text.utf8));XCTAssertEqual(actual.redacted,expected.redacted)
        }
    }
    func testDisabledRedactionAndLiteralMarkersRemainByteExact() {
        var disabled=PrivacyPolicy();disabled.redactSecrets=false
        let source="Cafe\u{301} "+Self.overlap+" [REDACTED] 🦊",result=disabled.sanitize(source)
        XCTAssertEqual(Array(result.text.utf8),Array(source.utf8));XCTAssertFalse(result.redacted)
        let literal=PrivacyPolicy().sanitize("[REDACTED] = a harmless literal marker")
        XCTAssertEqual(literal.text,"[REDACTED] = a harmless literal marker");XCTAssertFalse(literal.redacted)
    }
    func testRedactionIsIdempotentAfterOriginalSourceMatchesAreMerged() {
        let policy=PrivacyPolicy(),first=policy.sanitize(Self.overlap),second=policy.sanitize(first.text)
        XCTAssertEqual(first.text,"[REDACTED]");XCTAssertEqual(second.text,first.text);XCTAssertFalse(second.redacted)
    }
    func testProductionPatternProtectionDoesNotInheritExperimentalPIIDocumentLimit() {
        let prefix=String(repeating:"safe ",count:30000),suffix=" tail 🦊",result=PrivacyPolicy().sanitize(prefix+Self.overlap+suffix)
        XCTAssertGreaterThan(prefix.utf8.count,PIIDocument.maximumBytes)
        XCTAssertEqual(Array(result.text.utf8),Array((prefix+"[REDACTED]"+suffix).utf8));XCTAssertTrue(result.redacted)
    }
    func testConcurrentPoliciesKeepSourceAndMutableResultsIsolated() async throws {
        let inputs=[Self.overlap,Self.key+Self.privateKey,Self.privateKey+"\u{301}","safe Cafe\u{301} 🦊"]
        try await withThrowingTaskGroup(of:Bool.self) {group in
            for index in 0..<128 {
                let input=inputs[index%inputs.count],expected=index%inputs.count==3 ? input:"[REDACTED]"
                group.addTask {let result=PrivacyPolicy().sanitize(input);return result.text.utf8.elementsEqual(expected.utf8)}
            }
            for try await passed in group {XCTAssertTrue(passed)}
        }
    }
    func fixture(_ name:String)throws->(URL,MemoryStore) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(name+UUID().uuidString)
        return (root,try MemoryStore(root:root.appendingPathComponent("library")))
    }
    func testJSONAdmissionProtectsTextTitleAndURLWithoutPlaintextMediaFallback() throws {
        let (root,store)=try fixture("oswind-pattern-import-");defer {try? store.close();try? FileManager.default.removeItem(at:root)}
        let memory=Memory(id:"owned-overlap",title:Self.overlap,url:"https://example.test/?"+Self.overlap,text:Self.overlap,imagePath:"images/owned.png")
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .custom {try ISOTime.encode($0,to:$1)}
        XCTAssertEqual(try store.importJSONDetailed(data:encoder.encode([memory])).imported,1)
        let saved=try XCTUnwrap(store.get(memory.id));XCTAssertEqual(saved.text,"[REDACTED]");XCTAssertEqual(saved.title,"[REDACTED]")
        XCTAssertFalse(saved.url?.contains("OwnedOverlapSecret") ?? true);XCTAssertNil(saved.imagePath)
        let exported=root.appendingPathComponent("export.json");try store.exportJSON(to:exported)
        XCTAssertFalse(String(decoding:try Data(contentsOf:exported),as:UTF8.self).contains("OwnedOverlapSecret"))
    }
    func testTranscriptMainTextAndSegmentsAreProtectedAndAudioIsSuppressed() throws {
        let source=SpeechTranscript(text:Self.overlap,duration:1,segments:[.init(start:0,end:1,text:Self.overlap)],model:"owned")
        let result=try source.sanitized(policy:PrivacyPolicy())
        XCTAssertEqual(result.transcript.text,"[REDACTED]");XCTAssertTrue(result.suppressAudio)
        XCTAssertEqual(result.transcript.segments.map(\.text),["[REDACTED]"])
    }
    func testReplayTextAndSecretRegionsAreProtectedWhileSafeFrameRemains() throws {
        let region=TextRegion(text:Self.overlap,x:0,y:0,width:0.5,height:0.5)
        let source=VisualRecording(duration:2,width:100,height:100,codec:"hevc",hardwareRequired:false,frames:[.init(time:0,text:Self.overlap,regions:[region]),.init(time:1,text:"Safe frame",regions:[])])
        let result=try source.sanitized(policy:PrivacyPolicy())
        XCTAssertEqual(result.frames[0].text,"[REDACTED]");XCTAssertTrue(result.frames[0].regions.isEmpty)
        XCTAssertEqual(result.frames[1].text,"Safe frame")
    }
    func testCurrentPolicyMarkdownExportProtectsRawOwnedSourceAndSuppressesMedia() throws {
        let (root,store)=try fixture("oswind-pattern-export-");defer {try? store.close();try? FileManager.default.removeItem(at:root)}
        let image=store.root.appendingPathComponent("images/owned.png");try Paths.ensure(image.deletingLastPathComponent());try Data("owned raw fixture media".utf8).write(to:image)
        let memory=Memory(id:"owned-raw-export",title:"Owned source",text:Self.overlap,imagePath:"images/owned.png");try store.insert(memory)
        let destination=root.appendingPathComponent("Markdown"),info=try MarkdownExport.create(store:store,destination:destination,policy:PrivacyPolicy(),includeMedia:true)
        XCTAssertEqual(info.mediaFiles,0)
        let source=destination.appendingPathComponent("sources/"+BackupSHA256.hex(Data(memory.id.utf8))+".md")
        XCTAssertFalse(try String(contentsOf:source,encoding:.utf8).contains("OwnedOverlapSecret"))
        XCTAssertEqual(try store.get(memory.id)?.text,Self.overlap)
        XCTAssertTrue(FileManager.default.fileExists(atPath:image.path))
    }
}
