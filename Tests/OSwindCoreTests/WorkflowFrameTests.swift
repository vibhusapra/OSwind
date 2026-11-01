import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreVideo
@testable import OSwindCore

private final class WorkflowPIIBackend:PIINativeBackend,@unchecked Sendable {
    func close() {}
    func prepare(_ document:PIIDocument) async throws->PIIWindowPlan {try PIIWindowPlan.make(document:document,prompt:[50281,50369],tokenLimit:512){_ in [1]}}
    func predict(_ window:PIIWindowPlan.Window) async throws->PIINativeOutput {
        let words=window.input.words;var logits=Array(repeating:Float(-20),count:words.count*36)
        for (index,word) in words.enumerated() where word.text.contains("OwnedSensitive") {for channel in 0..<3 {logits[index*36+channel]=8}}
        return .init(sourceSHA256:window.sourceSHA256,windowID:window.id,modelID:PIIInspector.expectedModelID(.cpu),shape:[1,words.count,12,3],logits:logits)
    }
}
final class WorkflowFrameTests:XCTestCase {
    static func fixture(root selectedRoot:URL?=nil)throws->(URL,MemoryStore) {
        let root=selectedRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("oswind-workflow-frame-"+UUID().uuidString)
        let store=try MemoryStore(root:root)
        try Paths.ensure(root.appendingPathComponent("images"))
        let color=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
        let context=try XCTUnwrap(CGContext(data:nil,width:640,height:360,bitsPerComponent:8,bytesPerRow:640*4,space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:640,height:360))
        context.setFillColor(CGColor(red:0.1,green:0.3,blue:0.8,alpha:1));context.fill(CGRect(x:80,y:80,width:180,height:120))
        let data=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,try XCTUnwrap(context.makeImage()),nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (data as Data).write(to:root.appendingPathComponent("images/owned.png"))
        try store.insert(Memory(id:"owned-screen",timestamp:Date(timeIntervalSince1970:100),app:"Owned fixture",bundleID:"dev.oswind.fixture",title:"Authored workspace",text:"Owned source",imagePath:"images/owned.png"))
        return (root,store)
    }
    func cleanup(_ root:URL,_ store:MemoryStore) {try? store.close();try? FileManager.default.removeItem(at:root)}
    func testActualOwnedImagePreviewBindsPixelsAndReleasesBeforeStoreClose()async throws {
        let (root,store)=try Self.fixture();defer {cleanup(root,store)}
        let preview=try await NarratedWorkflow.preview(store:store,memoryID:"owned-screen")
        XCTAssertEqual(preview.source.kind,.image);XCTAssertEqual(preview.source.frameOrdinal,0);XCTAssertNil(preview.source.frameTime)
        XCTAssertEqual(preview.source.mediaSHA256,WorkflowDraft.digest(try Data(contentsOf:root.appendingPathComponent("images/owned.png"))))
        XCTAssertEqual(preview.title,"Authored workspace");XCTAssertEqual(preview.frames.count,1)
        XCTAssertTrue(preview.png.starts(with:[137,80,78,71,13,10,26,10]));XCTAssertNotNil(CGImageSourceCreateWithData(preview.png as CFData,nil))
        try store.close();XCTAssertTrue(store.isClosed)
    }
    func testReplacedPixelsCannotPassCurrentSourceAdmission()async throws {
        let (root,store)=try Self.fixture();defer {cleanup(root,store)}
        let settings=try LibrarySettingsSnapshot.capture(root:root);defer {settings.release()}
        let frame=try await WorkflowFrameReservation.make(store:store,memoryID:"owned-screen",frameOrdinal:0,settings:settings,scanner:nil,ocr:{_ in []});defer {frame.release()}
        let replacement=Data("Owned changed bytes".utf8);try replacement.write(to:root.appendingPathComponent("images/owned.png"),options:.atomic)
        XCTAssertThrowsError(try frame.withCurrent(store:store,settings:settings){_ in XCTFail("Changed pixels admitted")})
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("images/owned.png")),replacement)
    }
    func testChangedSourceMetadataCannotPassCurrentAdmission()async throws {
        let (root,store)=try Self.fixture();defer {cleanup(root,store)}
        let settings=try LibrarySettingsSnapshot.capture(root:root);defer {settings.release()}
        let frame=try await WorkflowFrameReservation.make(store:store,memoryID:"owned-screen",frameOrdinal:0,settings:settings,scanner:nil,ocr:{_ in []});defer {frame.release()}
        var changed=try XCTUnwrap(store.get("owned-screen"));changed.text="Changed owned source";try store.insert(changed)
        XCTAssertThrowsError(try frame.withCurrent(store:store,settings:settings){_ in XCTFail("Changed metadata admitted")})
    }
    func testSensitiveRecognizedPixelsRefuseAndReleaseReservation()async throws {
        let (root,store)=try Self.fixture();defer {cleanup(root,store)}
        let settings=try LibrarySettingsSnapshot.capture(root:root);defer {settings.release()}
        do {
            let frame=try await WorkflowFrameReservation.make(store:store,memoryID:"owned-screen",frameOrdinal:0,settings:settings,scanner:nil,ocr:{_ in [.init(text:"password: owned-fixture-secret",x:0,y:0,width:1,height:1)]})
            frame.release();XCTFail("Sensitive pixels admitted")
        }catch {}
        try store.close();XCTAssertTrue(store.isClosed)
    }
    func testSettingsChangedDuringInspectionRefusePreview()async throws {
        let (root,store)=try Self.fixture();defer {cleanup(root,store)}
        let settings=try LibrarySettingsSnapshot.capture(root:root);defer {settings.release()}
        do {
            let frame=try await WorkflowFrameReservation.make(store:store,memoryID:"owned-screen",frameOrdinal:0,settings:settings,scanner:nil,ocr:{_ in var changed=AppSettings();changed.privacy.retainImages=false;try changed.save(root:root);return []})
            frame.release();XCTFail("Old privacy snapshot admitted")
        }catch {}
        try store.close();XCTAssertTrue(store.isClosed)
    }
    func testSensitiveSourceRefusesBeforePixelInspection()async throws {
        let (root,store)=try Self.fixture();defer {cleanup(root,store)}
        var changed=try XCTUnwrap(store.get("owned-screen"));changed.text="password: owned-fixture-secret";try store.insert(changed)
        let settings=try LibrarySettingsSnapshot.capture(root:root);defer {settings.release()}
        do {
            let frame=try await WorkflowFrameReservation.make(store:store,memoryID:"owned-screen",frameOrdinal:0,settings:settings,scanner:nil,ocr:{_ in XCTFail("Excluded source reached OCR");return []})
            frame.release();XCTFail("Sensitive source admitted")
        }catch {}
    }
    func testCancellationDuringInspectionDoesNotReturnLatePreviewOrPinStore()async throws {
        let (root,store)=try Self.fixture();defer {cleanup(root,store)}
        let settings=try LibrarySettingsSnapshot.capture(root:root);defer {settings.release()}
        let task=Task {try await WorkflowFrameReservation.make(store:store,memoryID:"owned-screen",frameOrdinal:0,settings:settings,scanner:nil,ocr:{_ in withUnsafeCurrentTask {$0?.cancel()};return []})}
        do {let frame=try await task.value;frame.release();XCTFail("Cancelled preview returned")}catch is CancellationError {}catch {throw error}
        try store.close();XCTAssertTrue(store.isClosed)
    }
    func testEnabledLearnedPrivacyCannotBeBypassedWithMissingScanner()async throws {
        let (root,store)=try Self.fixture();defer {cleanup(root,store)}
        var saved=AppSettings();saved.piiImports.enabled=true;try saved.save(root:root)
        let settings=try LibrarySettingsSnapshot.capture(root:root);defer {settings.release()}
        do {
            let frame=try await WorkflowFrameReservation.make(store:store,memoryID:"owned-screen",frameOrdinal:0,settings:settings,scanner:nil,ocr:{_ in XCTFail("Missing selected scanner reached pixels");return []})
            frame.release();XCTFail("Selected learned privacy bypassed")
        }catch {}
    }
    func testSelectedLearnedScannerAllowsOwnedFrameWithNoRecognizedText()async throws {
        let (root,store)=try Self.fixture();defer {cleanup(root,store)}
        var saved=AppSettings();saved.piiImports.enabled=true;saved.piiImports.compute = .cpu;try saved.save(root:root)
        let settings=try LibrarySettingsSnapshot.capture(root:root);defer {settings.release()}
        let scanner=PIIImportScanner(inspector:PIIInspector(loader:{WorkflowPIIBackend()}))
        do {
            let frame=try await WorkflowFrameReservation.make(store:store,memoryID:"owned-screen",frameOrdinal:0,settings:settings,scanner:scanner,ocr:{_ in []})
            frame.release();await scanner.shutdown()
        }catch {await scanner.shutdown();throw error}
    }
    func testSelectedLearnedScannerRefusesDetectedPixelText()async throws {
        let (root,store)=try Self.fixture();defer {cleanup(root,store)}
        var saved=AppSettings();saved.piiImports.enabled=true;saved.piiImports.compute = .cpu;try saved.save(root:root)
        let settings=try LibrarySettingsSnapshot.capture(root:root);defer {settings.release()}
        let scanner=PIIImportScanner(inspector:PIIInspector(loader:{WorkflowPIIBackend()}))
        do {
            let frame=try await WorkflowFrameReservation.make(store:store,memoryID:"owned-screen",frameOrdinal:0,settings:settings,scanner:scanner,ocr:{_ in [.init(text:"OwnedSensitiveValue",x:0,y:0,width:1,height:1)]})
            frame.release();XCTFail("Learned detection admitted")
        }catch OSwindError.unavailable(let message) {XCTAssertEqual(message,"Local privacy inspection found sensitive content in this screen source")}
        catch {await scanner.shutdown();throw error}
        await scanner.shutdown();try store.close();XCTAssertTrue(store.isClosed)
    }
    func testActualReplaySelectsRecordedFrameAndReleasesPrivatePin()async throws {
        let (root,store)=try Self.fixture();defer {cleanup(root,store)}
        try Paths.ensure(root.appendingPathComponent("video"))
        func buffer(red:Bool)throws->CVPixelBuffer {
            var result:CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,128,96,kCVPixelFormatType_32BGRA,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&result),kCVReturnSuccess)
            let value=try XCTUnwrap(result);CVPixelBufferLockBaseAddress(value,[]);defer {CVPixelBufferUnlockBaseAddress(value,[])}
            let data=try XCTUnwrap(CVPixelBufferGetBaseAddress(value)).assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(value)
            for y in 0..<96 {for x in 0..<128 {let p=data.advanced(by:y*stride+x*4);p[0]=red ? 0:255;p[1]=0;p[2]=red ? 255:0;p[3]=255}}
            return value
        }
        let writer=try ReplayVideoEncoder(url:root.appendingPathComponent("video/owned.mov"),width:128,height:96,frameInterval:1,codec:"h264",hardwareRequired:false)
        try await writer.append(buffer(red:true),time:0);try await writer.append(buffer(red:false),time:1);_ = try await writer.finish(duration:2)
        var memory=Memory(id:"owned-replay",app:"Owned fixture",bundleID:"dev.oswind.fixture",title:"Authored replay",text:"")
        memory.videoPath="video/owned.mov";memory.visualRecording=VisualRecording(duration:2,width:128,height:96,codec:"h264",hardwareRequired:false,frames:[.init(time:0,text:"First owned frame"),.init(time:1,text:"Second owned frame")]);memory.text=memory.visualRecording!.text;try store.insert(memory)
        let settings=try LibrarySettingsSnapshot.capture(root:root);defer {settings.release()}
        let frame=try await WorkflowFrameReservation.make(store:store,memoryID:memory.id,frameOrdinal:1,settings:settings,scanner:nil,ocr:{_ in []});defer {frame.release()}
        XCTAssertEqual(frame.preview.source.kind,.video);XCTAssertEqual(frame.preview.source.frameOrdinal,1);XCTAssertEqual(frame.preview.source.frameTime,1)
        XCTAssertEqual(frame.preview.frames.map(\.time),[0,1])
        let source=try XCTUnwrap(CGImageSourceCreateWithData(frame.preview.png as CFData,nil)),image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil)),pixels=try VisualImageInput.pixels(image:image)
        XCTAssertLessThan(pixels[0],-0.8);XCTAssertGreaterThan(pixels[224*224*2],0.8)
        frame.release()
        do {
            let unavailable=try await WorkflowFrameReservation.make(store:store,memoryID:memory.id,frameOrdinal:2,settings:settings,scanner:nil,ocr:{_ in []})
            unavailable.release();XCTFail("Invented replay ordinal admitted")
        }catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("video/.staging").path).isEmpty)
    }
}
