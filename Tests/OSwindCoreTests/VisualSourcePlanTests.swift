import XCTest
@testable import OSwindCore

final class VisualSourcePlanTests:XCTestCase {
    private var image:Memory {Memory(id:"image-one",timestamp:Date(timeIntervalSince1970:100),app:"Photos",bundleID:"test.photos",title:"Trip",text:"",imagePath:"images/one.jpg")}
    private var video:Memory {
        var value=image;value.imagePath="images/poster.jpg";value.videoPath="video/one.mov"
        value.visualRecording=VisualRecording(duration:3,width:640,height:480,codec:"hevc",hardwareRequired:true,frames:[VisualFrame(time:0,text:"first"),VisualFrame(time:1.5,text:"second")]);value.text=value.visualRecording!.text;return value
    }
    func testImageWithoutOCRStillHasOneVisualTarget() throws {
        let plan=try XCTUnwrap(VisualSourcePlan.make(image))
        XCTAssertEqual(plan.kind,.image);XCTAssertEqual(plan.path,"images/one.jpg");XCTAssertEqual(plan.points,[.init(ordinal:0,time:nil)])
    }
    func testVideoUsesEveryDeclaredFrameAndNotThePoster() throws {
        let plan=try XCTUnwrap(VisualSourcePlan.make(video))
        XCTAssertEqual(plan.kind,.video);XCTAssertEqual(plan.path,"video/one.mov")
        XCTAssertEqual(plan.points,[.init(ordinal:0,time:0),.init(ordinal:1,time:1.5)])
        var changed=video;changed.visualRecording!.frames[1].time=2
        XCTAssertNotEqual(plan.revision,try VisualSourcePlan.make(changed)?.revision)
    }
    func testMediaLocationContextAndTimeChangesInvalidateWhilePersonalLabelsDoNot() throws {
        let base=try XCTUnwrap(VisualSourcePlan.make(image))
        for change in [({$0.imagePath="images/two.jpg"} as (inout Memory)->Void),{$0.bundleID="test.different"},{$0.endTimestamp=Date(timeIntervalSince1970:110)},{$0.text="new OCR"},{$0.timestamp=Date(timeIntervalSince1970:101)}] {
            var copy=image;change(&copy);XCTAssertNotEqual(base.revision,try VisualSourcePlan.make(copy)?.revision)
        }
        var labels=image;labels.favorite=true;labels.tags=["vacation"]
        XCTAssertEqual(base.revision,try VisualSourcePlan.make(labels)?.revision)
    }
    func testNoRetainedPixelsMeansNoVisualPlan() throws {
        var value=image;value.imagePath=nil;XCTAssertNil(try VisualSourcePlan.make(value))
        value=video;value.imagePath=nil;value.videoPath=nil;XCTAssertNil(try VisualSourcePlan.make(value))
    }
    func testReplayPosterCannotInventCoverageOfMissingVideo() throws {
        var value=video;value.videoPath=nil
        XCTAssertThrowsError(try VisualSourcePlan.make(value))
    }
    func testMalformedReplayAndForeignKindsAreRejected() throws {
        var value=video;value.visualRecording=nil;XCTAssertThrowsError(try VisualSourcePlan.make(value))
        value=video;value.text="not the recorded text";XCTAssertThrowsError(try VisualSourcePlan.make(value))
        value=video;value.visualRecording!.frames[1].time=0;XCTAssertThrowsError(try VisualSourcePlan.make(value))
        value=image;value.kind = .note;XCTAssertThrowsError(try VisualSourcePlan.make(value))
    }
    func testUnsafeOrUnadmittedPathsAreRejected() throws {
        for path in ["/images/one.jpg","images/../one.jpg","images//one.jpg","images/.staging/work/one.jpg","audio/one.jpg","memory.sqlite","images/x\0y"] {
            var value=image;value.imagePath=path;XCTAssertThrowsError(try VisualSourcePlan.make(value),path)
        }
    }
    func testVectorIdentityIncludesPixelsModelPreprocessorAndActualFrame() throws {
        let plan=try XCTUnwrap(VisualSourcePlan.make(video)),hash=String(repeating:"a",count:64),point=plan.points[0]
        let base=try plan.vectorRevision(mediaSHA256:hash,modelID:"siglip2:one",point:point)
        XCTAssertEqual(base,try plan.vectorRevision(mediaSHA256:hash,modelID:"siglip2:one",point:point))
        XCTAssertNotEqual(base,try plan.vectorRevision(mediaSHA256:String(repeating:"b",count:64),modelID:"siglip2:one",point:point))
        XCTAssertNotEqual(base,try plan.vectorRevision(mediaSHA256:hash,modelID:"siglip2:two",point:point))
        XCTAssertNotEqual(base,try plan.vectorRevision(mediaSHA256:hash,modelID:"siglip2:one",point:point,preprocessingID:"changed"))
        XCTAssertNotEqual(base,try plan.vectorRevision(mediaSHA256:hash,modelID:"siglip2:one",point:plan.points[1]))
        XCTAssertThrowsError(try plan.vectorRevision(mediaSHA256:"invalid",modelID:"siglip2:one",point:point))
        XCTAssertThrowsError(try plan.vectorRevision(mediaSHA256:hash,modelID:"siglip2:one",point:.init(ordinal:7,time:2)))
    }
}
