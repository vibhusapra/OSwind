#if DEBUG
import AppKit
import SwiftUI
import OSwindCore

/// Renders only the app's own sample workspace for artifact QA; never reads the desktop.
@MainActor enum PreviewExporter {
    static func export(model: AppModel, path: String) async throws {
        var size = NSSize(width:1320,height:850)
        if let index = CommandLine.arguments.firstIndex(of:"--preview-size"), index+1 < CommandLine.arguments.count {
            let dimensions = CommandLine.arguments[index+1].split(separator:"x").compactMap { Double($0) }
            if dimensions.count == 2 { size = NSSize(width:max(1000,min(3000,dimensions[0])),height:max(680,min(2000,dimensions[1]))) }
        }
        let content: AnyView
        if model.section == "ActivityCalendar" {
            let zone=TimeZone(identifier:"America/New_York")!;var calendar=Calendar(identifier:.gregorian);calendar.timeZone=zone
            for day in 1...30 where day%7 != 0 {
                for ordinal in 0..<(day%6+1)*3 {
                    let timestamp=calendar.date(from:DateComponents(year:2024,month:11,day:day,hour:9+ordinal%9,minute:ordinal%3*15))!
                    try model.store.insert(Memory(id:"calendar-render-\(day)-\(ordinal)",timestamp:timestamp,kind:ordinal%4==0 ? .audio:.screen,app:["Safari","Notes","Terminal"][ordinal%3],title:"Owned calendar sample",text:"Invented activity for layout review",favorite:ordinal%5==0,tags:["sample"]))
                }
            }
            for (index,stamp) in ["2024-11-03T01:30:00-04:00","2024-11-03T01:30:00-05:00"].enumerated() {try model.store.insert(Memory(id:"calendar-render-repeated-\(index)",timestamp:try QueryScopeResolver.instant(stamp),app:"Notes",title:"Repeated clock hour · sample",text:"Invented repeated-hour sample"))}
            model.section="Calendar";model.activity.updateTimeZone(zone);model.activity.month="2024-11";model.activity.selectedDay="2024-11-03";model.refresh(forceStatistics:true);model.activity.activate()
            let deadline=ContinuousClock.now.advanced(by:.seconds(15))
            while (model.activity.busy || model.activity.snapshot?.selectedDay != "2024-11-03"),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(20))}
            guard let snapshot=model.activity.snapshot,!model.activity.busy,snapshot.totalSources>0,snapshot.hours.count==25 else {throw OSwindError.unavailable("Calendar sample did not finish with complete counts")}
            content=AnyView(WorkspaceView().environmentObject(model))
        } else if model.section == "VisualSearch" {
            model.section="Memories";model.mode = .visual;model.refresh()
            let deadline=ContinuousClock.now.advanced(by:.seconds(30))
            while model.refreshing,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(20))}
            guard !model.refreshing,model.hits.contains(where:{$0.visual != nil}) else {throw OSwindError.unavailable("Visual sample search did not finish with source-validated matches")}
            content=AnyView(WorkspaceView().environmentObject(model))
        } else if model.section == "VaultLocked" || model.section == "VaultClosing" {
            let session=try await AppSession.previewVault(in:model.store.root,state:model.section == "VaultClosing" ? .closing:.locked)
            size=NSSize(width:1000,height:850);content=AnyView(VaultLockedView(session:session))
        } else if model.section == "VaultSetup" {
            let session=AppSession(selection:.init(url:model.store.root,requiresExisting:true,origin:"preview"),locked:{false})
            size=NSSize(width:600,height:620);content=AnyView(VaultSetupView(session:session))
        } else if model.section == "LibraryWipeResult" || model.section == "LibraryWipePending" {
            let pending=model.section=="LibraryWipePending"
            if pending {let target=model.store.root.appendingPathComponent("owned-keep");try Data([1]).write(to:target);try FileManager.default.createSymbolicLink(at:model.store.root.appendingPathComponent("images/owned-pending"),withDestinationURL:target)}
            model.wipeLocalLibrary();while model.libraryWipe.busy {try await Task.sleep(nanoseconds:10_000_000)}
            size=NSSize(width:760,height:520);content=AnyView(VStack(alignment:.leading,spacing:18) {Text("Your local library.").font(.title2);LibraryWipeStatusView(model:model.libraryWipe,retry:{});Text("Capture, audio, API access and scheduling stay off. Resume when you are ready.").foregroundStyle(.secondary);Spacer()}.padding(28))
        } else if model.section == "LinkedRecapDetail" {
            let source=Memory(id:"recap-preview-source",app:"Notes",title:"Release decision · sample",text:"Maya owns the release. The deadline is Friday.")
            try model.store.insert(source)
            let recap=try model.store.saveRecap(Answer(text:"Maya owns the release, due Friday [1].",sources:[SearchHit(memory:source,score:1,match:"fixture")],provider:"evidence",duration:0),title:"Release recap · sample")
            size=NSSize(width:850,height:760);content=AnyView(MemoryDetail(memory:recap,query:"").environmentObject(model))
        } else if model.section == "CleanupResult" {
            try model.store.insert(Memory(id:"synthetic-retention-preview",timestamp:Date(timeIntervalSince1970:100),text:"Owned old source for cleanup rendering"))
            model.maintain()
            while model.maintenanceBusy {try await Task.sleep(nanoseconds:10_000_000)}
            size=NSSize(width:760,height:720);content=AnyView(SettingsView(initialTab:"Data").environmentObject(model))
        } else if model.section == "DeletionResult",let candidate=model.hits.first?.memory {
            model.delete(candidate)
            while model.deletingID != nil {try await Task.sleep(nanoseconds:10_000_000)}
            model.section="Memories";content=AnyView(WorkspaceView().environmentObject(model))
        } else if model.section == "HistoryErasure" {
            size=NSSize(width:720,height:760);content=AnyView(HistoryErasureView().environmentObject(model))
        } else if model.section == "RoutineEditor" {
            var sample=RoutineDefinition();sample.ai=model.settings.ai
            size=NSSize(width:760,height:850);content=AnyView(RoutineEditor(value:sample,revision:nil,model:model.routines).environmentObject(model))
        } else if model.section == "Routines" {
            if model.routines.items.isEmpty {
                var sample=RoutineDefinition();sample.title="Evening reflection · sample";sample.window = .last24Hours
                _ = model.routines.save(sample,revision:nil)
                _ = try await RoutineRunner(store:model.store,embedder:model.embedder).runNow(sample.id,settings:model.settings)
                model.routines.reload()
            }
            content=AnyView(WorkspaceView().environmentObject(model))
        } else if model.section == "NativeModelDownloads" || model.section == "NativeModelDownloadBusy" {
            if model.section == "NativeModelDownloadBusy" {model.nativeModels.start(.parakeet){_ in}}
            size=NSSize(width:760,height:650)
            content=AnyView(VStack(alignment:.leading,spacing:24) {
                Text("Set up local speech.").font(.title2.weight(.medium))
                Text("Download the models you want to use. Current audio work and model choices stay under your control.").foregroundStyle(.secondary)
                NativeModelDownloadView(setup:model.nativeModels,kind:.parakeet)
                Divider()
                NativeModelDownloadView(setup:model.nativeModels,kind:.speakers)
            }.padding(28).environmentObject(model))
        } else if model.section == "SettingsSpeakerAudio" {
            model.settings.speech.engine = .parakeet; model.settings.diarization.enabled=true
            model.settings.diarization.modelDirectory="/path/to/local/community1-model"
            size = NSSize(width:760,height:900); content = AnyView(SettingsView(initialTab:"Audio").environmentObject(model))
        } else if model.section == "SettingsNativeAudio" {
            model.settings.speech.engine = .parakeet
            size = NSSize(width:760,height:800); content = AnyView(SettingsView(initialTab:"Audio").environmentObject(model))
        } else if model.section == "SettingsAudio" {
            size = NSSize(width:760,height:720); content = AnyView(SettingsView(initialTab:"Audio").environmentObject(model))
        } else if model.section == "SnapshotRegions" || model.section == "SnapshotDisplayRegions" {
            let displayMode=model.section=="SnapshotDisplayRegions"
            let first="11111111-1111-4111-8111-111111111111",second="22222222-2222-4222-8222-222222222222"
            model.settings.snapshotRegions.focusedWindowCrop=SnapshotRegion(x:0.1,y:0.15,width:0.7,height:0.65)
            if displayMode {model.settings.snapshotRegions.selectedDisplays=[first];model.settings.snapshotRegions.displayCrops[first]=SnapshotRegion(x:0.1,y:0.15,width:0.7,height:0.65)}
            size=NSSize(width:760,height:displayMode ? 640:470)
            content=AnyView(VStack(alignment:.leading,spacing:20) {
                Text(displayMode ? "Choose your displays.":"Remember just this region.").font(.title2.weight(.medium))
                SnapshotRegionsView(configuration:Binding(get:{model.settings.snapshotRegions},set:{model.settings.snapshotRegions=$0}),displayMode:displayMode,replay:true,displays:[.init(id:first,name:"Built-in display · sample",size:CGSize(width:1512,height:982)),.init(id:second,name:"Studio display · sample",size:CGSize(width:2560,height:1440))])
                Spacer(minLength:0)
            }.padding(28))
        } else if model.section == "SettingsCapture" || model.section == "SettingsPrivacy" {
            size=NSSize(width:760,height:720);content=AnyView(SettingsView(initialTab:model.section == "SettingsCapture" ? "Capture":"Privacy").environmentObject(model))
        } else if model.section == "SettingsData" {
            size = NSSize(width:760,height:720); content = AnyView(SettingsView(initialTab:"Data").environmentObject(model))
        } else if model.section == "LibraryRecovery" {
            size = NSSize(width:1000,height:760); content = AnyView(LibraryRecoveryView(session:AppSession(selection:LibraryLocationSelection(url:model.store.root.appendingPathComponent("disconnected-drive"),requiresExisting:true,origin:"preview"))))
        } else if ["SettingsVisualMemory","VisualPreparationBusy","VisualPreparationError"].contains(model.section) {
            if model.section != "SettingsVisualMemory" {
                model.visualModelSetup.start {_ in}
                try await Task.sleep(for:.milliseconds(150))
            }
            size=NSSize(width:800,height:1040)
            content=AnyView(Form {VisualModelSettingsView()}.formStyle(.grouped).padding(12).environmentObject(model))
        } else if model.section == "SettingsModels" {
            size = NSSize(width:760,height:720); content = AnyView(SettingsView(initialTab:"Models").environmentObject(model))
        } else if model.section == "MemoryDetail", let candidate = model.hits.first?.memory,let memory=try? model.store.hydrate(candidate) {
            size = NSSize(width:850,height:760); content = AnyView(MemoryDetail(memory:memory,query:model.query).environmentObject(model))
        } else { content = AnyView(WorkspaceView().environmentObject(model)) }
        let view = NSHostingView(rootView:content.frame(width:size.width,height:size.height).background(Color(nsColor:.windowBackgroundColor)).preferredColorScheme(NSApp.appearance?.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? .dark : .light))
        let window = NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = view
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        // Allow the app's own async excerpt views to finish before rasterizing.
        try await Task.sleep(nanoseconds:350_000_000)
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw NSError(domain:"OSwindPreview",code:1) }
        view.cacheDisplay(in:view.bounds,to:rep)
        guard let png = rep.representation(using:.png,properties:[:]) else { throw NSError(domain:"OSwindPreview",code:2) }
        try png.write(to:URL(fileURLWithPath:path)); window.close()
    }
}
#endif
