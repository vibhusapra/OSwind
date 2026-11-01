import XCTest
@testable import OSwindCore

final class WorkflowTimelineTests:XCTestCase {
    func withWorkspace(_ body:(BackupWorkspace)throws->Void)throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-workflow-timeline-"+UUID().uuidString),store=try MemoryStore(root:root)
        defer {try? FileManager.default.removeItem(at:root)}
        var workspace:BackupWorkspace?=try store.libraryWorkspace("oswind-workflow")
        do {try body(try XCTUnwrap(workspace));try workspace?.cleanup();workspace=nil;try store.close();XCTAssertTrue(store.isClosed)}
        catch {let original=error;try? workspace?.cleanup();workspace=nil;try? store.close();throw original}
    }
    func draft()->WorkflowDraft {
        let source=WorkflowSourceBinding(library:String(repeating:"a",count:64),memoryID:"owned-screen",revision:String(repeating:"b",count:64),mediaSHA256:String(repeating:"c",count:64),kind:.image)
        return .init(title:"Owned audio timeline",steps:[.init(source:source,title:"First",narration:"First owned narration."),.init(source:source,title:"Second",narration:"Second owned narration.")])
    }
    func populate(_ workspace:BackupWorkspace,draft:WorkflowDraft)throws->[WorkflowNarrationResult] {
        var result=[WorkflowNarrationResult]()
        for (index,step) in draft.steps.enumerated() {
            let stem=String(format:"step-%02d-narration",index+1),count=index==0 ? 2400:3600,duration=Double(count)/24000
            let samples=(0..<count).map {Float(sin(Double($0)*2*Double.pi*Double(index==0 ? 440:660)/24000)*0.1)}
            try workspace.tree.write(Data(step.narration.utf8),as:stem+".txt")
            try workspace.tree.write(WAV.data(samples:samples,sampleRate:24000),as:stem+".wav")
            let timing:[String:Any] = ["model":"mlx-community/Kokoro-82M-bf16","voice":"af_heart","speed":1.0,"audio":workspace.url.appendingPathComponent(stem+".wav").path,"audio_seconds":duration,"chunks":[["start_seconds":0.0,"end_seconds":duration]]]
            try workspace.tree.write(JSONSerialization.data(withJSONObject:timing),as:stem+".timing.json")
            result.append(.init(stem:stem,receipt:try WorkflowNarrationAudio.inspect(tree:workspace.tree,stem:stem,script:step.narration)))
        }
        return result
    }
    func testCombinationPreservesEveryPCMByteAndMeasuredStepBoundary()throws {
        try withWorkspace {workspace in
            let d=draft(),inputs=try populate(workspace,draft:d),timeline=try LocalWorkflowTimeline.combine(draft:d,narrations:inputs,workspace:workspace)
            XCTAssertEqual(timeline.frames,6000);XCTAssertEqual(timeline.duration,0.25,accuracy:0.000001);XCTAssertEqual(timeline.draftRevision,try d.revision)
            XCTAssertEqual(timeline.steps.map(\.startFrame),[0,2400]);XCTAssertEqual(timeline.steps.map(\.endFrame),[2400,6000]);XCTAssertEqual(timeline.steps.map(\.stepID),d.steps.map(\.id))
            let joined=try workspace.tree.read("narration.wav",limit:1024*1024),first=try workspace.tree.read(inputs[0].stem+".wav",limit:1024*1024),second=try workspace.tree.read(inputs[1].stem+".wav",limit:1024*1024)
            var expected=Data(first.dropFirst(44));expected.append(contentsOf:second.dropFirst(44))
            XCTAssertEqual(Data(joined.dropFirst(44)),expected)
            XCTAssertEqual(try workspace.tree.read("narration.txt",limit:12300),Data(d.steps.map(\.narration).joined(separator:"\n\n").utf8))
            XCTAssertEqual(timeline.narration.frames,6000);XCTAssertEqual(timeline.narration.chunks.count,2)
        }
    }
    func testChangedReviewedScriptRefusesBeforeCombinedFilesExist()throws {
        try withWorkspace {workspace in
            var d=draft();let inputs=try populate(workspace,draft:d);d.steps[0].narration="Edited after measurement"
            XCTAssertThrowsError(try LocalWorkflowTimeline.combine(draft:d,narrations:inputs,workspace:workspace))
            XCTAssertThrowsError(try workspace.tree.read("narration.txt",limit:12300));XCTAssertThrowsError(try workspace.tree.read("narration.wav",limit:1024))
        }
    }
    func testChangedValidPCMRefusesBeforeCombinationAndPreservesReplacement()throws {
        try withWorkspace {workspace in
            let d=draft(),inputs=try populate(workspace,draft:d),replacement=WAV.data(samples:Array(repeating:0.25,count:2400),sampleRate:24000)
            try replacement.write(to:workspace.url.appendingPathComponent(inputs[0].stem+".wav"),options:.atomic)
            XCTAssertThrowsError(try LocalWorkflowTimeline.combine(draft:d,narrations:inputs,workspace:workspace))
            XCTAssertEqual(try workspace.tree.read(inputs[0].stem+".wav",limit:1024*1024),replacement)
            XCTAssertThrowsError(try workspace.tree.read("narration.wav",limit:1024))
        }
    }
}
