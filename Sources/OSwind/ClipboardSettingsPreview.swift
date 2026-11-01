#if DEBUG
import Foundation
import OSwindCore

@MainActor enum ClipboardSettingsPreview {
    static func make(store:MemoryStore,stage:String)async throws->(model:ClipboardContextModel,enabled:Bool) {
        var settings=AppSettings();settings.clipboard.enabled=stage != "ClipboardOff"
        let permission:ClipboardAccess=stage=="ClipboardPermission" ? .approvalRequired:.allowed
        let reader=ClipboardReader(probe:{.init(access:permission,changeCount:permission == .allowed ? 7:nil)},read:{_,_ in throw OSwindError.unavailable("A component preview never reads a pasteboard")},requestAccess:{permission})
        let model=ClipboardContextModel(store:store,settings:settings,reader:reader,context:{nil},locked:{false},idle:{false},limited:{false},schedulesTimers:false,workspaceNotifications:NotificationCenter())
        if ["ClipboardReady","ClipboardPermission"].contains(stage) {
            model.start();let end=ContinuousClock.now.advanced(by:.seconds(5))
            while model.busy {guard ContinuousClock.now<end else {throw OSwindError.unavailable("Authored clipboard preview did not settle")};try await Task.sleep(for:.milliseconds(10))}
        }else if stage=="ClipboardPaused" {model.stop()}
        return (model,settings.clipboard.enabled)
    }
}
#endif
