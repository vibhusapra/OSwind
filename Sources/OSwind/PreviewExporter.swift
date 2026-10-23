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
        if model.section == "SettingsNativeAudio" {
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
        } else if model.section == "MemoryDetail", let memory = model.hits.first?.memory {
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
