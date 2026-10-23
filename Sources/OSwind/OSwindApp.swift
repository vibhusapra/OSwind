import SwiftUI
import AppKit
import Carbon
import OSwindCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var hotKey: EventHotKeyRef?
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--demo"), let index = CommandLine.arguments.firstIndex(of:"--render-preview"), index+1 < CommandLine.arguments.count {
            if let appearanceIndex = CommandLine.arguments.firstIndex(of:"--preview-appearance"), appearanceIndex+1 < CommandLine.arguments.count {
                NSApp.appearance = NSAppearance(named:CommandLine.arguments[appearanceIndex+1] == "light" ? .aqua : .darkAqua)
            }
            let preview = AppModel(), path = CommandLine.arguments[index+1]
            if let queryIndex = CommandLine.arguments.firstIndex(of:"--preview-query"), queryIndex+1 < CommandLine.arguments.count { preview.query = CommandLine.arguments[queryIndex+1] }
            if let sectionIndex = CommandLine.arguments.firstIndex(of:"--preview-section"), sectionIndex+1 < CommandLine.arguments.count { preview.section = CommandLine.arguments[sectionIndex+1]; if preview.section == "SettingsModels" { preview.settings.search.provider = .ollama }; preview.refresh() }
            if CommandLine.arguments.contains("--preview-chat"), let chat = preview.chats.first { preview.selectChat(chat.id) }
            preview.refresh()
            DispatchQueue.main.asyncAfter(deadline:.now()+1) {
                Task { @MainActor in
                    do { try await PreviewExporter.export(model:preview,path:path) } catch { FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8)) }
                    NSApp.terminate(nil)
                }
            }
        }
        #endif
        NSApp.setActivationPolicy(.regular)
        let id = EventHotKeyID(signature:0x4f53574e,id:1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey),id,GetApplicationEventTarget(),0,&hotKey)
        var spec = EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _,_,_ in DispatchQueue.main.async {
            NotificationCenter.default.post(name:.oswindOpenMain,object:nil)
            NotificationCenter.default.post(name:.oswindFocusSearch,object:nil)
        }; return noErr },1,&spec,nil,nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool { NotificationCenter.default.post(name:.oswindOpenMain,object:nil); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct OSwindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = AppModel()
    var body: some Scene {
        Window("OSwind",id:"main") { WorkspaceView().environmentObject(model).frame(minWidth:1000,minHeight:680).tint(OSwindTheme.accent) }
            .defaultSize(width:1320,height:850)
            .commands { CommandGroup(after:.newItem) { Button("Search memories") { NotificationCenter.default.post(name:.oswindOpenMain,object:nil); NotificationCenter.default.post(name:.oswindFocusSearch,object:nil) }.keyboardShortcut("k"); Button(model.isCapturing ? "Pause capture" : "Resume capture") { model.toggleCapture() }.keyboardShortcut("p",modifiers:[.command,.shift]); Button("Settings…") { model.showSettings = true }.keyboardShortcut(",") } }
        MenuBarExtra { VStack(alignment:.leading,spacing:12) {
            Text("OSwind").font(.headline); Text(model.capture.status).font(.caption)
            Button("Open OSwind  ⇧⌘Space") { NotificationCenter.default.post(name:.oswindOpenMain,object:nil) }
            Button(model.isCapturing ? "Pause capture" : "Resume capture") { model.toggleCapture() }
            Menu("Pause for…") { ForEach([5,15,30,60],id:\.self) { minutes in Button("\(minutes) minutes") { model.pauseFor(minutes:minutes) } } }
            Button("Capture now") { Task { await model.capture.captureOnce(manual:true) } }
            Button(model.audio.running ? "Stop audio" : "Start audio") { if model.audio.running { model.audio.finish() } else { Task { await model.audio.start() } } }
            Divider(); Text("\(model.stats.count) memories · stored on this Mac").font(.caption)
            Button("Quit OSwind") { model.capture.pause(); model.audio.stop(); NSApp.terminate(nil) }
        }.padding().frame(width:280) } label: { MenuBarIcon().environmentObject(model) }
        .menuBarExtraStyle(.window)
    }
}

extension Notification.Name {
    static let oswindOpenMain = Notification.Name("OSwindOpenMain")
    static let oswindFocusSearch = Notification.Name("OSwindFocusSearch")
}
struct MenuBarIcon: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Image(systemName:model.capture.running ? "wind.circle.fill" : model.audio.running ? "waveform.circle.fill" : "wind")
            .onReceive(NotificationCenter.default.publisher(for:.oswindOpenMain)) { _ in
                openWindow(id:"main"); NSApp.activate(ignoringOtherApps:true)
            }
            .onReceive(NotificationCenter.default.publisher(for:.oswindFocusSearch)) { _ in model.focusSearch() }
    }
}
