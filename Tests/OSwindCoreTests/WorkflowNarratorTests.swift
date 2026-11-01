import XCTest
@testable import OSwindCore

final class WorkflowNarratorTests:XCTestCase {
    func testExactScriptFixedVoiceAndIsolatedEnvironmentReachJoinedWorker()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-workflow-narrator-"+UUID().uuidString),store=try MemoryStore(root:root)
        defer {try? store.close();try? FileManager.default.removeItem(at:root)}
        let workspace=try store.libraryWorkspace("oswind-workflow"),script="Review the authored blue frame."
        let environment=WorkflowNarrationEnvironment {helper,args,env,keepAlive in
            XCTAssertEqual(helper.path,"/usr/bin/true");XCTAssertEqual(args,["--input",workspace.url.appendingPathComponent("step-01-narration.txt").path,"--output",workspace.url.appendingPathComponent("step-01-narration.wav").path,"--voice","af_heart","--speed","1.0"])
            XCTAssertEqual(env["HF_HUB_OFFLINE"],"1");XCTAssertEqual(env["TMPDIR"],workspace.url.path+"/");XCTAssertNil(env["OSWIND_TEST_PARENT_SECRET"]);XCTAssertNil(env["OPENAI_API_KEY"]);XCTAssertEqual(keepAlive.count,1)
            XCTAssertEqual(try workspace.tree.read("step-01-narration.txt",limit:4000),Data(script.utf8))
            let samples=(0..<4800).map {Float(sin(Double($0)*2*Double.pi*440/24000)*0.1)}
            try workspace.tree.write(WAV.data(samples:samples,sampleRate:24000),as:"step-01-narration.wav")
            let receipt:[String:Any] = ["model":"mlx-community/Kokoro-82M-bf16","voice":"af_heart","speed":1.0,"audio":workspace.url.appendingPathComponent("step-01-narration.wav").path,"audio_seconds":0.2,"chunks":[["start_seconds":0.0,"end_seconds":0.2]]]
            try workspace.tree.write(JSONSerialization.data(withJSONObject:receipt),as:"step-01-narration.timing.json")
        }
        let result=try await LocalWorkflowNarrator.generate(script:script,step:1,workspace:workspace,helper:URL(fileURLWithPath:"/usr/bin/true"),environment:environment)
        XCTAssertEqual(result.stem,"step-01-narration");XCTAssertEqual(result.receipt.frames,4800)
        try workspace.cleanup()
    }
    func testWorkerFailureDoesNotManufactureReceipt()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-workflow-narrator-failure-"+UUID().uuidString),store=try MemoryStore(root:root)
        defer {try? store.close();try? FileManager.default.removeItem(at:root)}
        let workspace=try store.libraryWorkspace("oswind-workflow")
        do {
            _ = try await LocalWorkflowNarrator.generate(script:"Owned script",step:1,workspace:workspace,helper:URL(fileURLWithPath:"/usr/bin/true"),environment:.init(run:{_,_,_,_ in throw OSwindError.unavailable("Owned worker failed")}))
            XCTFail("Failed worker returned narration")
        }catch OSwindError.unavailable(let message) {XCTAssertEqual(message,"Owned worker failed")}
        XCTAssertThrowsError(try workspace.tree.read("step-01-narration.wav",limit:1024))
        try workspace.cleanup()
    }
}
