import SwiftUI
import AppKit
import Carbon
import OSwindCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationReady=false
    private var terminationInProgress=false
    var finishTermination:(NSApplication)->Void={application in application.terminate(nil)}
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--demo"), let index = CommandLine.arguments.firstIndex(of:"--render-preview"), index+1 < CommandLine.arguments.count {
            if let appearanceIndex = CommandLine.arguments.firstIndex(of:"--preview-appearance"), appearanceIndex+1 < CommandLine.arguments.count {
                NSApp.appearance = NSAppearance(named:CommandLine.arguments[appearanceIndex+1] == "light" ? .aqua : .darkAqua)
            }
            let preview: AppModel
            do {
                if let index=CommandLine.arguments.firstIndex(of:"--preview-section"),index+1<CommandLine.arguments.count,["SettingsDataQuiet","RoutinesQuiet","SettingsConnectQuiet","OnboardingPreview"].contains(CommandLine.arguments[index+1]) {
                    preview=try AppModel(startServices:false)
                } else if let index=CommandLine.arguments.firstIndex(of:"--preview-section"),index+1<CommandLine.arguments.count,CommandLine.arguments[index+1]=="NativeModelDownloadBusy" {
                    let setup=NativeModelSetupModel(installer:{kind,_,_,progress in
                        let catalog=try kind.catalog()
                        progress(NativeModelProgress(phase:"Downloading",completedBytes:176_000_000,totalBytes:catalog.bytes,completedFiles:7,totalFiles:catalog.files.count,file:"Encoder.mlmodelc/weights/weight.bin"))
                        try await Task.sleep(nanoseconds:120_000_000_000);throw CancellationError()
                    })
                    preview=try AppModel(startServices:false,nativeModelSetup:setup)
                } else if let section=CommandLine.arguments.firstIndex(of:"--preview-section"),section+1<CommandLine.arguments.count,["VisualPreparationBusy","VisualPreparationError"].contains(CommandLine.arguments[section+1]) {
                    let failed=CommandLine.arguments[section+1]=="VisualPreparationError"
                    let setup=VisualModelSetupModel(installer:{progress in
                        if failed {throw OSwindError.network("The public model download was interrupted. Check the connection and retry.")}
                        progress(.init(phase:"Downloading public model weights",completedBytes:735_000_000,totalBytes:1_539_456_768,completedFiles:5,totalFiles:8,file:nil))
                        try await Task.sleep(for:.seconds(120));throw CancellationError()
                    })
                    preview=try AppModel(startServices:false,visualSetup:setup)
                } else {preview=try AppModel()}
            } catch { FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8)); NSApp.terminate(nil); return }
            let path = CommandLine.arguments[index+1]
            if let queryIndex = CommandLine.arguments.firstIndex(of:"--preview-query"), queryIndex+1 < CommandLine.arguments.count { preview.query = CommandLine.arguments[queryIndex+1] }
            if let questionIndex = CommandLine.arguments.firstIndex(of:"--preview-question"), questionIndex+1 < CommandLine.arguments.count { preview.question = CommandLine.arguments[questionIndex+1] }
            if CommandLine.arguments.contains("--preview-literal") { preview.interpretQuery = false }
            if let sectionIndex = CommandLine.arguments.firstIndex(of:"--preview-section"), sectionIndex+1 < CommandLine.arguments.count { preview.section = CommandLine.arguments[sectionIndex+1]; if preview.section == "SettingsModels" { preview.settings.search.provider = .ollama }; preview.refresh() }
            if CommandLine.arguments.contains("--preview-chat"), let chat = preview.chats.first { preview.selectChat(chat.id) }
            preview.refresh()
            DispatchQueue.main.asyncAfter(deadline:.now()+1) {
                Task { @MainActor in
                    do { try await PreviewExporter.export(model:preview,path:path) } catch { FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8)) }
                    NSApp.terminate(nil)
                }
            }
            // Component-only renders never register a desktop hotkey or its
            // destination-reading callback while their sample view is open.
            return
        }
        #endif
        NSApp.setActivationPolicy(.regular)
        GlobalShortcutModel.shared.configure {
            // Capture explicit external focus before OSwind activates. Opening
            // the app normally never inspects a different application's field.
            if let session=AppSession.current,!session.busy,let model=session.model,!model.store.isClosed,!model.libraryWipe.busy,!model.libraryWipe.pendingCleanup {model.drafting.chooseDestination(privacy:model.settings.privacy)}
            NotificationCenter.default.post(name:.oswindOpenMain,object:nil)
            if AppSession.current?.model?.drafting.showing != true {NotificationCenter.default.post(name:.oswindFocusSearch,object:nil)}
        }
    }
    func applicationWillTerminate(_ notification:Notification) {GlobalShortcutModel.shared.stop()}
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool { NotificationCenter.default.post(name:.oswindOpenMain,object:nil); return true }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        if terminationReady {return .terminateNow}
        guard let session=AppSession.current,session.vaultPackage != nil || session.busy || session.model?.hasPendingJSONImport == true else {AppSession.current?.model?.prepareForLibrarySwitch();return .terminateNow}
        guard !terminationInProgress else {return .terminateCancel}
        terminationInProgress=true
        // terminateLater enters AppKit's nested modal run loop. If terminate()
        // was called by a MainActor task, that task can starve the cleanup task.
        // Return to the ordinary loop, await the verified lock, then quit again.
        Task {@MainActor in
            let locked=await session.lockForTermination();self.terminationInProgress=false
            if locked {self.terminationReady=true;DispatchQueue.main.async {self.finishTermination(sender)}}
        }
        return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct OSwindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var session = AppSession()
    var body: some Scene {
        Window("OSwind",id:"main") {
            Group {
                if let model=session.model {VStack(spacing:0) {
                    if !session.message.isEmpty {HStack {Text(session.message).font(.callout);if session.snapshotNeedsReview,let snapshot=session.createdVault {Button("Open snapshot…") {session.open(snapshot)}};Spacer();Button {session.message=""} label:{Image(systemName:"xmark")}.buttonStyle(.plain)}.padding(12).background(OSwindTheme.accent.opacity(0.1))}
                    WorkspaceView().environmentObject(model).disabled(session.busy)
                }} else if session.vaultPackage != nil {VaultLockedView(session:session)}
                else {LibraryRecoveryView(session:session)}
            }.frame(minWidth:1000,minHeight:680).tint(OSwindTheme.accent)
                .onReceive(NotificationCenter.default.publisher(for:.oswindOpenLibrary)) { event in if let url = event.object as? URL { session.open(url) } }
                .onReceive(NotificationCenter.default.publisher(for:.oswindChooseLibrary)) {_ in session.choose()}
                .onReceive(NotificationCenter.default.publisher(for:.oswindCreateVault)) {_ in session.failure=nil;session.message="";session.showVaultSetup=true}
                .onReceive(NotificationCenter.default.publisher(for:.oswindLockVault)) {_ in session.requestLock()}
                .onReceive(NotificationCenter.default.publisher(for:.oswindForgetVaultSecret)) {_ in session.forgetKeychain()}
                .sheet(isPresented:$session.showVaultSetup) {VaultSetupView(session:session)}
                .onOpenURL { url in
                    if url.pathExtension.lowercased()=="oswindvault" || (try? LibraryVault.package(containing:url)) != nil {session.open(url);return}
                    if let model = session.model { model.settingsTab = "Data"; model.showSettings = true; model.libraryTransfer.inspect(url) }
                    else { session.recoveryTransfer.inspect(url) }
                }
                .alert("Library could not be opened",isPresented:Binding(get:{session.model != nil && session.failure != nil},set:{if !$0 {session.failure=nil}})) { Button("OK") {session.failure=nil} } message: { Text(session.failure ?? "") }
        }.defaultSize(width:1320,height:850)
            .commands { CommandGroup(after:.newItem) {
                Button("Search memories") { NotificationCenter.default.post(name:.oswindOpenMain,object:nil); NotificationCenter.default.post(name:.oswindFocusSearch,object:nil) }.keyboardShortcut("k")
                Button(session.model?.isCapturing == true ? "Pause capture" : "Resume capture") { session.model?.toggleCapture() }.keyboardShortcut("p",modifiers:[.command,.shift]).disabled(session.model == nil)
                Button("Settings…") { if let model = session.model {model.showSettings=true} else {NotificationCenter.default.post(name:.oswindOpenMain,object:nil)} }.keyboardShortcut(",")
            } }
        MenuBarExtra {
            if let model = session.model { LibraryMenuContent().environmentObject(model) }
            else { VStack(alignment:.leading,spacing:12) { Text(session.vaultPackage == nil ? "Library unavailable":"Encrypted library").font(.headline); Button("Open OSwind") {NotificationCenter.default.post(name:.oswindOpenMain,object:nil)}; Button("Quit OSwind") {NSApp.terminate(nil)} }.padding() }
        } label: {
            if let model = session.model { MenuBarIcon().environmentObject(model) }
            else { RecoveryMenuIcon() }
        }.menuBarExtraStyle(.window)
    }
}
struct LibraryMenuContent: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("OSwind").font(.headline); Text(model.capture.status).font(.caption)
            Button("Open OSwind  ⇧⌘Space") { NotificationCenter.default.post(name:.oswindOpenMain,object:nil) }
            Button(model.isCapturing ? "Pause capture" : "Resume capture") { model.toggleCapture() }
            Menu("Pause for…") { ForEach([5,15,30,60],id:\.self) { minutes in Button("\(minutes) minutes") { model.pauseFor(minutes:minutes) } } }
            Button("Capture now") { Task { await model.captureNow() } }
            Button(model.audio.running ? "Stop audio" : "Start audio") { Task {await model.toggleAudio()} }
            Divider(); Text("\(model.stats.count) memories · stored on this Mac").font(.caption)
            if (try? LibraryVault.package(containing:model.store.root)) != nil {Button("Lock library") {NotificationCenter.default.post(name:.oswindLockVault,object:nil)}}
            Button("Quit OSwind") {NSApp.terminate(nil)}
        }.padding().frame(width:280)
    }
}
struct RecoveryMenuIcon: View {
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Image(systemName:"externaldrive.badge.exclamationmark").onReceive(NotificationCenter.default.publisher(for:.oswindOpenMain)) { _ in openWindow(id:"main"); NSApp.activate(ignoringOtherApps:true) }
    }
}

extension Notification.Name {
    static let oswindOpenMain = Notification.Name("OSwindOpenMain")
    static let oswindFocusSearch = Notification.Name("OSwindFocusSearch")
    static let oswindOpenLibrary = Notification.Name("OSwindOpenLibrary")
    static let oswindCreateVault=Notification.Name("OSwindCreateVault")
    static let oswindLockVault=Notification.Name("OSwindLockVault")
    static let oswindForgetVaultSecret=Notification.Name("OSwindForgetVaultSecret")
    static let oswindChooseLibrary = Notification.Name("OSwindChooseLibrary")
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
