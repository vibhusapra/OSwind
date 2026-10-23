#if DEBUG
import AppKit
import SwiftUI

/// Renders only the app's own sample workspace for artifact QA; never reads the desktop.
@MainActor enum PreviewExporter {
    static func export(model: AppModel, path: String) throws {
        var size = NSSize(width:1320,height:850)
        if let index = CommandLine.arguments.firstIndex(of:"--preview-size"), index+1 < CommandLine.arguments.count {
            let dimensions = CommandLine.arguments[index+1].split(separator:"x").compactMap { Double($0) }
            if dimensions.count == 2 { size = NSSize(width:max(1000,min(3000,dimensions[0])),height:max(680,min(2000,dimensions[1]))) }
        }
        let view = NSHostingView(rootView:WorkspaceView().environmentObject(model).frame(width:size.width,height:size.height))
        let window = NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = view
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw NSError(domain:"OSwindPreview",code:1) }
        view.cacheDisplay(in:view.bounds,to:rep)
        guard let png = rep.representation(using:.png,properties:[:]) else { throw NSError(domain:"OSwindPreview",code:2) }
        try png.write(to:URL(fileURLWithPath:path)); window.close()
    }
}
#endif
