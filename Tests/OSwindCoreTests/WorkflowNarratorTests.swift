import XCTest
@testable import OSwindCore

final class WorkflowNarratorTests:XCTestCase {
    private func withWorkspace(_ body:(BackupWorkspace,MemoryStore) async throws->Void)async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-workflow-narrator-"+UUID().uuidString),store=try MemoryStore(root:root)
        defer {try? FileManager.default.removeItem(at:root)}
        var workspace:BackupWorkspace?=try store.libraryWorkspace("oswind-workflow")
        do {
            try await body(try XCTUnwrap(workspace),store)
            try workspace?.cleanup();workspace=nil
            try store.close();XCTAssertTrue(store.isClosed)
        }catch {
            let original=error;try? workspace?.cleanup();workspace=nil;try? store.close();throw original
        }
    }
    func testExactScriptFixedVoiceAndIsolatedEnvironmentReachJoinedWorker()async throws {
        try await withWorkspace {workspace,_ in
        let script="Review the authored blue frame."
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
        }
    }
    func testWorkerFailureDoesNotManufactureReceipt()async throws {
        try await withWorkspace {workspace,_ in
        do {
            _ = try await LocalWorkflowNarrator.generate(script:"Owned script",step:1,workspace:workspace,helper:URL(fileURLWithPath:"/usr/bin/true"),environment:.init(run:{_,_,_,_ in throw OSwindError.unavailable("Owned worker failed")}))
            XCTFail("Failed worker returned narration")
        }catch OSwindError.unavailable(let message) {XCTAssertEqual(message,"Owned worker failed")}
        XCTAssertThrowsError(try workspace.tree.read("step-01-narration.wav",limit:1024))
        }
    }
    func testAlreadyCancelledNarrationStartsNoWorkerAndWritesNoScript()async throws {
        try await withWorkspace {workspace,_ in
            let task=Task {
                withUnsafeCurrentTask {$0?.cancel()}
                return try await LocalWorkflowNarrator.generate(script:"Owned script",step:1,workspace:workspace,helper:URL(fileURLWithPath:"/usr/bin/true"),environment:.init(run:{_,_,_,_ in XCTFail("Cancelled narration started worker")}))
            }
            do {_ = try await task.value;XCTFail("Cancelled narration returned")}catch is CancellationError {}catch {throw error}
            XCTAssertThrowsError(try workspace.tree.read("step-01-narration.txt",limit:1024))
        }
    }
    func testActualOwnedKokoroThroughProductionGuardianAndWorker()async throws {
        let env=ProcessInfo.processInfo.environment
        guard let helper=env["OSWIND_TEST_WORKFLOW_KOKORO_HELPER"],let guardian=env["OSWIND_TEST_WORKFLOW_GUARDIAN"] else {throw XCTSkip("Explicit owned local Kokoro worker fixture")}
        try await withWorkspace {workspace,_ in
            let result=try await LocalWorkflowNarrator.generate(script:"This retained replay frame is blue. OSwind links it to the original recording.",step:1,workspace:workspace,helper:URL(fileURLWithPath:helper),environment:.production(guardian:URL(fileURLWithPath:guardian)))
            XCTAssertEqual(result.receipt.voice,"af_heart");XCTAssertEqual(result.receipt.speed,1);XCTAssertGreaterThan(result.receipt.audioSeconds,1)
            if let destination=env["OSWIND_TEST_WORKFLOW_GENERATE_OUTPUT"] {
                let url=URL(fileURLWithPath:destination,isDirectory:true)
                guard !FileManager.default.fileExists(atPath:url.path) else {throw OSwindError.invalid("Choose a new owned narration output fixture")}
                try Paths.ensure(url);let tree=try BackupFileTree(root:url,writable:true)
                for ext in ["txt","wav","timing.json"] {_ = try workspace.tree.copy(result.stem+"."+ext,to:tree,as:result.stem+"."+ext)}
                try tree.write(JSONEncoder().encode(result.receipt),as:"receipt.json")
            }
        }
    }
}
