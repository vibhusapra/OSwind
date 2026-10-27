import AppKit
import Carbon
import Combine

struct ShortcutRegistrationFailure:Equatable {
    var stage:String,status:OSStatus?
    var diagnostic:String {stage+(status.map {" (\($0))"} ?? "")}
}

/// Injectable native calls keep registration/cleanup tests from claiming the
/// real global shortcut, changing focus or inspecting another app.
struct ShortcutCarbonCalls {
    var install:(inout EventHandlerRef?)->OSStatus
    var register:(EventHotKeyID,inout EventHotKeyRef?)->OSStatus
    var unregister:(EventHotKeyRef)->OSStatus
    var remove:(EventHandlerRef)->OSStatus
    static var live:Self {
        .init(install:{handler in
            var spec=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
            return InstallEventHandler(GetApplicationEventTarget(),{_,event,_ in
                guard let event else {return OSStatus(eventNotHandledErr)}
                var identifier=EventHotKeyID(),size=0
                guard GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,&size,&identifier)==noErr,
                      size==MemoryLayout<EventHotKeyID>.size,identifier.signature==0x4f53574e else {return OSStatus(eventNotHandledErr)}
                let signature=identifier.signature,id=identifier.id
                DispatchQueue.main.async {GlobalShortcutModel.shared.receive(signature:signature,id:id)}
                return noErr
            },1,&spec,nil,&handler)
        },register:{identifier,reference in
            RegisterEventHotKey(UInt32(kVK_Space),UInt32(cmdKey|shiftKey),identifier,GetApplicationEventTarget(),0,&reference)
        },unregister:{UnregisterEventHotKey($0)},remove:{RemoveEventHandler($0)})
    }
}

@MainActor final class NativeShortcutRegistration {
    private let calls:ShortcutCarbonCalls
    private var handler:EventHandlerRef?,key:EventHotKeyRef?
    init(calls:ShortcutCarbonCalls = .live) {self.calls=calls}
    var hasResources:Bool {handler != nil || key != nil}
    func start(id:UInt32)->ShortcutRegistrationFailure? {
        guard !hasResources else {return .init(stage:"Previous shortcut resources remain",status:nil)}
        // Only success transfers ownership. An error out-parameter must never
        // be passed to native cleanup as if it were an owned registration.
        var installedHandler:EventHandlerRef?
        let installed=calls.install(&installedHandler)
        guard installed==noErr,let installedHandler else {return .init(stage:"Event handler registration",status:installed==noErr ? nil:installed)}
        handler=installedHandler
        var registeredKey:EventHotKeyRef?
        let registered=calls.register(EventHotKeyID(signature:0x4f53574e,id:id),&registeredKey)
        guard registered==noErr,let registeredKey else {return .init(stage:"Shortcut registration",status:registered==noErr ? nil:registered)}
        key=registeredKey
        return nil
    }
    /// Retain failed resources for an explicit retry. Never install a second
    /// handler/key while cleanup is unconfirmed; inactive tickets drop events.
    func stop()->ShortcutRegistrationFailure? {
        if let key {
            let status=calls.unregister(key)
            guard status==noErr else {return .init(stage:"Shortcut cleanup",status:status)}
            self.key=nil
        }
        if let handler {
            let status=calls.remove(handler)
            guard status==noErr else {return .init(stage:"Event handler cleanup",status:status)}
            self.handler=nil
        }
        return nil
    }
}

@MainActor final class GlobalShortcutModel:ObservableObject {
    static let shared=GlobalShortcutModel()
    enum State:Equatable {case idle,registered,unavailable}
    @Published private(set) var state:State = .idle
    @Published private(set) var diagnostic=""
    @Published private(set) var keyConflict=false
    private let driver:NativeShortcutRegistration
    private var action:(()->Void)?
    private var activeID:UInt32?,lastID:UInt64=0
    init(driver:NativeShortcutRegistration?=nil) {self.driver=driver ?? NativeShortcutRegistration()}
    var message:String {
        switch state {
        case .idle:return "The desktop shortcut has not been registered."
        case .registered:return "⇧⌘Space is registered with macOS."
        case .unavailable:return (keyConflict ? "⇧⌘Space is already in use.":"⇧⌘Space is unavailable.")+" Open OSwind from the Dock or menu bar; reviewed drafts can still be copied."
        }
    }
    func configure(action:@escaping ()->Void) {self.action=action;retry()}
    func retry() {
        activeID=nil;diagnostic="";keyConflict=false
        if let failure=driver.stop() {state = .unavailable;diagnostic=failure.diagnostic;return}
        guard action != nil else {state = .idle;return}
        guard lastID<UInt32.max else {state = .unavailable;diagnostic="Restart OSwind before registering another shortcut.";return}
        lastID+=1;let id=UInt32(lastID)
        if let failure=driver.start(id:id) {
            state = .unavailable;diagnostic=failure.diagnostic
            keyConflict=failure.stage=="Shortcut registration" && failure.status==OSStatus(eventHotKeyExistsErr)
            if let cleanup=driver.stop() {diagnostic+=" · "+cleanup.diagnostic}
            return
        }
        activeID=id;state = .registered
    }
    func receive(signature:OSType,id:UInt32) {
        guard signature==0x4f53574e,id==activeID,state == .registered else {return}
        action?()
    }
    func stop() {
        activeID=nil;action=nil;keyConflict=false
        if let failure=driver.stop() {state = .unavailable;diagnostic=failure.diagnostic}
        else {state = .idle;diagnostic=""}
    }
}
