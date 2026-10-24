import XCTest
import CryptoKit
import ImageIO
import CoreGraphics
@testable import OSwindCore

final class VisualEncoderTests:XCTestCase {
    private var fixtures:URL {URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")}
    private func sha(_ data:Data) -> String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
    private func rgba(_ width:Int,_ height:Int) -> [UInt8] {
        var bytes=[UInt8]();bytes.reserveCapacity(width*height*4)
        for y in 0..<height {for x in 0..<width {bytes += [UInt8((x*13+y*7)%256),UInt8((x*3+y*17+91)%256),UInt8((x*19+y*5+29)%256),255]}}
        return bytes
    }
    func testBilinearMatchesPinnedPillowAtUpscaleDownscaleAndIdentity() throws {
        struct Fixture:Decodable {var width:Int;var height:Int;var sha256:String}
        let cases=try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:fixtures.appendingPathComponent("VisualPreprocessing.json")))
        for fixture in cases {
            let output=try VisualImageInput.resizedRGB(rgba:rgba(fixture.width,fixture.height),width:fixture.width,height:fixture.height)
            XCTAssertEqual(sha(Data(output)),fixture.sha256,"\(fixture.width)×\(fixture.height)")
        }
    }
    func testBadOrOversizedImageIsRejected() throws {
        XCTAssertThrowsError(try VisualImageInput.pixels(data:Data("not an image".utf8)))
        XCTAssertThrowsError(try VisualImageInput.resizedRGB(rgba:[],width:Int.max,height:1))
        XCTAssertThrowsError(try VisualImageInput.resizedRGB(rgba:[],width:1,height:1))
    }
    func testRGBDecodeOrientationAndNormalization() throws {
        let width=71,height=113,bytes=rgba(width,height),provider=CGDataProvider(data:Data(bytes) as CFData)!
        let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let data=NSMutableData(),destination=CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
        let decoded=try VisualImageInput.pixels(data:data as Data),expected=try VisualImageInput.resizedRGB(rgba:bytes,width:width,height:height)
        XCTAssertEqual(decoded.count,3*224*224)
        for i in 0..<(224*224) {for c in 0..<3 {XCTAssertEqual(decoded[c*224*224+i],(Float(expected[i*3+c])/255-0.5)/0.5,accuracy:0.000001)}}
    }
    func testUnsupportedBundleNeverLoadsOrCreatesFiles() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-vision-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        XCTAssertThrowsError(try VisualModelBundle.verify(at:root));XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
        try Paths.ensure(root);try Data("{}".utf8).write(to:root.appendingPathComponent("OSWIND-VISION.json"))
        XCTAssertThrowsError(try VisualModelBundle.verify(at:root))
        let runtime=VisualEncoder()
        do {_ = try await runtime.embed(pixels:[.nan],directory:root);XCTFail("Invalid tensor admitted")}catch{}
        do {_ = try await runtime.embed(pixels:[Float](repeating:2,count:3*224*224),directory:root);XCTFail("Unnormalized tensor admitted")}catch{}
        do {_ = try await runtime.embed(image:Data("bad".utf8),directory:root);XCTFail("Invalid image admitted")}catch{}
        do {_ = try await runtime.embed(text:String(repeating:"x",count:32769),directory:root);XCTFail("Oversized query admitted")}catch{}
        let resident=await runtime.resident;XCTAssertFalse(resident)
        do {_ = try await runtime.embed(text:"red car",directory:root);XCTFail("Bad bundle loaded")}catch{}
        let after=await runtime.resident;XCTAssertFalse(after)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["OSWIND-VISION.json"])
    }
    func testCancelledImagePreprocessing() async throws {
        let task=Task { () throws -> [UInt8] in
            withUnsafeCurrentTask {$0?.cancel()}
            return try VisualImageInput.resizedRGB(rgba:self.rgba(224,224),width:224,height:224)
        }
        do {_ = try await task.value;XCTFail("Cancellation ignored")}catch is CancellationError{}
    }
    func testPinnedNativeTokenizerParityAndModelLifecycle() async throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_VISUAL_MODEL_DIR"] else {throw XCTSkip("Opt-in local converted visual bundle; never downloaded by tests")}
        let directory=URL(fileURLWithPath:path),verified=try VisualModelBundle.verify(at:directory)
        struct Fixture:Decodable {var text:String;var ids:[Int]}
        let cases=try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:fixtures.appendingPathComponent("VisualTokenizer.json")))
        let tokenizer=try await VisualTokenizer(directory:directory)
        for fixture in cases {XCTAssertEqual(try tokenizer.encode(fixture.text).ids,fixture.ids,String(reflecting:fixture.text.prefix(60)))}
        XCTAssertTrue(try tokenizer.encode(String(repeating:"one ",count:100)).truncated)
        XCTAssertFalse(try tokenizer.encode("short").truncated)
        XCTAssertThrowsError(try tokenizer.encode(String(repeating:"x",count:32769)))
        let runtime=VisualEncoder();await runtime.setRetention(.untilQuit)
        let first=try await runtime.embed(text:"a red car",directory:directory,compute:.cpuOnly)
        let second=try await runtime.embed(text:"a red car",directory:directory,compute:.cpuOnly)
        XCTAssertEqual(first.modelID,verified.modelID);XCTAssertEqual(first.vector.count,768)
        XCTAssertGreaterThan(LocalEmbedder.cosine(first.vector,second.vector),0.99999)
        let active=await runtime.resident;XCTAssertTrue(active)
        await runtime.unload();let released=await runtime.resident;XCTAssertFalse(released)
        await runtime.setRetention(.afterUse)
        _ = try await runtime.embed(text:"a blue car",directory:directory,compute:.cpuOnly)
        for _ in 0..<100 {if !(await runtime.resident) {break};try await Task.sleep(for:.milliseconds(10))}
        let expired=await runtime.resident;XCTAssertFalse(expired)
        await runtime.unload()
        await runtime.setRetention(.untilQuit)
        let preparing=Task {try await runtime.embed(text:"a mountain",directory:directory,compute:.cpuOnly)}
        for _ in 0..<100 {if await runtime.resident {break};try await Task.sleep(for:.milliseconds(1))}
        await runtime.unload()
        do {_ = try await preparing.value;XCTFail("Released preparation became resident again")}catch is CancellationError{}
        let final=await runtime.resident;XCTAssertFalse(final)
    }
}
