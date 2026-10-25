import AppKit
import ApplicationServices
import Carbon
import CryptoKit
import OSwindCore

struct DraftDestination:Equatable {
    let token:UUID
    let app:String
    let bundle:String
    let title:String
    let selectionLength:Int
    let capturedAt:TimeInterval
}

/// Value-only checks also exercised without sending input to the desktop.
struct DraftTargetFacts:Equatable {
    var trusted=true,locked=false,secureInput=false,protectedAncestor=false
    var app="TextEdit",bundle="com.apple.TextEdit",title="Untitled",role=kAXTextAreaRole
    var selection=CFRange(location:0,length:0)
    var characterCount=0
    var writable=true
    static func ==(a:Self,b:Self)->Bool {
        a.trusted==b.trusted && a.locked==b.locked && a.secureInput==b.secureInput && a.protectedAncestor==b.protectedAncestor && a.app==b.app && a.bundle==b.bundle && a.title==b.title && a.role==b.role && a.selection.location==b.selection.location && a.selection.length==b.selection.length && a.characterCount==b.characterCount && a.writable==b.writable
    }
}
enum DraftInsertionGuard {
    static let lifetime:TimeInterval=300
    static let maximumBytes=64*1024
    static func validate(_ facts:DraftTargetFacts,privacy:PrivacyPolicy) throws {
        func refuse(_ message:String) throws {throw OSwindError.unavailable(message)}
        guard facts.trusted else {try refuse("Accessibility permission is required for insertion. Copy the draft or enable OSwind in System Settings.");return}
        guard !facts.locked,!facts.secureInput,!facts.protectedAncestor else {try refuse("Protected input or a locked session cannot receive a draft.");return}
        guard !facts.bundle.isEmpty,facts.bundle != "com.oswind.desktop",facts.bundle != Bundle.main.bundleIdentifier else {try refuse("Focus an editable field in another app, then press ⇧⌘Space.");return}
        guard !WindowContext.isBrowser(bundle:facts.bundle) else {try refuse("Browser insertion is not yet qualified. Use Copy for this destination.");return}
        guard !["com.apple.terminal","com.googlecode.iterm2","com.mitchellh.ghostty","dev.warp.warp-stable","org.alacritty","net.kovidgoyal.kitty","co.zeit.hyper","com.microsoft.vscode","com.todesktop.230313mzl4w4u92"].contains(facts.bundle.lowercased()) else {try refuse("Terminal and IDE destinations require manual paste. Use Copy.");return}
        guard privacy.exclusion(app:facts.bundle,title:facts.title,url:nil)==nil else {try refuse("This destination is excluded by your privacy settings.");return}
        guard [kAXTextFieldRole,kAXTextAreaRole].contains(facts.role),facts.writable else {try refuse("This field does not support selected-text insertion. Use Copy.");return}
        guard facts.selection.location>=0,facts.selection.length>=0,facts.characterCount>=0,
              facts.selection.location<=facts.characterCount,facts.selection.length<=facts.characterCount-facts.selection.location,
              facts.selection.length<=maximumBytes else {try refuse("The destination selection is unavailable or too large. Use Copy.");return}
    }
    static func validateUnchanged(_ original:DraftTargetFacts,_ current:DraftTargetFacts,selectedHash:Data,currentHash:Data) throws {
        guard original==current,selectedHash==currentHash else {throw OSwindError.unavailable("The field, window or selection changed. Choose the destination again before inserting.")}
    }
    static func validateText(_ text:String) throws {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.utf8.count<=maximumBytes,
              !text.unicodeScalars.contains(where:{$0.value==0 || ($0.value<32 && ![9,10,13].contains($0.value)) || (127...159).contains($0.value)}) else {
            throw OSwindError.invalid("Use a nonempty draft up to 64 KiB, without control characters other than tabs and newlines.")
        }
    }
    static func validateAge(_ captured:TimeInterval,now:TimeInterval) throws {
        guard captured.isFinite,now.isFinite,now>=captured,now-captured<lifetime else {throw OSwindError.unavailable("The destination expired. Focus the intended field and press ⇧⌘Space again.")}
    }
}

@MainActor protocol DraftInsertionTransport:AnyObject {
    func capture(privacy:PrivacyPolicy) throws -> DraftDestination
    func activate(_ destination:DraftDestination) throws
    func insert(_ text:String,at destination:DraftDestination,privacy:PrivacyPolicy) throws
    func clear()
}

/// Owns one explicit shortcut's AX references. No observer, timer, clipboard or
/// keyboard-event transport; no field's full value is read or replaced.
@MainActor final class NativeDraftInsertion:DraftInsertionTransport {
    private struct Binding {
        let destination:DraftDestination,application:NSRunningApplication,launch:Date?
        let window:AXUIElement,field:AXUIElement
        let facts:DraftTargetFacts,selectionHash:Data
    }
    private var binding:Binding?
    private var deadline:TimeInterval=0
    private var expectedPID:pid_t=0
    private func checkpoint() throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime<deadline else {throw OSwindError.unavailable("The app took too long to check its field. Use Copy or try the shortcut again.")}
        guard AXIsProcessTrusted(),!SessionState.locked,!IsSecureEventInputEnabled() else {throw OSwindError.unavailable("Accessibility is unavailable, or protected input is active.")}
    }
    private func prepare(_ element:AXUIElement) throws {
        try checkpoint()
        let remaining=deadline-ProcessInfo.processInfo.systemUptime
        guard AXUIElementSetMessagingTimeout(element,Float(min(0.04,max(0.001,remaining)))) == .success else {throw OSwindError.unavailable("The destination cannot be checked.")}
    }
    private func value(_ element:AXUIElement,_ attribute:String,optional:Bool=false) throws -> CFTypeRef? {
        try prepare(element);var result:CFTypeRef?
        let status=AXUIElementCopyAttributeValue(element,attribute as CFString,&result)
        try checkpoint()
        if optional,[.attributeUnsupported,.noValue].contains(status) {return nil}
        guard status == .success,let result else {throw OSwindError.unavailable("The destination did not provide a complete field check. Use Copy.")}
        return result
    }
    private func node(_ element:AXUIElement,_ attribute:String) throws -> AXUIElement {
        guard let result=try value(element,attribute),CFGetTypeID(result)==AXUIElementGetTypeID() else {throw OSwindError.unavailable("The focused field could not be identified.")}
        let output=unsafeBitCast(result,to:AXUIElement.self);var pid:pid_t=0
        guard AXUIElementGetPid(output,&pid) == .success,pid==expectedPID else {throw OSwindError.unavailable("The field belongs to a different application.")}
        return output
    }
    private func string(_ element:AXUIElement,_ attribute:String,optional:Bool=false) throws -> String {
        guard let result=try value(element,attribute,optional:optional) else {return ""}
        guard let text=result as? String,text.utf8.count<=DraftInsertionGuard.maximumBytes else {throw OSwindError.unavailable("The destination supplied unsupported text metadata.")}
        return text
    }
    private func observe(_ app:NSRunningApplication,privacy:PrivacyPolicy) throws -> (AXUIElement,AXUIElement,DraftTargetFacts,Data) {
        expectedPID=app.processIdentifier
        let root=AXUIElementCreateApplication(app.processIdentifier)
        let window=try node(root,kAXFocusedWindowAttribute),field=try node(root,kAXFocusedUIElementAttribute)
        var facts=DraftTargetFacts();facts.app=app.localizedName ?? "App";facts.bundle=app.bundleIdentifier ?? ""
        facts.title=try string(window,kAXTitleAttribute);facts.role=try string(field,kAXRoleAttribute)
        // Verify the complete focused-element ancestry up to this exact window.
        // Unsupported, cyclic or excessively deep trees are refused.
        var ancestor=field,seen=[AXUIElement](),reachedWindow=false
        for _ in 0..<16 {
            guard !seen.contains(where:{CFEqual($0,ancestor)}) else {break};seen.append(ancestor)
            let subrole=try string(ancestor,kAXSubroleAttribute,optional:true)
            if subrole==kAXSecureTextFieldSubrole {facts.protectedAncestor=true}
            if CFEqual(ancestor,window) {reachedWindow=true;break}
            ancestor=try node(ancestor,kAXParentAttribute)
        }
        guard reachedWindow else {throw OSwindError.unavailable("The field could not be bound to its window. Use Copy.")}
        // Refuse sensitive/non-text roles before requesting any selected text.
        try DraftInsertionGuard.validate(facts,privacy:privacy)
        guard let raw=try value(field,kAXSelectedTextRangeAttribute),CFGetTypeID(raw)==AXValueGetTypeID() else {throw OSwindError.unavailable("The selection is unavailable.")}
        let rangeValue=unsafeBitCast(raw,to:AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange,AXValueGetValue(rangeValue,.cfRange,&facts.selection),
              let count=try value(field,kAXNumberOfCharactersAttribute) as? NSNumber,CFGetTypeID(count) != CFBooleanGetTypeID(),
              count.doubleValue.isFinite,count.doubleValue.rounded()==count.doubleValue,count.doubleValue>=0,count.doubleValue<=Double(Int.max/2) else {throw OSwindError.unavailable("The selection bounds are unavailable.")}
        facts.characterCount=count.intValue
        try prepare(field);var writable=DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(field,kAXSelectedTextAttribute as CFString,&writable) == .success else {throw OSwindError.unavailable("This editor cannot confirm selected-text support. Use Copy.")}
        facts.writable=writable.boolValue
        try DraftInsertionGuard.validate(facts,privacy:privacy)
        let selected=try string(field,kAXSelectedTextAttribute)
        guard selected.utf16.count==facts.selection.length else {throw OSwindError.unavailable("The selected text changed while checking the field.")}
        return (window,field,facts,Data(SHA256.hash(data:Data(selected.utf8))))
    }
    func capture(privacy:PrivacyPolicy) throws -> DraftDestination {
        clear();deadline=ProcessInfo.processInfo.systemUptime+0.5
        try checkpoint()
        guard let app=NSWorkspace.shared.frontmostApplication,!app.isTerminated,app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {throw OSwindError.unavailable("Focus a field in another app and press ⇧⌘Space to choose a destination.")}
        let (window,field,facts,hash)=try observe(app,privacy:privacy)
        try DraftInsertionGuard.validate(facts,privacy:privacy)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier else {throw OSwindError.unavailable("Focus changed during the field check. Try again.")}
        let destination=DraftDestination(token:UUID(),app:facts.app,bundle:facts.bundle,title:facts.title,selectionLength:facts.selection.length,capturedAt:ProcessInfo.processInfo.systemUptime)
        binding=Binding(destination:destination,application:app,launch:app.launchDate,window:window,field:field,facts:facts,selectionHash:hash)
        return destination
    }
    private func bound(_ destination:DraftDestination) throws -> Binding {
        guard let current=binding,current.destination==destination,!current.application.isTerminated,current.application.launchDate==current.launch else {throw OSwindError.unavailable("The destination is no longer available. Choose it again with ⇧⌘Space.")}
        try DraftInsertionGuard.validateAge(destination.capturedAt,now:ProcessInfo.processInfo.systemUptime)
        return current
    }
    func activate(_ destination:DraftDestination) throws {
        deadline=ProcessInfo.processInfo.systemUptime+0.5;try checkpoint()
        let current=try bound(destination)
        guard current.application.activate(options:[]) else {throw OSwindError.unavailable("The destination app could not be activated.")}
    }
    func insert(_ text:String,at destination:DraftDestination,privacy:PrivacyPolicy) throws {
        deadline=ProcessInfo.processInfo.systemUptime+0.5
        try DraftInsertionGuard.validateText(text);try checkpoint();let current=try bound(destination)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier==current.application.processIdentifier else {throw OSwindError.unavailable("Another app took focus. Nothing was inserted.")}
        let (window,field,facts,hash)=try observe(current.application,privacy:privacy)
        try DraftInsertionGuard.validate(facts,privacy:privacy)
        guard CFEqual(window,current.window),CFEqual(field,current.field) else {throw OSwindError.unavailable("The destination field or window changed. Choose it again.")}
        try DraftInsertionGuard.validateUnchanged(current.facts,facts,selectedHash:current.selectionHash,currentHash:hash)
        let root=AXUIElementCreateApplication(current.application.processIdentifier)
        guard CFEqual(try node(root,kAXFocusedUIElementAttribute),field),CFEqual(try node(root,kAXFocusedWindowAttribute),window) else {throw OSwindError.unavailable("Focus changed before insertion. Nothing was inserted.")}
        try prepare(field)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier==current.application.processIdentifier else {throw OSwindError.unavailable("Focus changed before insertion. Nothing was inserted.")}
        // One attempt. Errors may hide a completed write: never retry or fall
        // back to keystrokes, full-value replacement, clipboard, Enter or Send.
        let result=AXUIElementSetAttributeValue(field,kAXSelectedTextAttribute as CFString,text as CFString)
        clear()
        guard result == .success else {throw OSwindError.unavailable("The app did not confirm insertion. Check the destination before inserting again to avoid duplicates.")}
    }
    func clear(){binding=nil}
}
