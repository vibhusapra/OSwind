import XCTest
import SwiftUI
import AppKit
@testable import OSwindCore
@testable import OSwind

@MainActor final class PIIScanRecordViewTests:XCTestCase {
    func record(redacted:Bool) throws -> PIIScanRecord {
        let object:[String:Any]=["version":1,"coverage":"oswind-import-text-fields-v1","contentSHA256":String(repeating:"a",count:64),"modelID":PIIInspector.expectedModelID(.cpu),"compute":"cpu","threshold":0.5,"checkedAt":Date(timeIntervalSince1970:1793289600).timeIntervalSinceReferenceDate,"redacted":redacted,"fields":9,"windows":2,"framedTokens":180]
        return try JSONDecoder().decode(PIIScanRecord.self,from:JSONSerialization.data(withJSONObject:object))
    }
    func testOwnedPrivacyRecordStatesRenderInBothThemes()async throws {
        guard let directory=ProcessInfo.processInfo.environment["OSWIND_TEST_PII_SCAN_RENDER_DIR"] else {throw XCTSkip("Explicit owned privacy-record render directory absent")}
        let folder=URL(fileURLWithPath:directory);try Paths.ensure(folder)
        let cases:[(String,PIIScanStatus?,String?)]=[
            ("loading",nil,nil),("none",.init(memoryID:"owned",state:.notRecorded,record:nil),nil),
            ("masked",.init(memoryID:"owned",state:.recorded,record:try record(redacted:true)),nil),
            ("no-masks",.init(memoryID:"owned",state:.recorded,record:try record(redacted:false)),nil),
            ("changed",.init(memoryID:"owned",state:.changed,record:try record(redacted:true)),nil),
            ("unavailable",.init(memoryID:"owned",state:.unavailable,record:nil),nil),("failure",nil,"Owned read failure")]
        _ = NSApplication.shared
        for dark in [false,true] {for (name,status,error) in cases {
            // Pure SwiftUI text is layer-rendered and NSView cacheDisplay
            // misses it. Use SwiftUI's rasterizer; native Forms use a different
            // fixture path in PIIModelSetupTests.
            let view=PIIScanRecordView(status:status,error:error).padding(24).frame(width:680,height:300,alignment:.topLeading).background(dark ? Color(red:0.12,green:0.12,blue:0.12):.white).environment(\.colorScheme,dark ? .dark:.light)
            let renderer=ImageRenderer(content:view);renderer.scale=2
            let image=try XCTUnwrap(renderer.nsImage),bitmap=try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(image.tiffRepresentation)))
            var colors=Set<UInt32>()
            for y in stride(from:10,to:bitmap.pixelsHigh-10,by:7) {for x in stride(from:10,to:bitmap.pixelsWide-10,by:7) {
                if let color=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) {let r=UInt32(max(0,min(255,color.redComponent*255))),g=UInt32(max(0,min(255,color.greenComponent*255))),b=UInt32(max(0,min(255,color.blueComponent*255)));colors.insert((r<<16)|(g<<8)|b)}
            }}
            XCTAssertGreaterThan(colors.count,8);let png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]));try png.write(to:folder.appendingPathComponent(name+(dark ? "-dark":"-light")+".png"))
        }}
    }
}
