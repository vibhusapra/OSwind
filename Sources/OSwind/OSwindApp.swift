import SwiftUI
import AppKit
import Carbon
import OSwindCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var hotKey: EventHotKeyRef?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let id = EventHotKeyID(signature:0x4f53574e,id:1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey),id,GetApplicationEventTarget(),0,&hotKey)
        var spec = EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _,_,_ in DispatchQueue.main.async { NSApp.activate(ignoringOtherApps:true); NSApp.windows.first(where:{$0.canBecomeMain})?.makeKeyAndOrderFront(nil) }; return noErr },1,&spec,nil,nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct OSwindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = AppModel()
    var body: some Scene {
        WindowGroup("OSwind",id:"main") { WorkspaceView().environmentObject(model).frame(minWidth:1000,minHeight:680).tint(.mint) }
            .defaultSize(width:1320,height:850)
            .commands { CommandGroup(after:.newItem) { Button("Search memories") { NSApp.activate(ignoringOtherApps:true) }.keyboardShortcut("k"); Button(model.capture.running ? "Pause capture" : "Resume capture") { model.toggleCapture() }.keyboardShortcut("p",modifiers:[.command,.shift]); Button("Settings…") { model.showSettings = true }.keyboardShortcut(",") } }
        MenuBarExtra { VStack(alignment:.leading,spacing:12) {
            Text("OSwind").font(.headline); Text(model.capture.status).font(.caption)
            Button("Open OSwind  ⇧⌘Space") { NSApp.activate(ignoringOtherApps:true); NSApp.windows.first(where:{$0.canBecomeMain})?.makeKeyAndOrderFront(nil) }
            Button(model.capture.running ? "Pause capture" : "Resume capture") { model.toggleCapture() }
            Menu("Pause for…") { ForEach([5,15,30,60],id:\.self) { minutes in Button("\(minutes) minutes") { model.pauseFor(minutes:minutes) } } }
            Button("Capture now") { Task { await model.capture.captureOnce(manual:true) } }
            Button(model.audio.running ? "Stop audio" : "Start audio") { if model.audio.running { model.audio.finish() } else { Task { await model.audio.start() } } }
            Divider(); Text("\(model.stats.count) memories · stored on this Mac").font(.caption)
            Button("Quit OSwind") { model.capture.pause(); model.audio.stop(); NSApp.terminate(nil) }
        }.padding().frame(width:280) } label: { Image(systemName:model.capture.running ? "wind.circle.fill" : "wind") }
        .menuBarExtraStyle(.window)
    }
}
