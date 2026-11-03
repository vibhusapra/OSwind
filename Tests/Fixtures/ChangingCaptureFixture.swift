import AppKit
import Foundation
import ScreenCaptureKit
let app=NSApplication.shared;app.setActivationPolicy(.regular)
guard CommandLine.arguments.count==2 else {fatalError("Owned readiness path required")}
let ready=URL(fileURLWithPath:CommandLine.arguments[1]),window=NSWindow(contentRect:NSRect(x:200,y:180,width:960,height:600),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
let view=NSView(frame:NSRect(x:0,y:0,width:960,height:600));view.wantsLayer=true
let label=NSTextField(wrappingLabelWithString:"");label.frame=NSRect(x:55,y:65,width:850,height:470);label.font = .systemFont(ofSize:36);view.addSubview(label);window.contentView=view
var sample=0
func update() {
    sample+=1;let dark=sample%2==0
    view.layer?.backgroundColor=(dark ? NSColor(calibratedWhite:0.18,alpha:1):NSColor(calibratedWhite:0.93,alpha:1)).cgColor;label.textColor=dark ? .white:.black
    window.title="OSwind owned changing capture fixture";label.stringValue="OSwind generated capture baseline\n\nSample \(sample) · SOAKFRAME\(sample)\n\nMaya owns the Friday checklist.\nOnly this synthetic window is targeted."
    window.displayIfNeeded()

}
let menu=NSMenu(),item=NSMenuItem(),submenu=NSMenu();submenu.addItem(withTitle:"Quit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");item.submenu=submenu;menu.addItem(item);app.mainMenu=menu
update();window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
// Readiness must describe a realized, stable WindowServer source, not merely
// an AppKit object before orderFront/activation has completed.
let readiness=Task { @MainActor in
    var previous:String?,stable=0
    while !Task.isCancelled {
        do {
            let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
            let owned=content.windows.filter {$0.owningApplication?.processID==ProcessInfo.processInfo.processIdentifier && $0.windowID==CGWindowID(window.windowNumber) && $0.windowLayer==0 && $0.title==window.title && $0.frame.width>100 && $0.frame.height>100}
            if window.isVisible,owned.count==1,let source=owned.first {
                let signature="\(source.windowID)|\(source.title ?? "")|\(source.frame)"
                stable=signature==previous ? stable+1:1;previous=signature
                if stable>=3 {
                    let state:[String:Any]=["pid":ProcessInfo.processInfo.processIdentifier,"bundle":Bundle.main.bundleIdentifier ?? "","sample":sample,"wall":Date().timeIntervalSince1970,"executable":Bundle.main.executablePath ?? "","windowID":source.windowID,"stableSCObservations":stable,"title":source.title ?? "","frame":NSStringFromRect(source.frame)]
                    try JSONSerialization.data(withJSONObject:state,options:[.sortedKeys]).write(to:ready,options:.atomic);return
                }
            } else {stable=0;previous=nil}
        } catch {stable=0;previous=nil}
        try? await Task.sleep(for:.milliseconds(200))
    }
}
let timer=Timer.scheduledTimer(withTimeInterval:30,repeats:true){_ in update()};app.run()
