import XCTest
import Darwin
@testable import OSwindCore

private final class PreparationDownloads:@unchecked Sendable {
    private let lock=NSLock();private var count=0
    func add(){lock.lock();count+=1;lock.unlock()}
    var value:Int {lock.lock();defer {lock.unlock()};return count}
}
private struct PreparationFixtureTransport:NativeModelTransport {
    let data:Data;let counter:PreparationDownloads
    func download(_ url:URL,to descriptor:Int32,expectedBytes:Int64,progress:@escaping @Sendable (Int64)->Void) async throws {
        counter.add();try Task.checkCancellation()
        try data.withUnsafeBytes {bytes in var offset=0;while offset<bytes.count {let n=write(descriptor,bytes.baseAddress!.advanced(by:offset),bytes.count-offset);guard n>0 else {throw OSwindError.unavailable("Fixture write failed")};offset+=n}}
        progress(Int64(data.count))
    }
}
final class VisualModelPreparationTests:XCTestCase {
    var root:URL!
    var repo:URL {URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()}
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-visual-prepare-test-"+UUID().uuidString);try Paths.ensure(root)}
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:root)}
    func testEmbeddedAssetsAreExactAndEnvironmentHasNoAmbientCredentials() throws {
        let runtime=try VisualPreparationRuntime.current(),assets=try VisualModelPreparation.verifiedAssets(repo,runtime:runtime)
        XCTAssertEqual(assets.count,5);XCTAssertEqual(runtime.python,"3.12.15");XCTAssertEqual(runtime.version,"0.13.5")
        let environment=VisualModelPreparation.environment(cache:root,temporary:root.appendingPathComponent("tmp"))
        for key in ["HOME","OPENAI_API_KEY","HF_TOKEN","GITHUB_TOKEN","AWS_ACCESS_KEY_ID","PYTHONPATH","UV_INDEX","HTTP_PROXY","UV_PREVIEW_FEATURES"] {XCTAssertNil(environment[key])}
        XCTAssertEqual(environment["NETRC"],"/dev/null");XCTAssertEqual(environment["HF_HUB_OFFLINE"],"1");XCTAssertEqual(environment["UV_KEYRING_PROVIDER"],"disabled")
        XCTAssertTrue(environment["UV_CREDENTIALS_DIR"]!.hasPrefix(root.path))
    }
    func testQualificationRequiresBothEncodersAndPoliciesAndBindsModelIdentity() throws {
        let measurements=[("image","CPU_ONLY"),("text","CPU_ONLY"),("image","CPU_AND_GPU"),("text","CPU_AND_GPU")].map {VisualPreparationQualification.Measurement(encoder:$0.0,requestedCompute:$0.1,minimumCosine:0.9995,passed:true)}
        var report=VisualPreparationQualification(recipe:VisualModelBundle.recipe,measurements:measurements);try report.validate()
        for cosine in [0.998,Double.infinity,Double.nan] {report.measurements[0].minimumCosine=cosine;XCTAssertThrowsError(try report.validate())}
        report.measurements=measurements;report.measurements.removeLast();XCTAssertThrowsError(try report.validate())
        report.measurements=measurements;report.measurements[0]=measurements[1];XCTAssertThrowsError(try report.validate())
        report.measurements=measurements;report.measurements[0].passed=false;XCTAssertThrowsError(try report.validate())
        report.measurements=measurements
        let receipt=VisualPreparationReceipt(modelID:"fixture-model",buildID:"fixture-build",runtimeVersion:"0.13.5",pythonVersion:"3.12.15",qualification:report)
        try receipt.validate(modelID:"fixture-model",buildID:"fixture-build")
        XCTAssertThrowsError(try receipt.validate(modelID:"changed-model",buildID:"fixture-build"));XCTAssertThrowsError(try receipt.validate(modelID:"fixture-model",buildID:"changed-build"))
    }
    func testChangedBundledScriptRefusesBeforeCacheCreationOrDownload() async throws {
        let runtime=try VisualPreparationRuntime.current(),assets=root.appendingPathComponent("assets"),cache=root.appendingPathComponent("never-cache"),counter=PreparationDownloads()
        for asset in runtime.assets {let target=assets.appendingPathComponent(asset.path);try Paths.ensure(target.deletingLastPathComponent());try Data(contentsOf:repo.appendingPathComponent(asset.path)).write(to:target)}
        try Data("modified".utf8).write(to:assets.appendingPathComponent("scripts/convert-visual-model.py"))
        do {_ = try await VisualModelPreparation.run(cache:cache,assetsRoot:assets,runtime:runtime,transport:PreparationFixtureTransport(data:Data(),counter:counter),progress:{_ in});XCTFail("Changed tools started")}catch {XCTAssertTrue(error.localizedDescription.contains("preparation tools changed"))}
        XCTAssertFalse(FileManager.default.fileExists(atPath:cache.path));XCTAssertEqual(counter.value,0)
    }
    func testPreparationCacheCannotBeInsideHistoryOrPreparedModel() async throws {
        let library=root.appendingPathComponent("library"),store=try MemoryStore(root:library);defer {try? store.close()}
        do {_ = try await VisualModelPreparation.prepare(cache:library.appendingPathComponent("cache"),assetsRoot:repo);XCTFail("Prepared inside history")}catch{}
        XCTAssertFalse(FileManager.default.fileExists(atPath:library.appendingPathComponent("cache").path))
        let model=root.appendingPathComponent("model");try Paths.ensure(model);try Data("{}".utf8).write(to:model.appendingPathComponent("OSWIND-VISION.json"))
        XCTAssertThrowsError(try NativeModelInstaller.requireCacheOutsideLibraries(model.appendingPathComponent("nested")))
    }
    func fixture() async throws -> (VisualPreparationRuntime,Data,Data,URL) {
        let payload=root.appendingPathComponent("tar-payload"),source=payload.appendingPathComponent("fixture/uv"),archive=root.appendingPathComponent("fixture.tar.gz"),body=Data("Owned executable fixture, never run".utf8)
        try Paths.ensure(source.deletingLastPathComponent());try body.write(to:source)
        let result=try await PreparationProcess.run(URL(fileURLWithPath:"/usr/bin/tar"),["-czf",archive.path,"-C",payload.path,"fixture/uv"],environment:[:],timeout:10);XCTAssertEqual(result.status,0)
        let data=try Data(contentsOf:archive),cache=root.appendingPathComponent("cache");try Paths.ensure(cache)
        var runtime=try VisualPreparationRuntime.current();runtime.member="fixture/uv";runtime.bytes=Int64(data.count);runtime.sha256=BackupSHA256.hex(data);runtime.executableBytes=Int64(body.count);runtime.executableSHA256=BackupSHA256.hex(body)
        return (runtime,data,body,cache)
    }
    func testPinnedArchiveInstallsAndCachedToolReusesWithoutNetworkThenRejectsTampering() async throws {
        let (runtime,data,body,cache)=try await fixture(),counter=PreparationDownloads(),tree=try BackupFileTree(root:cache),transport=PreparationFixtureTransport(data:data,counter:counter)
        let first=try await VisualModelPreparation.runtimeTool(cache:cache,parent:tree,runtime:runtime,transport:transport,environment:[:],progress:{_ in})
        XCTAssertEqual(try Data(contentsOf:first),body);XCTAssertEqual(counter.value,1)
        let attributes=try FileManager.default.attributesOfItem(atPath:first.path);XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o700)
        let license=Data("Owned fixture license".utf8)
        let second=try await VisualModelPreparation.runtimeTool(cache:cache,parent:tree,runtime:runtime,transport:transport,environment:[:],license:license,progress:{_ in})
        XCTAssertEqual(first,second);XCTAssertEqual(counter.value,1)
        XCTAssertEqual(try Data(contentsOf:first.deletingLastPathComponent().appendingPathComponent("LICENSE-MIT.txt")),license)
        try Data("tampered".utf8).write(to:first)
        do {_ = try await VisualModelPreparation.runtimeTool(cache:cache,parent:tree,runtime:runtime,transport:transport,environment:[:],progress:{_ in});XCTFail("Changed executable accepted")}catch{}
        XCTAssertEqual(try Data(contentsOf:first),Data("tampered".utf8));XCTAssertEqual(counter.value,1)
    }
    func testWrongArchiveHashCannotPublishTool() async throws {
        var (runtime,data,_,cache)=try await fixture();runtime.sha256=String(repeating:"0",count:64)
        let counter=PreparationDownloads(),tree=try BackupFileTree(root:cache)
        do {_ = try await VisualModelPreparation.runtimeTool(cache:cache,parent:tree,runtime:runtime,transport:PreparationFixtureTransport(data:data,counter:counter),environment:[:],progress:{_ in});XCTFail("Bad archive published")}catch{}
        XCTAssertFalse(FileManager.default.fileExists(atPath:cache.appendingPathComponent("uv-"+runtime.version).path));XCTAssertEqual(counter.value,1)
    }
}
