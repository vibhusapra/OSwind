import Foundation
import Combine
import AppKit
import ApplicationServices
import OSwindCore

@MainActor final class ClipboardContextModel:ObservableObject {
    @Published private(set) var running=false
    private(set) var busy=false
    private var statusValue="Clipboard context is off"
    private(set) var status:String {
        get {statusValue}
        set {guard statusValue != newValue else {return};objectWillChange.send();statusValue=newValue}
    }
    @Published private(set) var saved=0
    private(set) var skipped=0
    private(set) var unchanged=0
    var allowed:()->Bool={true}
    var saveSource:((ClipboardTextDraft)async throws->CollectorImportResult)?
    private let store:MemoryStore,reader:ClipboardReader
    private let context:()async->WindowContext?,locked:()->Bool,idle:()->Bool,limited:()->Bool
    private let schedulesTimers:Bool
    private var settings:AppSettings,session=UUID().uuidString.lowercased(),epoch=UUID(),operationID:UUID?
    private var baseline:Int?,lastDigest:Data?,suspended=false
    private var worker:Task<Void,Never>?,timer:Timer?
    private var observers=Set<AnyCancellable>()
    init(store:MemoryStore,settings:AppSettings,reader:ClipboardReader = .native,context:@escaping ()async->WindowContext?={guard AXIsProcessTrusted() else {return nil};return await AccessibilityContext.read()},locked:@escaping ()->Bool={SessionState.locked},idle:@escaping ()->Bool={NativeInputActivity.secondsSinceLastInput()>120},limited:@escaping ()->Bool={ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical},schedulesTimers:Bool=true,workspaceNotifications:NotificationCenter=NSWorkspace.shared.notificationCenter) {
        self.store=store;self.settings=settings;self.reader=reader;self.context=context;self.locked=locked;self.idle=idle;self.limited=limited;self.schedulesTimers=schedulesTimers
        for name in [NSWorkspace.willSleepNotification,NSWorkspace.screensDidSleepNotification,NSWorkspace.sessionDidResignActiveNotification] {
            workspaceNotifications.publisher(for:name).sink {[weak self] _ in Task {@MainActor in self?.suspended=true;self?.invalidate();self?.status="Clipboard paused while sleeping or locked"}}.store(in:&observers)
        }
        for name in [NSWorkspace.didWakeNotification,NSWorkspace.screensDidWakeNotification,NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceNotifications.publisher(for:name).sink {[weak self] _ in Task {@MainActor in self?.suspended=false;self?.invalidate();self?.poll()}}.store(in:&observers)
        }
        workspaceNotifications.publisher(for:NSWorkspace.didActivateApplicationNotification).sink {[weak self] _ in Task {@MainActor in self?.invalidate();self?.poll()}}.store(in:&observers)
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange,ProcessInfo.thermalStateDidChangeNotification] {
            NotificationCenter.default.publisher(for:name).sink {[weak self] _ in Task {@MainActor in self?.schedule()}}.store(in:&observers)
        }
    }
    deinit {timer?.invalidate();worker?.cancel()}
    private var usable:Bool {settings.clipboard.enabled && !store.isClosed && !suspended && !locked() && !idle() && allowed()}
    func apply(_ value:AppSettings) {
        if settings.clipboard != value.clipboard || settings.privacy != value.privacy || settings.piiImports != value.piiImports {invalidate()}
        settings=value
        if !value.clipboard.enabled {stop()}else if running {schedule()}
    }
    func start() {
        guard settings.clipboard.enabled else {status="Enable optional clipboard context in Settings";return}
        guard !store.isClosed,allowed() else {status="This library is unavailable for clipboard context";return}
        if !running {invalidate();session=UUID().uuidString.lowercased();running=true}
        status="Waiting for a new eligible clipboard change";schedule();poll()
    }
    func requestAccess() {
        guard !busy,settings.clipboard.enabled,!store.isClosed,!suspended,!locked(),allowed() else {return}
        invalidate();let generation=epoch,id=UUID();operationID=id;busy=true
        status="Asking macOS for clipboard access…"
        worker=Task {[weak self] in
            guard let self else {return};defer {finish(id)}
            do {
                let permission=try await reader.requestAccess()
                guard generation==epoch,!Task.isCancelled,!store.isClosed,!locked(),allowed(),settings.clipboard.enabled else {return}
                switch permission {
                case .allowed:status=running ? "Clipboard access available · waiting for a new change":"Clipboard access available · resume when ready"
                case .approvalRequired:status="Choose Always Allow for OSwind in macOS Clipboard settings to monitor future changes"
                case .denied:status="macOS denied clipboard access · review Privacy settings"
                }
            }catch is CancellationError {}catch {if generation==epoch {status=error.localizedDescription}}
        }
    }
    func stop(){running=false;invalidate();timer?.invalidate();timer=nil;status=busy ? "Stopping clipboard work…":"Clipboard paused"}
    func cancelAndWait()async {stop();let task=worker;await task?.value}
    /// Erasure/privacy transitions establish a fresh baseline, not a backfill.
    func invalidate(){epoch=UUID();baseline=nil;lastDigest=nil;worker?.cancel()}
    private func schedule() {
        timer?.invalidate();timer=nil;guard running,schedulesTimers else {return}
        timer=Timer.scheduledTimer(withTimeInterval:limited() ? 5:1,repeats:true) {[weak self] _ in Task {@MainActor in self?.poll()}}
    }
    private func current(_ value:UUID)->Bool {running && value==epoch && !Task.isCancelled && usable}
    private func finish(_ id:UUID){guard operationID==id else {return};worker=nil;operationID=nil;busy=false;if !running,status=="Stopping clipboard work…" {status="Clipboard paused"}}
    /// The timer checks only permission/count until a new change is observed.
    /// Off, locked, idle and retired scopes do not probe pasteboard contents.
    func poll() {
        guard running,!busy else {return}
        guard usable else {baseline=nil;lastDigest=nil;status="Clipboard waiting for an active eligible session";return}
        let generation=epoch,id=UUID();operationID=id;busy=true
        worker=Task {[weak self] in
            guard let self else {return};defer {finish(id)}
            do {
                let probe=try await reader.probe();guard current(generation) else {return}
                guard probe.access == .allowed,let count=probe.changeCount,count>=0 else {baseline=nil;lastDigest=nil;status=probe.access == .denied ? "macOS denied clipboard access":"Clipboard monitoring needs macOS Always Allow access";return}
                let previous=baseline;baseline=count
                guard let previous else {status="Ready · existing clipboard content was ignored";return}
                guard previous != count else {unchanged+=1;return}
                let store=self.store
                let validation=Task.detached(priority:.utility) {try store.validateDirectoryIdentity()}
                try await withTaskCancellationHandler {try await validation.value} onCancel:{validation.cancel()}
                guard current(generation) else {return}
                guard let before=await context() else {throw ClipboardObservationSkip("Accessibility or foreground window context is unavailable")}
                guard current(generation) else {return}
                try ClipboardTextDraft.admittedContext(before,policy:settings.privacy)
                let began=ProcessInfo.processInfo.systemUptime,snapshot=try await reader.read(count,before.bundle)
                guard current(generation) else {return}
                guard let after=await context() else {throw ClipboardObservationSkip("Foreground context could not be renewed")}
                guard current(generation) else {return}
                let draft=try ClipboardTextDraft(snapshot:snapshot,before:before,after:after,sessionID:session,at:Date(),elapsedSeconds:ProcessInfo.processInfo.systemUptime-began,policy:settings.privacy)
                guard draft.digest != lastDigest else {unchanged+=1;status="Repeated clipboard text was ignored";return}
                guard let saveSource else {throw OSwindError.unavailable("Clipboard admission is not attached to this library")}
                let result=try await saveSource(draft);guard current(generation) else {return}
                if result.imported>0 {lastDigest=draft.digest;saved+=result.imported;status="Clipboard text saved · available in Memories and Ask"}else {skipped+=1;status="Current privacy rules excluded this clipboard observation"}
            }catch is CancellationError {}
            catch {guard generation==epoch,running else {return};skipped+=1;status=error.localizedDescription}
        }
    }
}
