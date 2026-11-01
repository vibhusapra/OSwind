import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import OSwindCore

final class WorkflowVideoFrameTests:XCTestCase {
    func image(blue:Bool)throws->CGImage {
        let color=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB)),context=try XCTUnwrap(CGContext(data:nil,width:640,height:360,bitsPerComponent:8,bytesPerRow:640*4,space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:blue ? 0:1,green:0,blue:blue ? 1:0,alpha:1));context.fill(CGRect(x:0,y:0,width:640,height:360))
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:10,y:280,width:90,height:60))
        return try XCTUnwrap(context.makeImage())
    }
    func png(_ image:CGImage)throws->Data {
        let data=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination));return data as Data
    }
    func testNativeH264FramesFollowMeasuredNarrationAndKeepOriginalColors()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-workflow-video-"+UUID().uuidString),store=try MemoryStore(root:root)
        defer {try? FileManager.default.removeItem(at:root)}
        var workspace:BackupWorkspace?=try store.libraryWorkspace("oswind-workflow",bucket:.video)
        do {
            try await renderFixture(store:store,workspace:try XCTUnwrap(workspace))
            try workspace?.cleanup();workspace=nil;try store.close();XCTAssertTrue(store.isClosed)
        }catch {let original=error;try? workspace?.cleanup();workspace=nil;try? store.close();throw original}
    }
    private func renderFixture(store:MemoryStore,workspace:BackupWorkspace)async throws {
        var frames=[WorkflowFramePreview]()
        for index in 0..<2 {
            let path="images/owned-\(index).png",id="owned-video-source-\(index)"
            try png(image(blue:index==1)).write(to:store.root.appendingPathComponent(path))
            try store.insert(Memory(id:id,timestamp:Date(timeIntervalSince1970:Double(100+index)),app:"Owned fixture",bundleID:"dev.oswind.fixture",title:index==0 ? "Authored red frame":"Authored blue frame",text:"Owned source",imagePath:path))
            frames.append(try await NarratedWorkflow.preview(store:store,memoryID:id))
        }
        let draft=WorkflowDraft(title:"Owned source walkthrough",steps:frames.enumerated().map {index,frame in WorkflowStep(source:frame.source,title:frame.title,narration:index==0 ? "First owned narration.":"Second owned narration.")})
        let audio=try WorkflowTimelineTests.populate(workspace,draft:draft),timeline=try LocalWorkflowTimeline.combine(draft:draft,narrations:audio,workspace:workspace)
        let hardware=ProcessInfo.processInfo.environment["OSWIND_TEST_WORKFLOW_VIDEO_HARDWARE"]=="1"
        let url=try await WorkflowVideoFrames.render(draft:draft,frames:frames,timeline:timeline,workspace:workspace,hardwareRequired:hardware)
        let asset=AVURLAsset(url:url),duration=try await asset.load(.duration).seconds,tracks=try await asset.loadTracks(withMediaType:.video)
        XCTAssertEqual(duration,timeline.duration,accuracy:1.0/600);XCTAssertEqual(tracks.count,1)
        let track=try XCTUnwrap(tracks.first),formats=try await track.load(.formatDescriptions),format=try XCTUnwrap(formats.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format),kCMVideoCodecType_H264)
        let decoder=try await VisualReplayDecoder.open(url);defer {decoder.close()}
        let first=try await decoder.image(at:timeline.steps[0].startSeconds),second=try await decoder.image(at:timeline.steps[1].startSeconds)
        let red=try VisualImageInput.pixels(image:first.image),blue=try VisualImageInput.pixels(image:second.image),center=112*224+112
        XCTAssertGreaterThan(red[center],0.8);XCTAssertLessThan(red[224*224*2+center],-0.8)
        XCTAssertGreaterThan(blue[224*224*2+center],0.8);XCTAssertLessThan(blue[center],-0.8)
        if let destination=ProcessInfo.processInfo.environment["OSWIND_TEST_WORKFLOW_VIDEO_OUTPUT"] {
            let output=URL(fileURLWithPath:destination,isDirectory:true)
            guard !FileManager.default.fileExists(atPath:output.path) else {throw OSwindError.invalid("Choose a new owned raw-video fixture output")}
            try Paths.ensure(output);let tree=try BackupFileTree(root:output,writable:true)
            _ = try workspace.tree.copy("workflow-video.mov",to:tree,as:"workflow-video.mov")
            try tree.write(png(first.image),as:"decoded-first.png");try tree.write(png(second.image),as:"decoded-second.png")
            try tree.write(JSONEncoder().encode(draft),as:"draft.json");try tree.write(JSONEncoder().encode(timeline),as:"timeline.json")
            try tree.write(Data("Owned silent H264 intermediate with synthetic narration used only for timing. AAC/mux not implemented yet. Hardware required: \(hardware)".utf8),as:"scope.txt")
        }
    }
}
