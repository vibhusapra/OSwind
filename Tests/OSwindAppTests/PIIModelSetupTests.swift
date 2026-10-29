import XCTest
import SwiftUI
import AppKit
import OSwindCore
@testable import OSwind

private actor PIISetupGate {
    nonisolated let entered=XCTestExpectation(description:"owned PII setup entered")
    var continuation:CheckedContinuation<Void,Never>?
    func wait() async {await withCheckedContinuation {continuation=$0;entered.fulfill()}}
    func open() {continuation?.resume();continuation=nil}
}
@MainActor final class PIIModelSetupTests:XCTestCase {
    func installation()->PIIModelInstallation {.init(directory:URL(fileURLWithPath:"/owned/model"),buildID:"fixture",bytes:393488824,downloadBytes:201963274,reused:false)}
    func wait(_ model:PIIModelSetupModel) async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(5))
        while model.busy,ContinuousClock.now<end {try await Task.sleep(for:.milliseconds(5))};XCTAssertFalse(model.busy)
    }
    func testSuccessReportsProgressAndBusyGuardPublishesOnlyOneInstallation() async throws {
        let gate=PIISetupGate(),result=installation()
        let model=PIIModelSetupModel(installer:{progress in progress(.init(phase:"Owned setup",completedBytes:5,totalBytes:10,completedFiles:0,totalFiles:1));await gate.wait();return result})
        let progress=XCTestExpectation(description:"PII progress published")
        let observer=model.$progress.compactMap {$0}.first().sink {_ in progress.fulfill()};defer {observer.cancel()}
        var count=0;model.start {_ in count+=1};model.start {_ in count+=100}
        await fulfillment(of:[gate.entered,progress],timeout:5);XCTAssertTrue(model.busy);XCTAssertNil(model.installation)
        await gate.open();try await wait(model);XCTAssertEqual(count,1);XCTAssertEqual(model.installation,result);XCTAssertNil(model.error)
    }
    func testLibrarySwitchCancelsAndJoinsLateSuccessWithoutPublishingIt() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-pii-ui-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:root)}
        let gate=PIISetupGate(),result=installation(),setup=PIIModelSetupModel(installer:{_ in await gate.wait();return result})
        let app=try AppModel(root:root,startServices:false,piiSetup:setup)
        var count=0;setup.start {_ in count+=1};await fulfillment(of:[gate.entered],timeout:5)
        app.prepareForLibrarySwitch();XCTAssertTrue(setup.cancelling);XCTAssertTrue(setup.busy)
        await gate.open();try await wait(setup);XCTAssertNil(setup.installation);XCTAssertEqual(count,0)
        XCTAssertTrue(setup.status.contains("Cancelled"))
    }
    func testFailureAndCancellationLeaveSetupRetryable() async throws {
        let model=PIIModelSetupModel(installer:{_ in throw OSwindError.network("owned setup failure")})
        for _ in 0..<2 {model.start {_ in XCTFail("Failure published an installation")};try await wait(model);XCTAssertNotNil(model.error);XCTAssertNil(model.installation);XCTAssertFalse(model.cancelling)}
    }
    func testOwnedSettingsStatesRenderWithoutNetworkOrLibrary() async throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_PII_SETUP_RENDER_DIR"] else {throw XCTSkip("Explicit owned render directory absent")}
        let directory=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let ready=installation()
        for dark in [false,true] {
            for state in ["idle","ready","failure","busy","stopping"] {
                let gate=PIISetupGate()
                let model=PIIModelSetupModel(installer:{_ in
                    if state=="busy" || state=="stopping" {await gate.wait()}
                    if state=="failure" {throw OSwindError.network("Owned download interrupted. Check your connection and retry.")}
                    return ready
                })
                if state != "idle" {model.start {_ in};if state=="busy" || state=="stopping" {await fulfillment(of:[gate.entered],timeout:5);if state=="stopping" {model.cancel()}} else {try await wait(model)}}
                // Form uses native AppKit content; ImageRenderer can return a
                // blank background. Rasterize an owned offscreen hosting view.
                _ = NSApplication.shared
                let view=Form {PIIModelSettingsView(setup:model)}.formStyle(.grouped).frame(width:710,height:400).preferredColorScheme(dark ? .dark:.light)
                let host=NSHostingView(rootView:view),window=NSWindow(contentRect:NSRect(x:0,y:0,width:710,height:400),styleMask:[.titled],backing:.buffered,defer:false)
                window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:dark ? .darkAqua:.aqua);window.contentView=host
                host.layoutSubtreeIfNeeded();window.displayIfNeeded();try await Task.sleep(for:.milliseconds(150));host.layoutSubtreeIfNeeded();window.displayIfNeeded()
                guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw OSwindError.unavailable("Owned PII settings bitmap unavailable")}
                host.cacheDisplay(in:host.bounds,to:bitmap)
                var colors=Set<UInt32>()
                for y in stride(from:20,to:bitmap.pixelsHigh-20,by:7) {for x in stride(from:20,to:bitmap.pixelsWide-20,by:7) {
                    if let color=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) {
                        let r=UInt32(max(0,min(255,color.redComponent*255))),g=UInt32(max(0,min(255,color.greenComponent*255))),b=UInt32(max(0,min(255,color.blueComponent*255)))
                        colors.insert((r<<16)|(g<<8)|b)
                    }
                }}
                XCTAssertGreaterThan(colors.count,8,"Native settings render is blank or missing its content")
                guard let png=bitmap.representation(using:.png,properties:[:]) else {throw OSwindError.unavailable("Owned PII settings PNG unavailable")}
                try png.write(to:directory.appendingPathComponent("\(state)-\(dark ? "dark":"light").png"))
                window.close()
                if state=="busy" || state=="stopping" {model.cancel();await gate.open();try await wait(model)}
            }
        }
    }
}
