import AppKit
import ScreenCaptureKit
import Vision
import ImageIO
import UniformTypeIdentifiers
import ApplicationServices

public struct WindowContext: Sendable {
    public var app: String
    public var bundle: String
    public var pid: pid_t
    public var title: String
    public var url: String?
    public var accessibilityText: String
    public var secure: Bool
    public var bounds: CGRect? = nil
    public var browser: Bool { ["safari", "chrome", "firefox", "arc", "brave", "edge", "vivaldi", "orion"].contains { bundle.lowercased().contains($0) } }
}
public enum AccessibilityContext {
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
public enum SessionState {
    public static var locked: Bool {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return dictionary["CGSSessionScreenIsLocked"] as? Bool == true || dictionary[kCGSessionOnConsoleKey as String] as? Bool == false
    }
}
public struct CaptureMetrics: Sendable {
    public var saved = 0, unchanged = 0, excluded = 0, idle = 0, errors = 0
    public var lastLatencyMS = 0.0
    public init() {}
}
@MainActor public final class CaptureController: ObservableObject {
    @Published public private(set) var running = false
    @Published public private(set) var status = "Paused"
    @Published public private(set) var metrics = CaptureMetrics()
    public var settings: AppSettings {
        didSet {
            guard settings.profile != oldValue.profile || settings.visualCaptureMode != oldValue.visualCaptureMode || settings.allDisplays != oldValue.allDisplays || settings.privacy != oldValue.privacy else {return}
            epoch=UUID(); replayGate.invalidate();replayGate=ReplayCommitGate()
            if running { replay?.stop(discard:true);replay=nil;timer?.invalidate();configureMode() }
        }
    }
    private var replay:ReplayCaptureSession?
    private var replayGate=ReplayCommitGate()
    public var onCapture: ((Memory) -> Void)?
    private let store: MemoryStore
    private let embedder: LocalEmbedder
    private var timer: Timer?
    private var observers = [NSObjectProtocol]()
    private var busy = false
    private var epoch = UUID()
    private var suspended = false
    private var fingerprints = [String: [UInt8]]()
    private var lastCapture = Date.distantPast
    public init(store: MemoryStore, embedder: LocalEmbedder, settings: AppSettings) {
        self.store = store; self.embedder = embedder; self.settings = settings
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in guard let self, self.running, Date().timeIntervalSince(self.lastCapture) > 1 else { return }; await self.captureOnce() } })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] { observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.suspended = true; self?.epoch = UUID(); self?.status = "Sleeping / locked"; self?.replay?.stop(); self?.replay=nil } }) }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] { observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.suspended = false; if let self,self.running {self.configureMode()} } }) }
    }
    public func start() { guard !running else { return }; guard CGPreflightScreenCaptureAccess() else { status = "Screen Recording permission required"; return }; running = true; epoch = UUID(); status = "Listening for changes"; configureMode() }
    private func configureMode() {
        if settings.visualCaptureMode == .replay && !settings.allDisplays {
            timer?.invalidate();timer=nil;replay?.stop();
            let session=ReplayCaptureSession(store:store,embedder:embedder,settings:settings,gate:replayGate,onMemory:{[weak self] memory in guard let self else {return};self.metrics.saved+=1;self.onCapture?(memory)},onStatus:{[weak self] text in self?.status=text},onFailure:{[weak self] _ in self?.metrics.errors+=1})
            replay=session;session.start()
        } else {replay?.stop();replay=nil;schedule();Task {await captureOnce()}}
    }
    public func pause(discardReplay:Bool=false) { if discardReplay {replayGate.invalidate();replayGate=ReplayCommitGate()}; replay?.stop(discard:discardReplay);replay=nil; running = false; epoch = UUID(); timer?.invalidate(); timer = nil; status = "Paused" }
    /// Explicit bounded replay, including a chosen app. Existing permissions
    /// only; never prompts or falls through to a different app when absent.
    public func captureReplay(seconds:Double,targetBundleID:String?=nil) async throws {
        guard seconds.isFinite,seconds>=1,seconds<=120,!running,!busy,!suspended else {throw OSwindError.invalid("Replay requires 1–120 seconds and an idle controller")}
        guard !SessionState.locked,CGPreflightScreenCaptureAccess() else {throw OSwindError.unavailable("Replay needs an unlocked session and existing Screen Recording access")}
        let previousSaved=metrics.saved,previousErrors=metrics.errors
        busy=true;running=true;defer {busy=false;running=false;replay=nil}
        let session=ReplayCaptureSession(store:store,embedder:embedder,settings:settings,gate:replayGate,targetBundleID:targetBundleID,onMemory:{[weak self] memory in self?.metrics.saved+=1;self?.onCapture?(memory)},onStatus:{[weak self] text in self?.status=text},onFailure:{[weak self] _ in self?.metrics.errors+=1})
        replay=session;session.start()
        do {try await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000))} catch {session.stop(discard:true);await session.waitUntilStopped();throw error}
        session.stop();await session.waitUntilStopped()
        guard metrics.errors==previousErrors else {throw OSwindError.unavailable("Replay encountered \(metrics.errors-previousErrors) errors: "+status)}
        guard metrics.saved>previousSaved else {throw OSwindError.unavailable("Replay saved no evidence: "+status)}
    }
    private func schedule() {
        timer?.invalidate(); let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
        let interval = settings.profile.effectiveInterval(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalLimited: ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical, idleSeconds: idle) ?? 20
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in Task { @MainActor in guard let self, self.running else { return }; await self.captureOnce(); self.schedule() } }
    }
    public func captureOnce(manual: Bool = false, targetBundleID: String? = nil) async {
        guard manual || settings.visualCaptureMode != .replay || settings.allDisplays else {return}
        guard manual || targetBundleID == nil else { status = "Targeted app capture requires a manual request"; return }
        guard !busy, !suspended, running || manual else { return }
        guard !SessionState.locked else { status = "Locked · capture suspended"; return }
        guard CGPreflightScreenCaptureAccess() else { status = "Screen Recording permission required"; return }
        if !manual, CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null) > 120 { metrics.idle += 1; status = "Idle · saving energy"; return }
        guard let context = AccessibilityContext.current(targetBundleID:targetBundleID) else { status = "Application context unavailable"; return }
        if context.bundle == "com.oswind.desktop" || context.bundle == Bundle.main.bundleIdentifier { status = "OSwind window · skipped"; return }
        if context.secure { metrics.excluded += 1; status = "Protected text field · skipped"; return }
        if let reason = settings.privacy.exclusion(app: context.bundle, title: context.title, url: context.url, isBrowser: context.browser) { metrics.excluded += 1; status = reason; return }
        busy = true; defer { busy = false }; let token = epoch; let begin = Date(); lastCapture = begin
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            var captures = [(SCContentFilter, String, String)]()
            if settings.allDisplays {
                // Domain privacy cannot be established for background browser tabs. Mask all browsers in display mode.
                let blocked = content.applications.filter { app in settings.privacy.excludedApps.contains(app.bundleIdentifier) || app.bundleIdentifier == Bundle.main.bundleIdentifier || ["safari","chrome","firefox","arc","brave","edge","vivaldi","orion"].contains(where: { app.bundleIdentifier.lowercased().contains($0) }) }
                for display in content.displays { captures.append((SCContentFilter(display: display, excludingApplications: blocked, exceptingWindows: []), "display-\(display.displayID)", "Display \(display.displayID)")) }
            } else if let window = content.windows.first(where: { $0.owningApplication?.processID == context.pid && $0.windowLayer == 0 && $0.frame.width > 100 && $0.frame.height > 100 && settings.privacy.exclusion(app: context.bundle, title: $0.title ?? context.title, url: context.url, isBrowser: context.browser) == nil }) {
                captures.append((SCContentFilter(desktopIndependentWindow: window), "window-\(window.windowID)", window.title ?? context.title))
            }
            for (filter, displayID, title) in captures {
                let config = SCStreamConfiguration(); let rect = filter.contentRect; let scale = min(2.0, Double(settings.profile.maxDimension) / max(rect.width, rect.height)); config.width = max(1, Int(rect.width * scale)); config.height = max(1, Int(rect.height * scale)); config.showsCursor = false; config.captureResolution = .best
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let pixels = Self.fingerprint(image)
                if !manual, let old = fingerprints[displayID], Self.difference(old, pixels) < 2.0 { metrics.unchanged += 1; status = "Unchanged · skipped"; continue }
                let policy = settings.privacy, quality = settings.profile.jpegQuality, root = store.root, localEmbedder = embedder
                var memory = try await Task.detached(priority: .utility) {
                    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true; request.automaticallyDetectsLanguage = true
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let regions = (request.results ?? []).compactMap { observation -> TextRegion? in guard let text = observation.topCandidates(1).first?.string else { return nil }; let b = observation.boundingBox; return TextRegion(text: text, x: b.minX, y: b.minY, width: b.width, height: b.height) }
                    let ocr = regions.map(\.text).joined(separator: "\n")
                    let text = policy.sanitize(ocr + (context.accessibilityText.isEmpty ? "" : "\n\n" + context.accessibilityText))
                    let safeTitle = policy.sanitize(title), safeURL = policy.sanitize(context.url ?? "")
                    var m = Memory(app: context.app, bundleID: context.bundle, title: safeTitle.text, url: safeURL.text.isEmpty ? nil : safeURL.text, text: text.text, display: displayID, regions: text.redacted ? [] : regions)
                    // A text redaction also suppresses the raw image; never retain secrets in screenshot pixels.
                    if policy.retainImages && !text.redacted && !safeTitle.redacted && !safeURL.redacted {
                        let relative = "images/\(m.id).jpg"; let dest = root.appendingPathComponent(relative)
                        if let output = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil) { CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary); guard CGImageDestinationFinalize(output) else { throw OSwindError.unavailable("Cannot save screenshot") }; m.imagePath = relative }
                    }
                    m.embedding = localEmbedder.embed(m.searchableText); m.embeddingModel = m.embedding == nil ? nil : localEmbedder.modelID; return m
                }.value
                guard epoch == token, running || manual, !suspended, !SessionState.locked else { if let path = memory.imagePath { try? FileManager.default.removeItem(at: root.appendingPathComponent(path)) }; return }
                memory.timestamp = begin
                do { try store.insert(memory) } catch { if let path = memory.imagePath { try? FileManager.default.removeItem(at: root.appendingPathComponent(path)) }; throw error }
                let saved = memory, passageStore = store
                if settings.search.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled { try await Task.detached(priority:.utility) { try passageStore.indexApplePassages(saved,embedder:localEmbedder) }.value }
                fingerprints[displayID] = pixels; metrics.saved += 1; metrics.lastLatencyMS = Date().timeIntervalSince(begin) * 1000; status = "Saved \(context.app) · \(Int(metrics.lastLatencyMS)) ms"; onCapture?(memory)
            }
        } catch { metrics.errors += 1; status = error.localizedDescription }
    }
    nonisolated public static func fingerprint(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 32 * 18)
        pixels.withUnsafeMutableBytes { bytes in if let ctx = CGContext(data: bytes.baseAddress, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) { ctx.interpolationQuality = .low; ctx.draw(image, in: CGRect(x: 0,y: 0,width: 32,height: 18)) } }; return pixels
    }
    nonisolated public static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double { guard a.count == b.count, !a.isEmpty else { return .infinity }; return Double(zip(a,b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count) }
}
