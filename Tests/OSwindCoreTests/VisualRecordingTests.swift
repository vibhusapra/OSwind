import XCTest
import AVFoundation
import CoreGraphics
import CoreVideo
@testable import OSwindCore

final class VisualRecordingTests:XCTestCase {
    func root() -> URL {FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)}
    func pixel(_ red:UInt8) throws -> CVPixelBuffer {
        var buffer:CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,320,180,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&buffer),kCVReturnSuccess)
        let result=try XCTUnwrap(buffer);CVPixelBufferLockBaseAddress(result,[]);defer {CVPixelBufferUnlockBaseAddress(result,[])}
        let bytes=CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(result)
        for y in 0..<180 {for x in 0..<320 {let p=y*stride+x*4;bytes[p]=0;bytes[p+1]=0;bytes[p+2]=red;bytes[p+3]=255}}
        return result
    }
    func input(time:Double,text:String="Maya owns capture.",title:String="Synthetic window",red:UInt8=240) throws -> ReplayFrameInput {
        ReplayFrameInput(buffer:try pixel(red),time:time,capturedAt:Date(timeIntervalSince1970:1_700_000_000+time),app:"Fixture app",bundle:"org.oswind.fixture",title:title,url:nil,display:"window-1",text:text,regions:[])
    }
    func testVisualSourceValidationRangesAndPrivacy() throws {
        let source=VisualRecording(duration:2,width:320,height:180,codec:"h264",hardwareRequired:false,frames:[VisualFrame(time:0,text:"Café 👩🏽‍💻 owns capture."),VisualFrame(time:1,text:"password=synthetic123")])
        XCTAssertNoThrow(try source.validated());let ranges=source.ranges();XCTAssertEqual(ranges[1].range.text(in:source.text),source.frames[1].text)
        XCTAssertEqual(source.frameTime(passage:ranges[1].range),1);XCTAssertEqual(source.frameTime(query:"Café"),0)
        let clean=try source.sanitized(policy:PrivacyPolicy());XCTAssertFalse(clean.text.contains("synthetic123"))
        var bad=source;bad.frames[1].time=0;XCTAssertThrowsError(try bad.validated());bad=source;bad.duration = .infinity;XCTAssertThrowsError(try bad.validated())
    }
    func testNativeSoftwareMuxAndPixelDecodePreserveFrameOrder() async throws {
        let directory=root();try Paths.ensure(directory);defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("clip.mov"),encoder=try ReplayVideoEncoder(url:url,width:320,height:180,frameInterval:1,codec:"h264",hardwareRequired:false)
        try await encoder.append(pixel(240),time:0);try await encoder.append(pixel(20),time:1)
        let duration=try await encoder.finish(duration:2);XCTAssertEqual(duration,2,accuracy:0.05)
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:url));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let first=try generator.copyCGImage(at:CMTime(seconds:0,preferredTimescale:600),actualTime:nil),last=try generator.copyCGImage(at:CMTime(seconds:1,preferredTimescale:600),actualTime:nil)
        func mean(_ image:CGImage) -> Double {
            var data=[UInt8](repeating:0,count:4)
            data.withUnsafeMutableBytes {p in let context=CGContext(data:p.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;context.draw(image,in:CGRect(x:0,y:0,width:1,height:1))};return Double(data[0])
        }
        XCTAssertGreaterThan(mean(first),180);XCTAssertLessThan(mean(last),70)
    }
    func testRecorderOwnsVideoThumbnailBackupInterchangeAndErasure() async throws {
        let directory=root();defer {try? FileManager.default.removeItem(at:directory)};let store=try MemoryStore(root:directory.appendingPathComponent("library"))
        let recorder=VisualChunkRecorder(store:store,codec:"h264",hardwareRequired:false)
        try await recorder.append(input(time:0),privacy:PrivacyPolicy(),interval:1);try await recorder.append(input(time:1,text:"Theo owns archive.",red:20),privacy:PrivacyPolicy(),interval:1);try await recorder.close()
        let memory=try XCTUnwrap(store.search(SearchFilter(query:"archive"),mode:.keyword).first?.memory)
        XCTAssertEqual(memory.visualRecording?.frames.count,2);XCTAssertEqual(memory.text,"Maya owns capture.\n\nTheo owns archive.")
        let video=try XCTUnwrap(memory.videoPath.flatMap {store.assetURL($0)});XCTAssertTrue(FileManager.default.fileExists(atPath:video.path));XCTAssertNotNil(memory.imagePath)
        let package=directory.appendingPathComponent("visual.oswindbackup");_ = try LibraryBackup.create(store:store,destination:package)
        let restored=directory.appendingPathComponent("restored");_ = try LibraryBackup.restore(package,to:restored)
        let opened=try MemoryStore(root:restored),copy=try XCTUnwrap(opened.get(memory.id));XCTAssertEqual(copy.visualRecording,memory.visualRecording);XCTAssertTrue(FileManager.default.fileExists(atPath:opened.assetURL(copy.videoPath!)!.path))
        let json=directory.appendingPathComponent("source.json");try store.exportJSON(to:json)
        let imported=try MemoryStore(root:directory.appendingPathComponent("imported"));_ = try imported.importJSON(from:json)
        XCTAssertNil(try imported.get(memory.id)?.videoPath);XCTAssertEqual(try imported.get(memory.id)?.visualRecording,memory.visualRecording)
        try store.delete(memory.id);XCTAssertFalse(FileManager.default.fileExists(atPath:video.path))
    }
    func testSecretFrameClosesVideoAndNeverReachesRawRetention() async throws {
        let directory=root();defer {try? FileManager.default.removeItem(at:directory)};let store=try MemoryStore(root:directory)
        let recorder=VisualChunkRecorder(store:store,codec:"h264",hardwareRequired:false)
        try await recorder.append(input(time:0),privacy:PrivacyPolicy(),interval:1)
        try await recorder.append(input(time:1,text:"password=synthetic123"),privacy:PrivacyPolicy(),interval:1)
        try await recorder.close();let memories=try store.search(SearchFilter(),mode:.keyword).map(\.memory)
        XCTAssertEqual(memories.count,2);XCTAssertEqual(memories.filter {$0.videoPath != nil}.count,1)
        let redacted=try XCTUnwrap(memories.first {$0.text=="[REDACTED]"});XCTAssertNil(redacted.videoPath);XCTAssertNil(redacted.imagePath)
        XCTAssertTrue(memories.allSatisfy {!$0.text.contains("synthetic123")});XCTAssertEqual(memories.first {$0.videoPath != nil}?.visualRecording?.frames.count,1)
    }
    func testDiscardedAndExcludedFramesCannotPublishAssets() async throws {
        let directory=root();defer {try? FileManager.default.removeItem(at:directory)};let store=try MemoryStore(root:directory)
        let recorder=VisualChunkRecorder(store:store,codec:"h264",hardwareRequired:false)
        var excluded=try input(time:0);excluded.secure=true;try await recorder.append(excluded,privacy:PrivacyPolicy(),interval:1)
        try await recorder.append(input(time:1),privacy:PrivacyPolicy(),interval:1);try await recorder.close(commit:false)
        XCTAssertEqual(try store.matchingCount(),0);XCTAssertTrue((FileManager.default.enumerator(at:directory.appendingPathComponent("video"),includingPropertiesForKeys:[.isRegularFileKey])?.allObjects as? [URL] ?? []).allSatisfy { (try? $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) != true })
    }
    func testVideoPathsAndTextMetadataMustAgreeAndRevisionProtectsChats() throws {
        let directory=root();defer {try? FileManager.default.removeItem(at:directory)};let store=try MemoryStore(root:directory)
        var memory=Memory(id:"clip",kind:.screen,text:"Maya owns capture.")
        memory.visualRecording=VisualRecording(duration:1,width:320,height:180,codec:"h264",hardwareRequired:false,frames:[VisualFrame(time:0,text:memory.text)])
        try store.insert(memory);let chat=try store.createChat(),answer=Answer(text:"Maya [1].",sources:[SearchHit(memory:memory,score:1,match:"")],provider:"fixture",duration:0)
        _ = try store.appendChatTurn(sessionID:chat.id,question:"Who?",answer:answer)
        var changed=memory;changed.visualRecording?.duration=2;try store.insert(changed)
        XCTAssertTrue(try store.chatTurns(chat.id).isEmpty);XCTAssertThrowsError(try store.appendChatTurn(sessionID:chat.id,question:"Stale?",answer:answer))
        changed.videoPath="../bad.mov";XCTAssertThrowsError(try store.insert(changed));changed.videoPath=nil;changed.text="Different";XCTAssertThrowsError(try store.insert(changed))
    }
    func testInvalidatedPublicationGatePreventsLateRowsAndAssets() async throws {
        let directory=root();defer {try? FileManager.default.removeItem(at:directory)};let store=try MemoryStore(root:directory),gate=ReplayCommitGate()
        let recorder=VisualChunkRecorder(store:store,codec:"h264",hardwareRequired:false,gate:gate)
        try await recorder.append(input(time:0),privacy:PrivacyPolicy(),interval:1)
        gate.invalidate();let waiting=expectation(description:"wipe waits for recorder")
        let wipe=Task.detached {try store.wipeLibrary {if $0.phase=="Waiting for active media writers" {waiting.fulfill()}}}
        await fulfillment(of:[waiting],timeout:1)
        do {try await recorder.close();XCTFail("Late commit should be rejected")} catch is CancellationError {}
        let wiped=try await wipe.value;XCTAssertTrue(wiped.cleanupComplete)
        XCTAssertEqual(try store.matchingCount(),0)
        for folder in ["video","images"] {XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:directory.appendingPathComponent(folder).path).isEmpty)}
        let textOnly=VisualChunkRecorder(store:store,codec:"h264",hardwareRequired:false,gate:gate)
        do {try await textOnly.append(input(time:1,text:"password=synthetic123"),privacy:PrivacyPolicy(),interval:1);XCTFail("Late text must be rejected")} catch is CancellationError {}
        XCTAssertEqual(try store.matchingCount(),0)
    }
    func testTimedVisualAnswerEvidencePreservesLiteralUnicodeAndPassage() throws {
        let visual=VisualRecording(duration:2,width:320,height:180,codec:"h264",hardwareRequired:false,frames:[VisualFrame(time:0,text:"Café 👩🏽‍💻 owns capture."),VisualFrame(time:1,text:"Theo owns archive.")])
        var memory=Memory(kind:.screen,text:visual.text);memory.visualRecording=visual
        let hit=SearchHit(memory:memory,score:1,match:"fixture",passage:visual.ranges()[1].range)
        let evidence=hit.answerEvidence(query:"archive",budget:100)
        XCTAssertTrue(evidence.contains("frame time 1.000 s"));XCTAssertTrue(evidence.contains("Theo owns archive."));XCTAssertFalse(evidence.contains("Café"))
        XCTAssertTrue(hit.answerEvidence(query:"",budget:100,summary:true).contains("Café 👩🏽‍💻 owns capture."))
        memory.text="Revised unrelated source";XCTAssertEqual(SearchHit(memory:memory,score:1,match:"").answerEvidence(query:"",budget:100),memory.text)
    }
    func testRetentionModeSettingsAndSingleFrameFlushRemainReadable() async throws {
        let directory=root();defer {try? FileManager.default.removeItem(at:directory)};let store=try MemoryStore(root:directory)
        var settings=AppSettings();settings.visualCaptureMode = .replay;try settings.save(root:directory)
        XCTAssertEqual(AppSettings.load(root:directory).visualCaptureMode,.replay)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self,from:Data("{}".utf8)).visualCaptureMode,.snapshots)
        XCTAssertEqual(CaptureProfile.detailed.replayInterval(lowPower:true,thermalLimited:true),4.5)
        var privacy=PrivacyPolicy();privacy.retainImages=false
        let text=VisualChunkRecorder(store:store,codec:"h264",hardwareRequired:false)
        try await text.append(input(time:0),privacy:privacy,interval:1);try await text.close()
        XCTAssertNil(try store.search(SearchFilter(),mode:.keyword).first?.memory.videoPath)
        let clip=VisualChunkRecorder(store:store,codec:"h264",hardwareRequired:false)
        try await clip.append(input(time:2),privacy:PrivacyPolicy(),interval:1);try await clip.flush()
        let memories=try store.search(SearchFilter(),mode:.keyword).map(\.memory)
        XCTAssertEqual(memories.count,2);XCTAssertEqual(memories.first {$0.videoPath != nil}?.visualRecording?.frames.count,1)
        try store.deleteAll();XCTAssertTrue((FileManager.default.enumerator(at:directory.appendingPathComponent("video"),includingPropertiesForKeys:[.isRegularFileKey])?.allObjects as? [URL] ?? []).allSatisfy { (try? $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) != true })
    }

    func testCancelledFinalizationNeverCallsWriterAfterCancellation() async throws {
        let directory=root();try Paths.ensure(directory);defer {try? FileManager.default.removeItem(at:directory)}
        for index in 0..<4 {
            let encoder=try ReplayVideoEncoder(url:directory.appendingPathComponent("cancel-\(index).mov"),width:320,height:180,frameInterval:1,codec:"h264",hardwareRequired:false)
            try await encoder.append(pixel(240),time:0)
            let task=Task {try await encoder.finish(duration:1)}
            task.cancel()
            do {_ = try await task.value;XCTFail("Expected cancelled finalization")} catch is CancellationError {}
            encoder.cancel()
        }
    }

    func testConcurrentFlushAndNormalCloseKeepEveryAdmittedFrame() async throws {
        let directory=root();defer {try? FileManager.default.removeItem(at:directory)}
        for index in 0..<8 {
            let store=try MemoryStore(root:directory.appendingPathComponent(String(index))),recorder=VisualChunkRecorder(store:store,codec:"h264",hardwareRequired:false)
            for frame in 0..<4 {try await recorder.append(input(time:Double(frame),text:"Admitted frame \(frame)"),privacy:PrivacyPolicy(),interval:1)}
            try await withThrowingTaskGroup(of:Void.self) {group in
                group.addTask {try await recorder.flush()};group.addTask {try await recorder.close()};try await group.waitForAll()
            }
            let memories=try store.search(SearchFilter(),mode:.keyword).map(\.memory)
            XCTAssertEqual(memories.count,1);XCTAssertEqual(memories.first?.visualRecording?.frames.count,4)
            XCTAssertTrue(memories.first?.text.contains("Admitted frame 3") == true)
        }
    }

}
