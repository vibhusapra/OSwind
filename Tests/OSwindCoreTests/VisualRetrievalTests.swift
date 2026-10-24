import XCTest
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
@testable import OSwindCore

private actor VisualTestGate {
    let entered=XCTestExpectation(description:"visual inference entered")
    private var continuation:CheckedContinuation<Void,Never>?
    func wait() async {await withCheckedContinuation {continuation=$0;entered.fulfill()}}
    func open(){continuation?.resume();continuation=nil}
}
private actor FixtureVisualEncoder:VisualEmbeddingService {
    var images=0,pixels=0,identities=0,batches=0,completedBatches=0
    let gate:VisualTestGate?
    let changedIdentity:Bool
    init(gate:VisualTestGate?=nil,changedIdentity:Bool=false) {self.gate=gate;self.changedIdentity=changedIdentity}
    func identity(directory:URL,compute:VisualCompute) -> String {identities+=1;return "fixture-visual"}
    func beginBatch() -> UUID {batches+=1;return UUID()}
    func endBatch(_ token:UUID) {completedBatches+=1}
    func setRetention(_ value:NativeModelRetention) {}
    func embed(text:String,directory:URL,compute:VisualCompute) -> VisualEmbedding {VisualEmbedding(modelID:"fixture-visual",vector:text.contains("blue") ? [0,1]:[1,0],seconds:0,truncated:false)}
    func embed(image:Data,directory:URL,compute:VisualCompute) async throws -> VisualEmbedding {
        images+=1;if let gate {await gate.wait()}
        let value=String(decoding:image,as:UTF8.self);if value=="corrupt" {throw OSwindError.invalid("Fixture decode failed")}
        return VisualEmbedding(modelID:changedIdentity ? "different-model":"fixture-visual",vector:value.contains("blue") ? [0,1]:[1,0],seconds:0,truncated:false)
    }
    func embed(pixels:[Float],directory:URL,compute:VisualCompute) -> VisualEmbedding {
        self.pixels+=1;let size=224*224,red=pixels[0..<size].reduce(0,+),blue=pixels[(2*size)..<(3*size)].reduce(0,+)
        return VisualEmbedding(modelID:"fixture-visual",vector:red>blue ? [1,0]:[0,1],seconds:0,truncated:false)
    }
}
final class VisualRetrievalTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    var configuration:VisualSearchConfiguration {var value=VisualSearchConfiguration();value.enabled=true;value.modelDirectory="/synthetic/local-model";return value}
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-visual-engine-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError() throws {try? store.close();store=nil;try? FileManager.default.removeItem(at:root)}
    @discardableResult func image(_ id:String,color:String,bundle:String="test.photos") throws -> Memory {
        let value=Memory(id:id,timestamp:Date(timeIntervalSince1970:100),app:"Photos",bundleID:bundle,title:"Image",text:"",imagePath:"images/\(id).dat")
        try Data(color.utf8).write(to:root.appendingPathComponent(value.imagePath!));try store.insert(value);return value
    }
    func testImageOnlyIndexResumeAndChangedBytesRebuild() async throws {
        try image("red",color:"red");try image("blue",color:"blue")
        let encoder=FixtureVisualEncoder(),engine=VisualRetrievalEngine(store:store,encoder:encoder)
        let first=try await engine.rebuild(configuration:configuration);XCTAssertEqual(first.indexedSources,2);XCTAssertEqual(first.failedSources,0)
        let red=try await engine.search(SearchFilter(query:"red window"),configuration:configuration)
        XCTAssertEqual(red.hits.first?.id,"red");XCTAssertNotNil(red.hits[0].visual)
        _ = try await engine.rebuild(configuration:configuration);let count=await encoder.images;XCTAssertEqual(count,2)
        try Data("blue".utf8).write(to:root.appendingPathComponent("images/red.dat"))
        _ = try await engine.rebuild(configuration:configuration);let changed=await encoder.images;XCTAssertEqual(changed,3)
        let missingRed=try await engine.search(SearchFilter(query:"red"),configuration:configuration);XCTAssertTrue(missingRed.hits.allSatisfy {$0.score==0})
        XCTAssertThrowsError(try store.hydrate(red.hits))
    }
    func testCurrentPrivacyRulesPreventInferenceAndHideExistingMatches() async throws {
        try image("one",color:"red",bundle:"test.blocked")
        let encoder=FixtureVisualEncoder(),engine=VisualRetrievalEngine(store:store,encoder:encoder)
        _ = try await engine.rebuild(configuration:configuration)
        var policy=PrivacyPolicy();policy.excludedApps.append("test.blocked")
        let hits=try await engine.search(SearchFilter(query:"red"),configuration:configuration,policy:policy);XCTAssertTrue(hits.hits.isEmpty)
        let rebuilt=try await engine.rebuild(configuration:configuration,policy:policy);XCTAssertEqual(rebuilt.skippedSources,1)
        let count=await encoder.images;XCTAssertEqual(count,1)
        XCTAssertEqual(try store.visualCoverage(modelID:"fixture-visual").indexedSources,0);XCTAssertNotNil(try store.get("one"))
        var browser=try XCTUnwrap(store.get("one"));browser.bundleID="com.apple.Safari";try store.insert(browser)
        let noURL=try await engine.rebuild(configuration:configuration);XCTAssertEqual(noURL.skippedSources,1)
    }
    func testLateSourceReplacementNeverAdmitsOriginalPixels() async throws {
        var memory=try image("one",color:"red");let gate=VisualTestGate(),encoder=FixtureVisualEncoder(gate:gate),engine=VisualRetrievalEngine(store:store,encoder:encoder),config=configuration
        let task=Task {try await engine.rebuild(configuration:config)}
        await fulfillment(of:[gate.entered],timeout:5)
        memory.title="replacement metadata";try store.insert(memory);await gate.open()
        let result=try await task.value;XCTAssertEqual(result.failedSources,1);XCTAssertEqual(try store.visualCoverage(modelID:"fixture-visual").indexedSources,0)
    }
    func testCancellationBeforeAdmissionLeavesNoPartialVisualIndex() async throws {
        try image("one",color:"red");let gate=VisualTestGate(),encoder=FixtureVisualEncoder(gate:gate),engine=VisualRetrievalEngine(store:store,encoder:encoder),config=configuration
        let task=Task {try await engine.rebuild(configuration:config)}
        await fulfillment(of:[gate.entered],timeout:5);task.cancel();await gate.open()
        do {_ = try await task.value;XCTFail("Cancelled visual work completed")}catch is CancellationError{}
        XCTAssertEqual(try store.visualCoverage(modelID:"fixture-visual").indexedSources,0)
    }
    func testModelChangeAbortsAndCorruptSourceDoesNotBlockGoodSources() async throws {
        try image("one",color:"red")
        let wrong=VisualRetrievalEngine(store:store,encoder:FixtureVisualEncoder(changedIdentity:true))
        do {_ = try await wrong.rebuild(configuration:configuration);XCTFail("Changed model accepted")}catch{}
        XCTAssertEqual(try store.visualCoverage(modelID:"fixture-visual").indexedSources,0)
        try image("corrupt",color:"corrupt")
        let engine=VisualRetrievalEngine(store:store,encoder:FixtureVisualEncoder()),result=try await engine.rebuild(configuration:configuration)
        XCTAssertEqual(result.indexedSources,1);XCTAssertEqual(result.failedSources,1);XCTAssertEqual(result.errors.count,1)
    }
    func testEmptyQueryBrowsesRetainedSourcesWithoutLoadingModel() async throws {
        try image("one",color:"red")
        let encoder=FixtureVisualEncoder(),engine=VisualRetrievalEngine(store:store,encoder:encoder)
        let result=try await engine.search(SearchFilter(),configuration:VisualSearchConfiguration())
        XCTAssertEqual(result.hits.map(\.id),["one"]);XCTAssertNil(result.modelID)
        do {_ = try await engine.search(SearchFilter(query:"red"),configuration:VisualSearchConfiguration());XCTFail("Disabled model used")}catch{}
        let calls=await encoder.images;XCTAssertEqual(calls,0)
    }
    func testPowerDeferralNeverReportsReady() async throws {
        try image("one",color:"red")
        let encoder=FixtureVisualEncoder(),engine=VisualRetrievalEngine(store:store,encoder:encoder)
        do {_ = try await engine.rebuild(configuration:configuration,shouldContinue:{false});XCTFail("Power deferral ignored")}catch{}
        XCTAssertEqual(try store.visualCoverage(modelID:"fixture-visual").indexedSources,0)
        let identities=await encoder.identities;XCTAssertEqual(identities,0)
    }
    func testVisualConfigurationDefaultsAndRoundTrip() throws {
        let old=try JSONDecoder().decode(AppSettings.self,from:Data("{}".utf8))
        XCTAssertFalse(old.search.visual.enabled);XCTAssertEqual(old.search.visual.compute,.cpuAndGPU)
        var settings=old;settings.search.visual=configuration;settings.search.visual.retention = .afterUse
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(settings)).search.visual,settings.search.visual)
    }
    func testMatchedImagePreviewRejectsChangedBytesAndCurrentPrivacy() async throws {
        let pixels=[UInt8](repeating:0,count:32*32*4).enumerated().map {index,_ in UInt8(index%4==0 || index%4==3 ? 255:0)}
        let provider=try XCTUnwrap(CGDataProvider(data:Data(pixels) as CFData)),space=try XCTUnwrap(CGColorSpace(name:CGColorSpace.sRGB))
        let image=try XCTUnwrap(CGImage(width:32,height:32,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:128,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let output=NSMutableData(),destination=try XCTUnwrap(CGImageDestinationCreateWithData(output,UTType.png.identifier as CFString,1,nil));CGImageDestinationAddImage(destination,image,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
        let memory=Memory(id:"preview",app:"Fixture",bundleID:"test.preview",text:"",imagePath:"images/preview.png")
        try (output as Data).write(to:root.appendingPathComponent(memory.imagePath!));try store.insert(memory)
        let snapshot=try XCTUnwrap(VisualImageSnapshot.make(store:store,id:memory.id))
        _ = try store.saveVisualVectors([.init(point:snapshot.plan.points[0],decodedTime:nil,vector:[1,0])],snapshot:snapshot,modelID:"fixture-visual");snapshot.release()
        let hit=try XCTUnwrap(store.searchVisual(SearchFilter(),vector:[1,0],modelID:"fixture-visual").hits.first),match=try XCTUnwrap(hit.visual)
        let preview=try await store.visualPreview(memory:memory,match:match),decoded=try VisualImageInput.pixels(image:preview)
        XCTAssertGreaterThan(decoded[0],0.9);XCTAssertLessThan(decoded[224*224*2],-0.9)
        var settings=AppSettings();settings.privacy.excludedApps.append("test.preview");try settings.save(root:root)
        do {_ = try await store.visualPreview(memory:memory,match:match);XCTFail("Excluded preview displayed")}catch{}
        try AppSettings().save(root:root);try Data("different bytes".utf8).write(to:root.appendingPathComponent(memory.imagePath!))
        do {_ = try await store.visualPreview(memory:memory,match:match);XCTFail("Changed pixels displayed")}catch{}
    }
    private func buffer(red:Bool) throws -> CVPixelBuffer {
        var pixel:CVPixelBuffer?;XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,128,96,kCVPixelFormatType_32BGRA,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&pixel),kCVReturnSuccess)
        let value=try XCTUnwrap(pixel);CVPixelBufferLockBaseAddress(value,[]);defer {CVPixelBufferUnlockBaseAddress(value,[])}
        let data=CVPixelBufferGetBaseAddress(value)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(value)
        for y in 0..<96 {for x in 0..<128 {let p=data.advanced(by:y*stride+x*4);p[0]=red ? 0:255;p[1]=0;p[2]=red ? 255:0;p[3]=255}}
        return value
    }
    func testRealVideoDecodeIndexesAllFramesAndReturnsMatchedTime() async throws {
        let path="video/colors.mov",url=root.appendingPathComponent(path),writer=try ReplayVideoEncoder(url:url,width:128,height:96,frameInterval:1,codec:"h264",hardwareRequired:false)
        try await writer.append(buffer(red:true),time:0);try await writer.append(buffer(red:false),time:1);try await writer.append(buffer(red:false),time:2);_ = try await writer.finish(duration:3)
        var memory=Memory(id:"clip",app:"Fixture",text:"");memory.videoPath=path;memory.visualRecording=VisualRecording(duration:3,width:128,height:96,codec:"h264",hardwareRequired:false,frames:[VisualFrame(time:0,text:"first"),VisualFrame(time:1,text:"second"),VisualFrame(time:2,text:"third")]);memory.text=memory.visualRecording!.text;try store.insert(memory)
        let encoder=FixtureVisualEncoder(),engine=VisualRetrievalEngine(store:store,encoder:encoder),result=try await engine.rebuild(configuration:configuration)
        let startedBatches=await encoder.batches,completedBatches=await encoder.completedBatches;XCTAssertEqual(startedBatches,1);XCTAssertEqual(completedBatches,1)
        XCTAssertEqual(result.failedSources,0,result.errors.joined(separator:"; "));XCTAssertEqual(result.indexedFrames,3)
        let blue=try await engine.search(SearchFilter(query:"blue"),configuration:configuration)
        XCTAssertEqual(blue.hits.count,1);XCTAssertEqual(blue.hits.first?.visual?.frameOrdinal,1);XCTAssertEqual(blue.hits.first?.visual?.decodedTime ?? -1,1,accuracy:0.1)
        let match=try XCTUnwrap(blue.hits.first?.visual),preview=try await store.visualPreview(memory:memory,match:match),decoded=try VisualImageInput.pixels(image:preview)
        XCTAssertGreaterThan(decoded[224*224*2],0.8);XCTAssertLessThan(decoded[0],-0.8)
        var altered=match;altered.decodedTime=2.8
        do {_ = try await store.visualPreview(memory:memory,match:altered);XCTFail("Invalid matched time displayed")}catch{}
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("video/.staging").path)).isEmpty)
    }
}
