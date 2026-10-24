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
        if model.section == "CleanupResult" {
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
        } else if model.section == "SettingsData" {
            size = NSSize(width:760,height:720); content = AnyView(SettingsView(initialTab:"Data").environmentObject(model))
        } else if model.section == "LibraryRecovery" {
            size = NSSize(width:1000,height:760); content = AnyView(LibraryRecoveryView(session:AppSession(selection:LibraryLocationSelection(url:model.store.root.appendingPathComponent("disconnected-drive"),requiresExisting:true,origin:"preview"))))
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
