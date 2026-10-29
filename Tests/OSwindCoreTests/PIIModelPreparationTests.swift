import XCTest
import Darwin
@testable import OSwindCore

final class PIIModelPreparationTests:XCTestCase {
    actor Gate {
        nonisolated let entered=XCTestExpectation(description:"owned setup paused")
        private var continuation:CheckedContinuation<Void,Never>?
        func wait() async {await withCheckedContinuation {continuation=$0;entered.fulfill()}}
        func open() {continuation?.resume();continuation=nil}
    }
    actor Transport:NativeModelTransport {
        var calls=0,descriptorWasLive=false
        let gate:Gate?
        init(gate:Gate?=nil) {self.gate=gate}
        func download(_ url:URL,to fd:Int32,expectedBytes:Int64,progress:@escaping @Sendable (Int64)->Void) async throws {
            calls+=1;if let gate {await gate.wait()}
            descriptorWasLive=fcntl(fd,F_GETFD)>=0
            var byte:UInt8=120;guard Darwin.write(fd,&byte,1)==1 else {throw OSwindError.unavailable("fixture descriptor closed early")}
        }
    }
    func root()->URL {FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-pii-setup-test-\(UUID().uuidString)",isDirectory:true)}
    func refused(_ operation:() async throws -> PIIModelInstallation) async {
        do {_ = try await operation();XCTFail("Invalid preparation published a model")} catch {}
    }
    func testPinnedCatalogHasBoundedDownloadsLicensesPatchesAndKnownSamples()throws {
        let c=try PIISetupCatalog.current()
        XCTAssertEqual(c.downloadBytes,201963274);XCTAssertEqual(c.installedFiles.count,12)
        XCTAssertEqual(c.patches.count,6);XCTAssertEqual(c.samples.count,2)
        XCTAssertTrue(c.modelLicense.contains("Apache License"));XCTAssertTrue(c.installedFiles.contains {$0.path=="licenses/Ettin-MIT.txt"})
        XCTAssertEqual(c.installedFiles.first {$0.path=="runtime/libonnxruntime.1.24.2.dylib"}?.sha256,"94e1e79a7eae49dd6dec88c2ada0bf30ed2f04f02dd03abc12d7d8ebed92cdfa")
    }
    func testMalformedRecipesRefuseWithoutArithmeticTraps()throws {
        let good=try PIISetupCatalog.current()
        var cases=[PIISetupCatalog]()
        var c=good;c.files[0].bytes = .max;cases.append(c)
        c=good;c.files[0].url=URL(string:"http://example.test/model")!;cases.append(c)
        c=good;c.files[0].path="../model";cases.append(c)
        c=good;c.files[1].path=c.files[0].path.uppercased();cases.append(c)
        c=good;c.patches[1].offset=0;cases.append(c)
        c=good;c.patches[0].before="0g";cases.append(c)
        c=good;c.samples[0].ranges[0].location = .max;cases.append(c)
        c=good;c.samples[0].ranges[0].length = .max;cases.append(c)
        c=good;c.samples[0].sourceSHA256=String(repeating:"0",count:64);cases.append(c)
        c=good;c.revision=String(repeating:"z",count:40);cases.append(c)
        for item in cases {XCTAssertThrowsError(try item.validate())}
    }
    func testVerifyMissingCacheNeverCreatesAnythingOrDownloads() async throws {
        let location=root(),transport=Transport(),catalog=try PIISetupCatalog.current()
        await refused {try await PIIModelPreparation.run(cache:location,verifyOnly:true,catalog:catalog,transport:transport)}
        XCTAssertFalse(FileManager.default.fileExists(atPath:location.path));let calls=await transport.calls;XCTAssertEqual(calls,0)
        await refused {try await PIIModelPreparation.verify(cache:location)}
        XCTAssertFalse(FileManager.default.fileExists(atPath:location.path))
    }
    func testCancelledBeforeStartCannotCreateCache() async throws {
        let location=root(),transport=Transport(),catalog=try PIISetupCatalog.current(),gate=Gate()
        let job=Task {await gate.wait();return try await PIIModelPreparation.run(cache:location,verifyOnly:false,catalog:catalog,transport:transport)}
        await fulfillment(of:[gate.entered],timeout:5);job.cancel();await gate.open()
        await refused {try await job.value};XCTAssertFalse(FileManager.default.fileExists(atPath:location.path))
        let calls=await transport.calls;XCTAssertEqual(calls,0)
    }
    func testChecksumFailurePublishesNothingAndCleansBothWorkspaces() async throws {
        let location=root(),transport=Transport(),catalog=try PIISetupCatalog.current();defer {try? FileManager.default.removeItem(at:location)}
        await refused {try await PIIModelPreparation.run(cache:location,verifyOnly:false,catalog:catalog,transport:transport)}
        let entries=try FileManager.default.contentsOfDirectory(atPath:location.path)
        XCTAssertEqual(entries,[".pii-prepare.lock"]);let calls=await transport.calls;XCTAssertEqual(calls,1)
    }
    func testInFlightCancellationJoinsDescriptorWriterBeforeCleaning() async throws {
        let location=root(),gate=Gate(),transport=Transport(gate:gate),catalog=try PIISetupCatalog.current();defer {try? FileManager.default.removeItem(at:location)}
        let job=Task {try await PIIModelPreparation.run(cache:location,verifyOnly:false,catalog:catalog,transport:transport)}
        await fulfillment(of:[gate.entered],timeout:5);job.cancel()
        XCTAssertGreaterThan(try FileManager.default.contentsOfDirectory(atPath:location.path).count,1)
        await gate.open();await refused {try await job.value}
        let live=await transport.descriptorWasLive;XCTAssertTrue(live)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:location.path),[".pii-prepare.lock"])
    }
    func testConcurrentReservationAndSymlinkLockRefuseBeforeNetwork() async throws {
        let location=root(),transport=Transport(),catalog=try PIISetupCatalog.current();defer {try? FileManager.default.removeItem(at:location)}
        try FileManager.default.createDirectory(at:location,withIntermediateDirectories:false)
        let lockURL=location.appendingPathComponent(".pii-prepare.lock"),fd=open(lockURL.path,O_CREAT|O_RDWR|O_CLOEXEC,0o600)
        XCTAssertGreaterThanOrEqual(fd,0);defer {close(fd)};XCTAssertEqual(flock(fd,LOCK_EX|LOCK_NB),0)
        await refused {try await PIIModelPreparation.run(cache:location,verifyOnly:false,catalog:catalog,transport:transport)}
        XCTAssertEqual(flock(fd,LOCK_UN),0);try FileManager.default.removeItem(at:lockURL)
        let sentinel=location.appendingPathComponent("keep");try Data("owned keep".utf8).write(to:sentinel)
        try FileManager.default.createSymbolicLink(at:lockURL,withDestinationURL:sentinel)
        await refused {try await PIIModelPreparation.run(cache:location,verifyOnly:false,catalog:catalog,transport:transport)}
        XCTAssertEqual(try Data(contentsOf:sentinel),Data("owned keep".utf8));let calls=await transport.calls;XCTAssertEqual(calls,0)
    }
    func testCorruptExistingInstallationIsNeverReplacedOrDownloadedOver() async throws {
        let location=root(),transport=Transport(),catalog=try PIISetupCatalog.current();defer {try? FileManager.default.removeItem(at:location)}
        let destination=location.appendingPathComponent("gliner-pii-"+PIISetupCatalog.buildID.prefix(16))
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        let sentinel=destination.appendingPathComponent("keep");try Data("original".utf8).write(to:sentinel)
        await refused {try await PIIModelPreparation.run(cache:location,verifyOnly:false,catalog:catalog,transport:transport)}
        XCTAssertEqual(try Data(contentsOf:sentinel),Data("original".utf8));let calls=await transport.calls;XCTAssertEqual(calls,0)
    }
    func testCachesInsideLibrariesBackupsOrPreparedPIIModelsRefuse() async throws {
        let location=root(),catalog=try PIISetupCatalog.current();defer {try? FileManager.default.removeItem(at:location)}
        try FileManager.default.createDirectory(at:location,withIntermediateDirectories:false)
        for marker in ["memory.sqlite","OSWIND-PII.json","OSWIND-MODEL.json"] {
            let file=location.appendingPathComponent(marker);try Data("owned marker".utf8).write(to:file)
            let transport=Transport(),cache=location.appendingPathComponent("nested")
            await refused {try await PIIModelPreparation.run(cache:cache,verifyOnly:false,catalog:catalog,transport:transport)}
            XCTAssertFalse(FileManager.default.fileExists(atPath:cache.path));let calls=await transport.calls;XCTAssertEqual(calls,0)
            try FileManager.default.removeItem(at:file)
        }
    }
    func testReceiptRequiresBothPoliciesAndAllCompatibilitySamples()throws {
        let catalog=try PIISetupCatalog.current()
        let bad=PIISetupReceipt(format:1,buildID:PIISetupCatalog.buildID,modelRevision:catalog.revision,runtimeVersion:catalog.runtimeVersion,compatibilitySamples:2,computePolicies:[.cpu],preparedOS:"owned fixture")
        XCTAssertThrowsError(try bad.validate(catalog:catalog))
    }
    func testNativeStreamingMetadataDerivativeMatchesIndependentONNXBytes()throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_PII_MODEL_DIR"] else {throw XCTSkip("Explicit pinned local PII model opt-in absent")}
        let location=root();try FileManager.default.createDirectory(at:location,withIntermediateDirectories:false);defer {try? FileManager.default.removeItem(at:location)}
        let workspace=try BackupWorkspace(in:location,label:"oswind-pii-shape-test")
        let original=try BackupFileTree(root:URL(fileURLWithPath:path))
        _ = try original.pin("onnx/model.onnx",to:workspace.tree,as:"model/onnx/model.onnx")
        let catalog=try PIISetupCatalog.current();try PIIModelPreparation.deriveBucket(in:workspace.tree,catalog:catalog)
        let derived=try workspace.tree.digest("model/onnx/model-bucket128.onnx",limit:catalog.bucketBytes)
        XCTAssertEqual(derived.bytes,catalog.bucketBytes);XCTAssertEqual(derived.sha256,catalog.bucketSHA256)
        withExtendedLifetime(workspace){}
    }
    func testRealPreparedReuseAndVerifyNeverInvokeNetworkExtractorOrInference() async throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_PII_SETUP_CACHE"] else {throw XCTSkip("Explicit owned prepared PII cache opt-in absent")}
        let catalog=try PIISetupCatalog.current(),transport=Transport(),cache=URL(fileURLWithPath:path)
        for verifyOnly in [true,false] {
            let result=try await PIIModelPreparation.run(cache:cache,verifyOnly:verifyOnly,catalog:catalog,transport:transport,
                extractor:{_,_,_ in throw OSwindError.invalid("reuse unexpectedly extracted")},
                qualifier:{_,_,_ in throw OSwindError.invalid("reuse unexpectedly inferred")})
            XCTAssertTrue(result.reused);XCTAssertEqual(result.bytes,393488824)
        }
        let calls=await transport.calls;XCTAssertEqual(calls,0)
    }
}
