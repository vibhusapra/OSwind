import XCTest
import AppKit
import SwiftUI
@testable import OSwindCore
@testable import OSwind

@MainActor final class RecordingCalendarRenderTests:XCTestCase {
    func testOwnedPickerPopulatedEmptyDeniedChangedAndSavingInBothAppearances()async throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_RECORDING_CALENDAR_UI_QA_DIR"] else {throw XCTSkip("Explicit owned calendar component output required")}
        let output=URL(fileURLWithPath:path);try Paths.ensure(output)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-calendar-render-"+UUID().uuidString),store=try MemoryStore(root:root),work=LibraryWorkRegistry(),provider=RecordingCalendarModelTests.Provider()
        var audio=Memory(id:"owned-audio",timestamp:Date(timeIntervalSince1970:1_793_700_000),kind:.audio,app:"Owned",title:"Original capture",text:"Authored fixture; no microphone");audio.audioSessionID="owned-session";try store.insert(audio)
        let source=try XCTUnwrap(store.recordedMeetingPage().sources.first),saved=try store.saveRecordedMeetingName("Planning review",for:source)
        var settings=AppSettings();settings.meetings.enabled=true;settings.meetings.calendarIDs=["owned-calendar"];settings.meetings.boundLibrary=try store.authorizeMeetingLibrary();try settings.save(root:root)
        let model=RecordingCalendarModel(store:store,work:work,provider:provider.source());model.allowed={true};model.select(source,expected:saved)
        func settle()async throws {let end=ContinuousClock.now.advanced(by:.seconds(10));while work.busy,ContinuousClock.now<end {try await Task.sleep(for:.milliseconds(5))};XCTAssertFalse(work.busy)}
        func render(_ state:String)async throws {
            for dark in [false,true] {
                let view=NSHostingView(rootView:RecordingCalendarPickerView(calendar:model).background(Color(nsColor:.windowBackgroundColor)).preferredColorScheme(dark ? .dark:.light))
                let window=NSWindow(contentRect:.init(x:0,y:0,width:570,height:620),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=view
                defer {window.contentView=nil;window.close()};view.setFrameSize(.init(width:570,height:620));view.layoutSubtreeIfNeeded();window.displayIfNeeded();try await Task.sleep(for:.milliseconds(180));view.layoutSubtreeIfNeeded()
                let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap);try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent(state+(dark ? "-dark.png":"-light.png")),options:.withoutOverwriting)
            }
        }
        provider.calendars=[try .init(id:"owned-calendar",title:"Studio calendar",account:"Authored account")]
        provider.events=try (0..<3).map {try .init(calendarID:"owned-calendar",seriesID:"owned-\($0)",start:audio.timestamp.addingTimeInterval(Double($0)*3600),end:audio.timestamp.addingTimeInterval(Double($0)*3600+1800),title:$0==0 ? "Planning review and launch checklist with studio follow-up":"Authored occurrence \($0+1)")}
        model.open();try await settle();model.selectedID=model.events.first?.id;try await render("populated")
        provider.state {$0.clock+=1};model.checkForChanges();try await render("changed")
        provider.state {$0.events=[]};model.load();try await settle();try await render("empty")
        provider.state {$0.permission = .denied};model.load();try await settle();try await render("denied")
        provider.state {$0.permission = .full;$0.events=[try! .init(calendarID:"owned-calendar",seriesID:"saving",start:audio.timestamp,end:audio.timestamp.addingTimeInterval(1800),title:"Authored saving occurrence")]};model.load();try await settle();model.selectedID=model.events.first?.id
        let gate=MeetingsModelTests.Gate();provider.state {$0.nextGate=gate};model.save();await fulfillment(of:[gate.entered],timeout:5);try await render("saving");await gate.open();try await settle()
        _=try store.removeRecordedMeetingName(try XCTUnwrap(store.recordedMeetingDetails(for:source).first),for:source)
        model.select(source,expected:nil);model.open();try await settle();model.selectedID=model.events.first?.id;model.useEventTitle();try await render("unnamed")
        model.clear();await work.cancelAndWait();try store.close();try FileManager.default.removeItem(at:root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at:output,includingPropertiesForKeys:nil).filter {$0.pathExtension=="png"}.count,12)
    }
}
