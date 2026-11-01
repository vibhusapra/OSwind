import XCTest
@testable import OSwindCore

final class NativeVaultWorkflowExportTests:XCTestCase {
    func testOwnedWorkflowExportReleasesMountedFilesBeforeNormalLockAndRetainsHistory()async throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_VAULT"]=="1" else {throw XCTSkip("Owned encrypted workflow export fixture")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-native-workflow-"+UUID().uuidString);try Paths.ensure(root)
        let trace=OwnedVaultNativeTrace(root:root),driver=NativeVaultDriver(observer:{trace.append($0)},willMutate:{trace.beforeMutation($0,$1)})
        let package=root.appendingPathComponent("Fixture.oswindvault"),secret=Data(UUID().uuidString.utf8),vault=try LibraryVault(package:package,nativeDriver:driver)
        var active:MemoryStore?
        do {
            _ = try await LibraryVault.create(at:package,name:"Owned workflow lifecycle",capacityGiB:1,passphrase:secret,nativeDriver:driver)
            trace.setStage("workflow-unlock");_ = try await vault.unlock(passphrase:secret)
            let (_,store)=try WorkflowFrameTests.fixture(root:vault.libraryURL);active=store
            try store.insert(Memory(id:"owned-workflow-history",kind:.note,text:"Owned workflow history survives normal lock"))
            let preview=try await NarratedWorkflow.preview(store:store,memoryID:"owned-screen"),draft=WorkflowDraft(title:"Owned encrypted workflow",steps:[.init(source:preview.source,title:preview.title,narration:"Review the owned source.")])
            trace.setStage("workflow-export")
            let destination=root.appendingPathComponent("ExplicitIndependentWorkflow")
            _ = try await NarratedWorkflow.export(store:store,draft:draft,destination:destination,options:.init(narrationHelper:URL(fileURLWithPath:"/usr/bin/true")),permit:.init(),environment:WorkflowExportTests.environment,progress:{_ in})
            XCTAssertTrue(FileManager.default.fileExists(atPath:destination.appendingPathComponent("workflow.mp4").path))
            trace.setStage("workflow-lock")
            let locked=try await vault.lock(store:store);active=nil
            XCTAssertTrue(store.isClosed);XCTAssertEqual(locked.state,.locked);XCTAssertFalse(locked.imageAttached)
            XCTAssertFalse(preview.png.isEmpty) // Retaining preview bytes must not pin the mounted volume.
            let boundaries=trace.snapshot().beforeMutations.filter {$0.stage=="workflow-lock"}
            XCTAssertFalse(boundaries.isEmpty);XCTAssertTrue(boundaries.allSatisfy {$0.ownedHandles.allSatisfy {!$0.mounted}})
            trace.setStage("workflow-history-reopen");_ = try await vault.unlock(passphrase:secret)
            let reopened=try MemoryStore(root:vault.libraryURL);active=reopened
            XCTAssertEqual(try reopened.get("owned-workflow-history")?.text,"Owned workflow history survives normal lock")
            trace.setStage("workflow-final-lock");_ = try await vault.lock(store:reopened);active=nil
            let inventory=try await VaultProcess.run("/usr/bin/hdiutil",["info","-plist"]);XCTAssertEqual(inventory.status,0)
            let plist=try XCTUnwrap(PropertyListSerialization.propertyList(from:inventory.stdout,format:nil) as? [String:Any]),images=try XCTUnwrap(plist["images"] as? [[String:Any]])
            let image=package.appendingPathComponent("contents.sparsebundle").standardizedFileURL.resolvingSymlinksInPath()
            XCTAssertFalse(images.contains {value in (value["image-path"] as? String).map {URL(fileURLWithPath:$0).standardizedFileURL.resolvingSymlinksInPath()==image} ?? false})
            try trace.save(root:root,secret:secret,failed:false);try FileManager.default.removeItem(at:root)
        }catch {
            let original=error;trace.markFailure();try? active?.close();_ = try? await vault.lock()
            do {try trace.save(root:root,secret:secret,failed:true)}catch {print("Owned workflow trace could not be saved; original error preserved")}
            throw original
        }
    }
}
