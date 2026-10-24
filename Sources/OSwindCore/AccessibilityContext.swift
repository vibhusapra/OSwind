import AppKit
import ApplicationServices

// No global AX timeout, observer, cache or cross-request AX object is retained.
// Each async traversal owns its elements; one shared slot bounds its IPC work.
final class AccessibilityWorker:@unchecked Sendable {
    static let shared=AccessibilityWorker()
    private let lock=NSLock()
    private var occupied=false
    private func acquire()->Bool {lock.lock();defer {lock.unlock()};guard !occupied else {return false};occupied=true;return true}
    private func release(){lock.lock();occupied=false;lock.unlock()}
    func run(_ operation:@escaping @Sendable ()->WindowContext?) async -> WindowContext? {
        guard !Task.isCancelled,acquire() else {return nil}
        let worker=Task.detached(priority:.utility) { [self] in
            defer {release()}
            guard !Task.isCancelled else {return nil as WindowContext?}
            let result=operation()
            return Task.isCancelled ? nil:result
        }
        return await withTaskCancellationHandler {await worker.value} onCancel:{worker.cancel()}
    }

}
enum AccessibilityReadFailure:Error {case exhausted,unavailable}
final class AccessibilityReadBudget {
    let maximumNodes:Int,maximumText:Int
    private let maximumMessages:Int,deadline:Double,now:()->Double,cancelled:()->Bool
    private var messages=0
    init(seconds:Double=0.35,maximumNodes:Int=1000,maximumText:Int=16000,maximumMessages:Int=8192,
         now:@escaping ()->Double={ProcessInfo.processInfo.systemUptime},cancelled:@escaping ()->Bool={Task.isCancelled}) {
        self.maximumNodes=maximumNodes;self.maximumText=maximumText;self.maximumMessages=maximumMessages;self.now=now;self.cancelled=cancelled;deadline=now()+seconds
    }
    func checkpoint() throws {if cancelled() {throw CancellationError()};guard now()<deadline else {throw AccessibilityReadFailure.exhausted}}
    func message() throws -> Float {try checkpoint();guard messages<maximumMessages else {throw AccessibilityReadFailure.exhausted};messages+=1;return Float(min(0.04,max(0.001,deadline-now())))}
}
enum AccessibilityAttribute {case focusedWindow,focusedElement,title,position,size,role,subrole,url,value,children}
enum AccessibilityTreeValue<Node> {case node(Node),nodes([Node]),string(String),point(CGPoint),size(CGSize)}
protocol AccessibilityTreeSource {
    associatedtype Node:Hashable
    var root:Node {get}
    func value(_ node:Node,_ attribute:AccessibilityAttribute,budget:AccessibilityReadBudget) throws -> AccessibilityTreeValue<Node>?
}
enum AccessibilityTraversal {
    static func read<Source:AccessibilityTreeSource>(_ source:Source,identity:WindowContext,budget:AccessibilityReadBudget) throws -> WindowContext? {
        func value(_ node:Source.Node,_ attribute:AccessibilityAttribute) throws -> AccessibilityTreeValue<Source.Node>? {try budget.checkpoint();return try source.value(node,attribute,budget:budget)}
        func string(_ node:Source.Node,_ attribute:AccessibilityAttribute) throws -> String? {if case .string(let text)=try value(node,attribute) {return text};return nil}
        guard case .node(let window)=try value(source.root,.focusedWindow) else {return nil}
        var context=identity
        context.title=try string(window,.title) ?? ""
        if case .point(let position)=try value(window,.position),case .size(let size)=try value(window,.size) {context.bounds=CGRect(origin:position,size:size)}
        if case .node(let focused)=try value(source.root,.focusedElement),try string(focused,.subrole)==kAXSecureTextFieldSubrole {context.secure=true;return context}
        var queue=[window],known:Set<Source.Node>=[window],offset=0,textSize=0,texts=[String]()
        while offset<queue.count {
            try budget.checkpoint()
            let node=queue[offset];offset+=1
            guard offset<=budget.maximumNodes else {throw AccessibilityReadFailure.exhausted}
            let role=try string(node,.role) ?? "",subrole=try string(node,.subrole) ?? ""
            if subrole==kAXSecureTextFieldSubrole {context.secure=true;return context}
            if context.url==nil {context.url=try string(node,.url)}
            if let text=try string(node,.value),!text.isEmpty {
                if role==kAXTextFieldRole,context.url==nil,(text.hasPrefix("http://") || text.hasPrefix("https://")) {context.url=text}
                if textSize<budget.maximumText,[kAXStaticTextRole,kAXTextAreaRole,kAXTextFieldRole].contains(role) {
                    let separator=texts.isEmpty ? 0:1,remaining=budget.maximumText-textSize-separator
                    if remaining>0 {let bounded=String(text.prefix(min(4000,remaining)));texts.append(bounded);textSize+=separator+bounded.count}
                }
            }
            // Text truncation never terminates security/URL traversal. Cycles
            // are skipped, but an incomplete tree fails closed at the budget.
            if case .nodes(let children)=try value(node,.children) {
                for child in children where !known.contains(child) {
                    guard known.count<budget.maximumNodes else {throw AccessibilityReadFailure.exhausted};known.insert(child);queue.append(child)
                }
            }
        }
        try budget.checkpoint();context.accessibilityText=texts.joined(separator:"\n");return context
    }
}
private struct NativeAccessibilityTree:AccessibilityTreeSource {
    let root:AXUIElement
    init(pid:pid_t){root=AXUIElementCreateApplication(pid)}
    func value(_ node:AXUIElement,_ attribute:AccessibilityAttribute,budget:AccessibilityReadBudget) throws -> AccessibilityTreeValue<AXUIElement>? {
        let name:String
        switch attribute {
        case .focusedWindow:name=kAXFocusedWindowAttribute
        case .focusedElement:name=kAXFocusedUIElementAttribute
        case .title:name=kAXTitleAttribute
        case .position:name=kAXPositionAttribute
        case .size:name=kAXSizeAttribute
        case .role:name=kAXRoleAttribute
        case .subrole:name=kAXSubroleAttribute
        case .url:name=kAXURLAttribute
        case .value:name=kAXValueAttribute
        case .children:name=kAXChildrenAttribute
        }
        func prepare() throws {guard AXUIElementSetMessagingTimeout(node,try budget.message()) == .success else {throw AccessibilityReadFailure.unavailable}}
        func succeeded(_ result:AXError) throws -> Bool {
            switch result {case .success:return true;case .attributeUnsupported,.noValue:return false;default:throw AccessibilityReadFailure.unavailable}
        }
        if attribute == .children {
            try prepare();var count:CFIndex=0
            guard try succeeded(AXUIElementGetAttributeValueCount(node,name as CFString,&count)) else {return nil}
            guard count>=0,count<=budget.maximumNodes else {throw AccessibilityReadFailure.exhausted}
            guard count>0 else {return .nodes([])}
            try prepare();var children:CFArray?
            guard try succeeded(AXUIElementCopyAttributeValues(node,name as CFString,0,count,&children)),let values=children as? [AXUIElement] else {return nil}
            try budget.checkpoint();return .nodes(values)
        }
        try prepare();var output:CFTypeRef?
        guard try succeeded(AXUIElementCopyAttributeValue(node,name as CFString,&output)),let output else {return nil}
        try budget.checkpoint()
        switch attribute {
        case .focusedWindow,.focusedElement:
            guard CFGetTypeID(output)==AXUIElementGetTypeID() else {throw AccessibilityReadFailure.unavailable}
            return .node(unsafeBitCast(output,to:AXUIElement.self))
        case .position,.size:
            guard CFGetTypeID(output)==AXValueGetTypeID() else {return nil}
            let value=unsafeBitCast(output,to:AXValue.self)
            if attribute == .position {var point=CGPoint.zero;return AXValueGetValue(value,.cgPoint,&point) ? .point(point):nil}
            var size=CGSize.zero;return AXValueGetValue(value,.cgSize,&size) ? .size(size):nil
        case .url:
            if let url=output as? URL {return .string(url.absoluteString)}
            return (output as? String).map {.string($0)}
        default:return (output as? String).map {.string($0)}
        }
    }
}
public enum AccessibilityContext {
    @MainActor private static func identity(targetBundleID:String?)->WindowContext? {
        let application=targetBundleID.flatMap {bundle in NSWorkspace.shared.runningApplications.first {$0.bundleIdentifier==bundle}} ?? (targetBundleID==nil ? NSWorkspace.shared.frontmostApplication:nil)
        guard let app=application,!app.isTerminated else {return nil}
        return WindowContext(app:app.localizedName ?? "Unknown",bundle:app.bundleIdentifier ?? "",pid:app.processIdentifier,title:"",accessibilityText:"",secure:false)
    }
    @MainActor static func identityCurrent(_ context:WindowContext,targetBundleID:String?)->Bool {
        guard let now=identity(targetBundleID:targetBundleID) else {return false}
        return context.pid==now.pid && context.bundle==now.bundle
    }
    @MainActor public static func read(targetBundleID:String?=nil) async -> WindowContext? {
        guard !Task.isCancelled,let selected=identity(targetBundleID:targetBundleID) else {return nil}
        // Preserve the explicit optional-AX path for native apps. Browser URL
        // policy and unambiguous ScreenCaptureKit binding still apply; without
        // AX permission, secure-field detection and accessible text are absent.
        if !AXIsProcessTrusted() {return selected}
        let context=await AccessibilityWorker.shared.run {try? AccessibilityTraversal.read(NativeAccessibilityTree(pid:selected.pid),identity:selected,budget:AccessibilityReadBudget())}
        guard !Task.isCancelled,let context,identityCurrent(context,targetBundleID:targetBundleID) else {return nil}
        return context
    }
    // Audio keeps its existing synchronous reader until its startup, segment
    // and finish lifecycle can migrate together. It does not consume or bypass
    // the bounded asynchronous worker slot.
    @MainActor public static func current(targetBundleID: String? = nil) -> WindowContext? {
        let application = targetBundleID.flatMap { bundle in NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundle } } ?? (targetBundleID == nil ? NSWorkspace.shared.frontmostApplication : nil)
        guard let app = application else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?; AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &windowRef)
        var title = "", url: String?, texts = [String](), secure = false, bounds: CGRect?
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? { var out: CFTypeRef?; AXUIElementCopyAttributeValue(element, name as CFString, &out); return out }
        if let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() {
            let window = unsafeBitCast(windowRef, to: AXUIElement.self); title = value(window, kAXTitleAttribute) as? String ?? ""
            if let position=value(window,kAXPositionAttribute),let size=value(window,kAXSizeAttribute),CFGetTypeID(position)==AXValueGetTypeID(),CFGetTypeID(size)==AXValueGetTypeID() {
                var point=CGPoint.zero,dimensions=CGSize.zero
                if AXValueGetValue(unsafeBitCast(position,to:AXValue.self),.cgPoint,&point),AXValueGetValue(unsafeBitCast(size,to:AXValue.self),.cgSize,&dimensions) {bounds=CGRect(origin:point,size:dimensions)}
            }
            var queue: [AXUIElement] = [window], visited = 0, textSize = 0
            while !queue.isEmpty && visited < 600 && textSize < 16000 {
                let element = queue.removeFirst(); visited += 1
                let role = value(element, kAXRoleAttribute) as? String ?? ""
                let subrole = value(element, kAXSubroleAttribute) as? String ?? ""
                if subrole == kAXSecureTextFieldSubrole { secure = true; continue }
                if let u = value(element, kAXURLAttribute) as? URL { url = url ?? u.absoluteString }
                else if let u = value(element, kAXURLAttribute) as? String, u.hasPrefix("http") { url = url ?? u }
                if let text = value(element, kAXValueAttribute) as? String, !text.isEmpty {
                    if role == kAXTextFieldRole, url == nil, text.hasPrefix("http://") || text.hasPrefix("https://") { url = text }
                    if [kAXStaticTextRole,kAXTextAreaRole,kAXTextFieldRole].contains(role) { texts.append(String(text.prefix(4000))); textSize += text.count }
                }
                if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children.prefix(100)) }
            }
        }
        return WindowContext(app: app.localizedName ?? "Unknown", bundle: app.bundleIdentifier ?? "", pid: app.processIdentifier, title: title, url: url, accessibilityText: texts.joined(separator: "\n"), secure: secure,bounds:bounds)
    }
}

/// One replay session coalesces concurrent observations only while its read is
/// in flight. Results are never reused after completion or across targets.
@MainActor final class AccessibilityReadSession {
    private let operation:(String?) async -> WindowContext?
    private var active:(target:String?,task:Task<WindowContext?,Never>)?
    init(operation:@escaping (String?) async -> WindowContext?={await AccessibilityContext.read(targetBundleID:$0)}) {self.operation=operation}
    func read(_ target:String?) async ->WindowContext? {
        guard !Task.isCancelled else {return nil}
        if let active {guard active.target==target else {return nil};let result=await active.task.value;return (Task.isCancelled || active.task.isCancelled) ? nil:result}
        let read=operation,task=Task {await read(target)};active=(target,task);defer {active=nil}
        let result=await task.value;return (Task.isCancelled || task.isCancelled) ? nil:result
    }
    func cancel(){active?.task.cancel()}
    deinit {active?.task.cancel()}
}
