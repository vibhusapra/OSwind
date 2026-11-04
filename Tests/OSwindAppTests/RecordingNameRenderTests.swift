import XCTest
import AppKit
import SwiftUI
@testable import OSwindCore
@testable import OSwind

/// Authored native component rasters, never a general desktop screenshot.
@MainActor final class RecordingNameRenderTests:XCTestCase {
    private var root:URL!,app:AppModel!,extra=[RecordedMeetingsModel]()
    override func setUpWithError()throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-recording-name-render-"+UUID().uuidString)
        app=try AppModel(root:root.appendingPathComponent("library"),startServices:false,recordingsLocked:{false})
        app.showOnboarding=false
    }
    override func tearDown()async throws {
        extra.forEach {$0.deactivate()};app.prepareForLibrarySwitch();await app.cancelExternalWorkAndWait()
        try app.store.close();app=nil;try FileManager.default.removeItem(at:root)
    }
    private func settle(_ archive:RecordedMeetingsModel)async throws {
        let end=SuspendingClock.now.advanced(by:.seconds(15))
        while archive.busy || archive.names.loading || archive.names.saving,SuspendingClock.now<end {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(archive.busy);XCTAssertFalse(archive.names.loading);XCTAssertFalse(archive.names.saving)
    }
    private func render<Content:View>(_ content:Content,size:NSSize,dark:Bool,to path:URL,ready:()async throws->Void)async throws {
        let view=NSHostingView(rootView:content.frame(width:size.width,height:size.height).background(Color(nsColor:.windowBackgroundColor)).preferredColorScheme(dark ? .dark:.light))
        let window=NSWindow(contentRect:.init(origin:.zero,size:size),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=view
        defer {window.contentView=nil;window.close()}
        view.layoutSubtreeIfNeeded();window.displayIfNeeded();try await ready()
        try await Task.sleep(for:.milliseconds(250));view.layoutSubtreeIfNeeded();window.displayIfNeeded()
        let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:bitmap)
        let bytes=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]));try bytes.write(to:path,options:.withoutOverwriting)
        XCTAssertGreaterThan(bytes.count,4000)
    }
    func testRenderNamesConflictsEditorsAndDraftRecoveryInBothAppearances()async throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_RECORDING_NAMES_UI_QA_DIR"] else {throw XCTSkip("Explicit owned recording-name component output required")}
        let output=URL(fileURLWithPath:path);try Paths.ensure(output)
        var original=Memory(id:"authored-recording",timestamp:Date(timeIntervalSince1970:1_793_700_000),endTimestamp:Date(timeIntervalSince1970:1_793_701_800),kind:.audio,app:"Owned meeting",bundleID:"owned.meeting",title:"Original studio capture",text:"Authored UI fixture. No microphone, system audio or ASR was used.")
        original.audioSessionID="owned-render-session";try app.store.insert(original)
        let source=try XCTUnwrap(app.store.recordedMeetingPage().sources.first)
        let saved=try app.store.saveRecordedMeetingName("Planning review and launch checklist",for:source)
        let archive=app.recordedMeetings
        func workspace(_ state:String,_ expected:Int)async throws {
            for dark in [false,true] {for (suffix,size) in [("regular",NSSize(width:1120,height:800)),("compact",NSSize(width:900,height:660))] {
                archive.activate()
                try await render(RecordedMeetingsView(model:archive).environmentObject(app),size:size,dark:dark,to:output.appendingPathComponent(state+"-"+suffix+(dark ? "-dark.png":"-light.png"))) {
                    try await self.settle(archive);XCTAssertEqual(archive.names.rows.count,expected);XCTAssertTrue(archive.names.loaded)
                }
                archive.deactivate()
            }}
        }
        try await workspace("named",1)
        var extraNames=[String]()
        for index in 1...8 {
            var value=try XCTUnwrap(app.store.get(saved.id));value.id="authored-name-conflict-\(index)";value.title="Alternative planning title \(index): roadmap, launch and follow-up"
            try app.store.insert(value);extraNames.append(value.id)
        }
        try await workspace("conflicts",9)
        for id in extraNames {let snapshot=try XCTUnwrap(app.store.recordedMeetingDetails(for:source).first {$0.id==id});_=try app.store.removeRecordedMeetingName(snapshot,for:source)}
        archive.activate();try await settle(archive);archive.names.beginEditing()
        archive.names.draft="Our next planning review"
        let reviewed=try XCTUnwrap(archive.names.editor)
        for dark in [false,true] {
            try await render(RecordingNameEditorView(names:archive.names,archive:archive,review:reviewed),size:.init(width:500,height:430),dark:dark,to:output.appendingPathComponent(dark ? "editor-dark.png":"editor-light.png")) {XCTAssertTrue(archive.names.canSave)}
        }
        _=try app.store.saveRecordedMeetingName("A newer name from another window",for:source,replacing:try XCTUnwrap(reviewed.expected))
        archive.names.saveEditor();try await settle(archive)
        XCTAssertNotNil(archive.names.editorError);XCTAssertEqual(archive.names.draft,"Our next planning review");XCTAssertFalse(archive.names.canSave)
        for dark in [false,true] {
            try await render(RecordingNameEditorView(names:archive.names,archive:archive,review:reviewed),size:.init(width:500,height:540),dark:dark,to:output.appendingPathComponent(dark ? "stale-draft-dark.png":"stale-draft-light.png")) {XCTAssertNotNil(archive.names.editorError)}
        }
        archive.names.reviewLatest();archive.names.editorDismissed();try await settle(archive)
        XCTAssertEqual(archive.names.draft,"Our next planning review");XCTAssertEqual(archive.names.editor?.expected?.name,"A newer name from another window")
        archive.deactivate()
        let gate=ImportWorkerGate();defer {gate.release()}
        let names=RecordingNamesModel(store:app.store,work:app.libraryWork,save:{store,name,source,expected in try gate.pause();return try store.saveRecordedMeetingName(name,for:source,replacing:expected)})
        let savingArchive=RecordedMeetingsModel(store:app.store,work:app.libraryWork,nameDetails:names);savingArchive.allowed={true};extra.append(savingArchive)
        savingArchive.activate();try await settle(savingArchive);names.beginEditing();names.draft="Draft held while saving"
        let savingReview=try XCTUnwrap(names.editor);names.saveEditor();await fulfillment(of:[gate.entered],timeout:5)
        for dark in [false,true] {
            try await render(RecordingNameEditorView(names:names,archive:savingArchive,review:savingReview),size:.init(width:500,height:430),dark:dark,to:output.appendingPathComponent(dark ? "saving-dark.png":"saving-light.png")) {XCTAssertTrue(names.saving);XCTAssertFalse(names.canSave)}
        }
        gate.release();try await settle(savingArchive)
        XCTAssertEqual(try app.store.get(original.id),original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at:output,includingPropertiesForKeys:nil).filter {$0.pathExtension=="png"}.count,14)
    }
}
