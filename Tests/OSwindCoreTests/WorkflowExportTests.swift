import XCTest
@testable import OSwindCore

private actor WorkflowExportGate {
    nonisolated let entered=XCTestExpectation(description:"owned narration worker entered")
    private var continuation:CheckedContinuation<Void,Never>?
    private(set) var input:URL?
    private var opened=false
    func wait(_ input:URL)async {self.input=input;if opened {return};await withCheckedContinuation {continuation=$0;entered.fulfill()}}
    func open() {opened=true;continuation?.resume();continuation=nil}
}
final class WorkflowExportTests:XCTestCase {
    func withFixture(_ body:(URL,MemoryStore,WorkflowDraft,URL)async throws->Void)async throws {
        let (root,store)=try WorkflowFrameTests.fixture(),parent=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-workflow-output-"+UUID().uuidString)
        try Paths.ensure(parent)
        defer {try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:parent)}
        do {
            let frame=try await NarratedWorkflow.preview(store:store,memoryID:"owned-screen"),draft=WorkflowDraft(title:"Owned workflow",steps:[.init(source:frame.source,title:"Inspect the authored source",narration:"Review the owned source.")])
            try await body(root,store,draft,parent)
            try store.close();XCTAssertTrue(store.isClosed)
        }catch {let original=error;try? store.close();throw original}
    }
    static var environment:WorkflowExportEnvironment {
        .init(narration:.init(run:{_,args,_,_ in
            let input=URL(fileURLWithPath:args[1]),output=URL(fileURLWithPath:args[3]),script=try String(contentsOf:input,encoding:.utf8)
            XCTAssertFalse(script.isEmpty)
            let samples=(0..<12000).map {Float(sin(Double($0)*2*Double.pi*440/24000)*0.1)}
            try WAV.data(samples:samples,sampleRate:24000).write(to:output)
            let timing:[String:Any] = ["model":"mlx-community/Kokoro-82M-bf16","voice":"af_heart","speed":1.0,"audio":output.path,"audio_seconds":0.5,"chunks":[["start_seconds":0.0,"end_seconds":0.5]]]
            try JSONSerialization.data(withJSONObject:timing).write(to:output.deletingPathExtension().appendingPathExtension("timing.json"))
        }),hardwareRequired:false)
    }
    func run(store:MemoryStore,draft:WorkflowDraft,to destination:URL,permit:WorkflowExportPermit = .init(),environment:WorkflowExportEnvironment = WorkflowExportTests.environment,progress:@escaping @Sendable(WorkflowExportProgress)async throws->Void={_ in})async throws->WorkflowExportInfo {
        try await NarratedWorkflow.export(store:store,draft:draft,destination:destination,options:.init(narrationHelper:URL(fileURLWithPath:"/usr/bin/true")),permit:permit,environment:environment,progress:progress)
    }
    func testExplicitExportPublishesPortableFilesAndNoLibraryOrCredentialPayload()async throws {
        try await withFixture {root,store,draft,parent in
            let destination=parent.appendingPathComponent("Owned.workflow"),permit=WorkflowExportPermit(),info=try await run(store:store,draft:draft,to:destination,permit:permit)
            XCTAssertEqual(info.steps,1);XCTAssertEqual(info.duration,0.5,accuracy:0.000001);XCTAssertTrue(info.plaintextIndependentCopy);XCTAssertFalse(permit.canCancel)
            let tree=try BackupFileTree(root:destination),manifest=try XCTUnwrap(JSONSerialization.jsonObject(with:tree.read("workflow.json",limit:1024*1024)) as? [String:Any])
            XCTAssertEqual(manifest["encrypted"] as? Bool,false);XCTAssertEqual(manifest["sourceDeletionUpdatesExport"] as? Bool,false)
            for file in try XCTUnwrap(manifest["files"] as? [[String:Any]]) {
                let path=try XCTUnwrap(file["path"] as? String),hash=try XCTUnwrap(file["sha256"] as? String)
                XCTAssertEqual(try tree.digest(path).sha256,hash)
            }
            for name in ["narration.timing.json","step-01-narration.timing.json"] {
                let bytes=try tree.read(name,limit:64*1024),value=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
                XCTAssertFalse(try XCTUnwrap(value["audio"] as? String).hasPrefix("/"));XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains(root.path))
            }
            XCTAssertEqual(try tree.digest("workflow.mp4").sha256,info.movieSHA256)
            XCTAssertThrowsError(try tree.read("settings.json",limit:1024));XCTAssertThrowsError(try tree.read("memory.sqlite",limit:1024))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("video/.staging").path).isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:parent.path),["Owned.workflow"])
        }
    }
    func testExistingDestinationRefusesBeforeAnyNarrationAndKeepsOriginalBytes()async throws {
        try await withFixture {_,store,draft,parent in
            let destination=parent.appendingPathComponent("Existing"),marker=Data("Owned existing output".utf8);try Paths.ensure(destination);try marker.write(to:destination.appendingPathComponent("marker"))
            var environment=Self.environment;environment.narration.run={_,_,_,_ in XCTFail("Existing destination started narration")}
            do {_ = try await run(store:store,draft:draft,to:destination,environment:environment);XCTFail("Existing export replaced")}catch {}
            XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("marker")),marker)
        }
    }
    func testInsideLibraryDestinationRefusesBeforeNarration()async throws {
        try await withFixture {root,store,draft,_ in
            let destination=root.appendingPathComponent("MustNotExport")
            do {_ = try await run(store:store,draft:draft,to:destination);XCTFail("Export inside source admitted")}catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        }
    }
    func testChangedSettingsAtFinalPublicationRemoveUnpublishedCopy()async throws {
        try await withFixture {root,store,draft,parent in
            let destination=parent.appendingPathComponent("Refused")
            do {
                _ = try await run(store:store,draft:draft,to:destination,progress:{stage in
                    if stage.phase == .publishing {var changed=AppSettings();changed.privacy.retainImages=false;try changed.save(root:root)}
                });XCTFail("Stale privacy export published")
            }catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path));XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:parent.path).isEmpty)
        }
    }
    func testChangedSourceAtFinalPublicationRemoveUnpublishedCopy()async throws {
        try await withFixture {_,store,draft,parent in
            let destination=parent.appendingPathComponent("Refused")
            do {
                _ = try await run(store:store,draft:draft,to:destination,progress:{stage in
                    if stage.phase == .publishing {var changed=try XCTUnwrap(store.get("owned-screen"));changed.text="Changed owned source";try store.insert(changed)}
                });XCTFail("Changed source export published")
            }catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path));XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:parent.path).isEmpty)
        }
    }
    func testRevokedPermitBeforePublicationRemovesUnpublishedCopy()async throws {
        try await withFixture {_,store,draft,parent in
            let destination=parent.appendingPathComponent("Cancelled"),permit=WorkflowExportPermit()
            do {
                _ = try await run(store:store,draft:draft,to:destination,permit:permit,progress:{stage in if stage.phase == .publishing {XCTAssertTrue(permit.invalidate())}});XCTFail("Revoked export published")
            }catch is CancellationError {}catch {throw error}
            XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path));XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:parent.path).isEmpty)
        }
    }
    func testSensitiveEditedScriptRefusesBeforeNarration()async throws {
        try await withFixture {_,store,original,parent in
            var draft=original;draft.steps[0].narration="password: owned-fixture-secret"
            var environment=Self.environment;environment.narration.run={_,_,_,_ in XCTFail("Sensitive script reached narration")}
            do {_ = try await run(store:store,draft:draft,to:parent.appendingPathComponent("Refused"),environment:environment);XCTFail("Sensitive script exported")}catch {}
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:parent.path).isEmpty)
        }
    }
    func testTitlesAndCaptionPayloadCannotInjectHTMLOrExtraCues()async throws {
        try await withFixture {_,store,original,parent in
            var draft=original;draft.title="<script>owned()</script>";draft.steps[0].narration="Owned <b>text</b> & source.\n\n00:00:00.000 --> fake"
            let destination=parent.appendingPathComponent("Escaped");_ = try await run(store:store,draft:draft,to:destination)
            let tree=try BackupFileTree(root:destination),html=String(decoding:try tree.read("index.html",limit:128*1024),as:UTF8.self),vtt=String(decoding:try tree.read("captions.vtt",limit:128*1024),as:UTF8.self)
            XCTAssertFalse(html.contains("<script>"));XCTAssertTrue(html.contains("&lt;script&gt;"));XCTAssertFalse(vtt.contains("<b>"));XCTAssertEqual(vtt.components(separatedBy:" --> ").count-1,1)
        }
    }
    func testCancelledNoncooperativeNarratorKeepsReservationUntilActualWorkerReturns()async throws {
        try await withFixture {root,store,draft,parent in
            let gate=WorkflowExportGate(),permit=WorkflowExportPermit(),destination=parent.appendingPathComponent("Cancelled")
            var env=Self.environment;env.narration.run={_,args,_,_ in await gate.wait(URL(fileURLWithPath:args[1]))}
            let environment=env
            let task=Task {try await self.run(store:store,draft:draft,to:destination,permit:permit,environment:environment)}
            do {
            await fulfillment(of:[gate.entered],timeout:5)
            XCTAssertTrue(permit.invalidate());task.cancel()
            let captured=await gate.input,input=try XCTUnwrap(captured)
            XCTAssertTrue(FileManager.default.fileExists(atPath:input.path))
            XCTAssertThrowsError(try MediaAdmissionLease.acquire(root:root,exclusive:true,timeout:0.02),"Cancelled-but-running worker released its library reservation")
            await gate.open()
            do {_ = try await task.value;XCTFail("Cancelled export returned success")}catch is CancellationError {}catch {throw error}
            XCTAssertFalse(FileManager.default.fileExists(atPath:input.path));XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
            let exclusive=try MediaAdmissionLease.acquire(root:root,exclusive:true,timeout:1);exclusive.release()
            XCTAssertNotNil(try store.get("owned-screen"))
            }catch {let original=error;permit.invalidate();task.cancel();await gate.open();_ = try? await task.value;throw original}
        }
    }
}
