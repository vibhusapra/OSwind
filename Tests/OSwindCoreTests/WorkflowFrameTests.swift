import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import OSwindCore

final class WorkflowFrameTests:XCTestCase {
    func fixture()throws->(URL,MemoryStore) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-workflow-frame-"+UUID().uuidString)
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
        let (root,store)=try fixture();defer {cleanup(root,store)}
        let preview=try await NarratedWorkflow.preview(store:store,memoryID:"owned-screen")
        XCTAssertEqual(preview.source.kind,.image);XCTAssertEqual(preview.source.frameOrdinal,0);XCTAssertNil(preview.source.frameTime)
        XCTAssertEqual(preview.source.mediaSHA256,WorkflowDraft.digest(try Data(contentsOf:root.appendingPathComponent("images/owned.png"))))
        XCTAssertEqual(preview.title,"Authored workspace");XCTAssertEqual(preview.frames.count,1)
        XCTAssertTrue(preview.png.starts(with:[137,80,78,71,13,10,26,10]));XCTAssertNotNil(CGImageSourceCreateWithData(preview.png as CFData,nil))
        try store.close();XCTAssertTrue(store.isClosed)
    }
    func testReplacedPixelsCannotPassCurrentSourceAdmission()async throws {
        let (root,store)=try fixture();defer {cleanup(root,store)}
        let settings=try LibrarySettingsSnapshot.capture(root:root);defer {settings.release()}
        let frame=try await WorkflowFrameReservation.make(store:store,memoryID:"owned-screen",frameOrdinal:0,settings:settings,scanner:nil,ocr:{_ in []});defer {frame.release()}
        let replacement=Data("Owned changed bytes".utf8);try replacement.write(to:root.appendingPathComponent("images/owned.png"),options:.atomic)
        XCTAssertThrowsError(try frame.withCurrent(store:store,settings:settings){_ in XCTFail("Changed pixels admitted")})
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("images/owned.png")),replacement)
    }
    func testChangedSourceMetadataCannotPassCurrentAdmission()async throws {
        let (root,store)=try fixture();defer {cleanup(root,store)}
        let settings=try LibrarySettingsSnapshot.capture(root:root);defer {settings.release()}
        let frame=try await WorkflowFrameReservation.make(store:store,memoryID:"owned-screen",frameOrdinal:0,settings:settings,scanner:nil,ocr:{_ in []});defer {frame.release()}
        var changed=try XCTUnwrap(store.get("owned-screen"));changed.text="Changed owned source";try store.insert(changed)
        XCTAssertThrowsError(try frame.withCurrent(store:store,settings:settings){_ in XCTFail("Changed metadata admitted")})
    }
    func testSensitiveRecognizedPixelsRefuseAndReleaseReservation()async throws {
        let (root,store)=try fixture();defer {cleanup(root,store)}
        let settings=try LibrarySettingsSnapshot.capture(root:root);defer {settings.release()}
        do {
            let frame=try await WorkflowFrameReservation.make(store:store,memoryID:"owned-screen",frameOrdinal:0,settings:settings,scanner:nil,ocr:{_ in [.init(text:"password: owned-fixture-secret",x:0,y:0,width:1,height:1)]})
            frame.release();XCTFail("Sensitive pixels admitted")
        }catch {}
        try store.close();XCTAssertTrue(store.isClosed)
    }
    func testSettingsChangedDuringInspectionRefusePreview()async throws {
        let (root,store)=try fixture();defer {cleanup(root,store)}
        let settings=try LibrarySettingsSnapshot.capture(root:root);defer {settings.release()}
        do {
            let frame=try await WorkflowFrameReservation.make(store:store,memoryID:"owned-screen",frameOrdinal:0,settings:settings,scanner:nil,ocr:{_ in var changed=AppSettings();changed.privacy.retainImages=false;try changed.save(root:root);return []})
            frame.release();XCTFail("Old privacy snapshot admitted")
        }catch {}
        try store.close();XCTAssertTrue(store.isClosed)
    }
    func testSensitiveSourceRefusesBeforePixelInspection()async throws {
        let (root,store)=try fixture();defer {cleanup(root,store)}
        var changed=try XCTUnwrap(store.get("owned-screen"));changed.text="password: owned-fixture-secret";try store.insert(changed)
        let settings=try LibrarySettingsSnapshot.capture(root:root);defer {settings.release()}
        do {
            let frame=try await WorkflowFrameReservation.make(store:store,memoryID:"owned-screen",frameOrdinal:0,settings:settings,scanner:nil,ocr:{_ in XCTFail("Excluded source reached OCR");return []})
            frame.release();XCTFail("Sensitive source admitted")
        }catch {}
    }
    func testCancellationDuringInspectionDoesNotReturnLatePreviewOrPinStore()async throws {
        let (root,store)=try fixture();defer {cleanup(root,store)}
        let settings=try LibrarySettingsSnapshot.capture(root:root);defer {settings.release()}
        let task=Task {try await WorkflowFrameReservation.make(store:store,memoryID:"owned-screen",frameOrdinal:0,settings:settings,scanner:nil,ocr:{_ in withUnsafeCurrentTask {$0?.cancel()};return []})}
        do {let frame=try await task.value;frame.release();XCTFail("Cancelled preview returned")}catch is CancellationError {}catch {throw error}
        try store.close();XCTAssertTrue(store.isClosed)
    }
}
