import AppKit
import ApplicationServices

/// Session/identity checks are cheap enough for the replay supervisor. Keeping
/// a stream binding alive is not permission to recognize or retain a frame:
/// every frame still needs fresh complete AX observations around its OCR.
@MainActor struct ReplayContextEnvironment {
    var available: (Bool) -> Bool = { targeted in
        !SessionState.locked && CGPreflightScreenCaptureAccess() &&
            (targeted || CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.null)<=120)
    }
    var identityCurrent: (WindowContext,String?) -> Bool = {
        AccessibilityContext.identityCurrent($0,targetBundleID:$1)
    }
    var read: (String?) async -> WindowContext? = {
        await AccessibilityContext.read(targetBundleID:$0)
    }
    var binding: (String?) async -> WindowContext? = {
        await AccessibilityContext.readBinding(targetBundleID:$0)
    }
}

@MainActor final class ReplayContextMonitor {
    private let target:String?
    private let environment:ReplayContextEnvironment
    private let reads:AccessibilityReadSession
    private let bindings:AccessibilityReadSession
    convenience init(target:String?) {self.init(target:target,environment:ReplayContextEnvironment())}
    init(target:String?,environment:ReplayContextEnvironment) {
        self.target=target;self.environment=environment
        reads=AccessibilityReadSession(operation:environment.read)
        bindings=AccessibilityReadSession(operation:environment.binding)
    }
    var available:Bool {!Task.isCancelled && environment.available(target != nil)}

    /// This avoids repeated tree traversal while no new frame is delivered.
    /// Only focused-window metadata is observed. URL, tree text and secure-field
    /// state are NOT inferred: fresh() must independently admit each frame.
    func canKeepBinding(_ context:WindowContext?,intervalUnchanged:Bool) async -> Bool {
        guard available,intervalUnchanged,let context else {return false}
        guard environment.identityCurrent(context,target) else {return false}
        let observed=await bindings.read(target)
        guard available,let observed,environment.identityCurrent(observed,target) else {return false}
        return Self.bindingKey(context)==Self.bindingKey(observed)
    }
    func fresh(policy:PrivacyPolicy) async -> WindowContext? {
        guard available else {return nil}
        let context=await reads.read(target)
        guard available,let context,environment.identityCurrent(context,target),
              !context.secure,context.bundle != Bundle.main.bundleIdentifier,
              context.bundle != "com.oswind.desktop",
              policy.exclusion(app:context.bundle,title:context.title,url:context.url,isBrowser:context.browser)==nil else {return nil}
        return context
    }
    func cancel(){reads.cancel();bindings.cancel()}
    private static func bindingKey(_ context:WindowContext)->String {
        [String(context.pid),context.bundle,context.title,context.bounds.map {NSStringFromRect($0)} ?? ""].joined(separator:"\u{0}")
    }
    static func key(_ context:WindowContext)->String {
        [String(context.pid),context.bundle,context.title,context.url ?? "",context.bounds.map {NSStringFromRect($0)} ?? ""].joined(separator:"\u{0}")
    }
}
