#if DEBUG
import AppKit
import SwiftUI

/// Renders only the app's own sample workspace for artifact QA; never reads the desktop.
@MainActor enum PreviewExporter {
    static func export(model: AppModel, path: String) throws {
        let size = NSSize(width:1320,height:850)
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
