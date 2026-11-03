import XCTest
import AppKit
import ScreenCaptureKit
@testable import OSwindCore

final class NativeCaptureConfigurationTests:XCTestCase {
    func testOneXWindowUsesNativeRasterAcrossAllProfiles()throws {
        for profile in CaptureProfile.allCases {
            let c=try NativeCaptureConfiguration.window(size:CGSize(width:960,height:632),nativePixelScale:1,maximumDimension:profile.maxDimension)
            XCTAssertEqual(c.width,960);XCTAssertEqual(c.height,632)
            XCTAssertTrue(c.scalesToFit);XCTAssertFalse(c.preservesAspectRatio);XCTAssertTrue(c.ignoreShadowsSingleWindow);XCTAssertFalse(c.showsCursor);XCTAssertEqual(c.captureResolution,.best)
        }
    }
    func testRetinaWindowDownsamplesToProfileWithoutExceedingNativePixels()throws {
        for (limit,width,height) in [(1280,1280,842),(1920,1920,1264),(2560,1920,1264)] {
            let c=try NativeCaptureConfiguration.window(size:CGSize(width:960,height:632),nativePixelScale:2,maximumDimension:limit)
            XCTAssertEqual(c.width,width);XCTAssertEqual(c.height,height);XCTAssertTrue(c.scalesToFit);XCTAssertFalse(c.preservesAspectRatio)
        }
    }
    func testFractionalScaleAndPortraitFramesRemainBounded()throws {
        let fractional=try NativeCaptureConfiguration.window(size:CGSize(width:960,height:632),nativePixelScale:1.25,maximumDimension:1920)
        XCTAssertEqual(fractional.width,1200);XCTAssertEqual(fractional.height,790)
        let portrait=try NativeCaptureConfiguration.window(size:CGSize(width:632,height:960),nativePixelScale:2,maximumDimension:1280)
        XCTAssertEqual(portrait.width,842);XCTAssertEqual(portrait.height,1280)
    }
    func testReplayEvenAlignmentFillsSurfaceAndDoesNotUpscale()throws {
        for native in [1.0,2.0] {
            let c=try NativeCaptureConfiguration.window(size:CGSize(width:961,height:633),nativePixelScale:native,maximumDimension:2560,evenDimensions:true)
            XCTAssertEqual(c.width%2,0);XCTAssertEqual(c.height%2,0);XCTAssertLessThanOrEqual(Double(c.width),961*native);XCTAssertLessThanOrEqual(Double(c.height),633*native);XCTAssertTrue(c.scalesToFit);XCTAssertFalse(c.preservesAspectRatio)
        }
        XCTAssertThrowsError(try NativeCaptureConfiguration.window(size:CGSize(width:1,height:1),nativePixelScale:1,maximumDimension:1280,evenDimensions:true))
    }
    func testInvalidSourceGeometryAndScaleRefuseBeforeCapture()throws {
        for scale in [0.0,-1,.nan,.infinity] {XCTAssertThrowsError(try NativeCaptureConfiguration.window(size:CGSize(width:960,height:632),nativePixelScale:scale,maximumDimension:1280))}
        for size in [CGSize.zero,CGSize(width:Double.nan,height:2),CGSize(width:2,height:Double.infinity),CGSize(width:-1,height:2)] {XCTAssertThrowsError(try NativeCaptureConfiguration.window(size:size,nativePixelScale:1,maximumDimension:1280))}
        XCTAssertThrowsError(try NativeCaptureConfiguration.window(size:CGSize(width:1,height:1),nativePixelScale:0.5,maximumDimension:1280))
        for limit in [0,-1,8193] {XCTAssertThrowsError(try NativeCaptureConfiguration.window(size:CGSize(width:960,height:632),nativePixelScale:1,maximumDimension:limit))}
    }
    func testDisplayCropKeepsPointCoordinatesAndUsesActualPixelScale()throws {
        let region=SnapshotRegion(x:0.25,y:0.1,width:0.5,height:0.4)
        let one=try SnapshotRegionGeometry(size:CGSize(width:2560,height:1440),region:region,maximumDimension:1920,nativePixelScale:1)
        let two=try SnapshotRegionGeometry(size:CGSize(width:2560,height:1440),region:region,maximumDimension:1920,nativePixelScale:2)
        XCTAssertEqual(one.sourceRect,two.sourceRect);XCTAssertEqual(one.sourceRect,CGRect(x:640,y:144,width:1280,height:576));XCTAssertEqual(one.outputWidth,1280);XCTAssertEqual(one.outputHeight,576);XCTAssertEqual(two.outputWidth,1920);XCTAssertEqual(two.outputHeight,864)
    }
}
