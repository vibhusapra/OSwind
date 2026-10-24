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
            guard settings.profile != oldValue.profile || settings.visualCaptureMode != oldValue.visualCaptureMode || settings.allDisplays != oldValue.allDisplays || settings.snapshotRegions != oldValue.snapshotRegions || settings.privacy != oldValue.privacy else {return}
            if settings.snapshotRegions != oldValue.snapshotRegions {fingerprints.removeAll()}
            epoch=UUID(); replayGate.invalidate();replayGate=ReplayCommitGate()
            cancelSnapshotWork()
            if running { replay?.stop(discard:true);replay=nil;timer?.invalidate();configureMode() }
        }
    }
    private var replay:ReplayCaptureSession?
    private var replayGate=ReplayCommitGate()
    public var onCapture: ((Memory) -> Void)?
    private let store: MemoryStore
    private let embedder: LocalEmbedder
    private let snapshots:SnapshotCaptureEnvironment
    private var snapshotContextWorker:Task<WindowContext?,Never>?
    private var snapshotWorker:Task<(Memory,Data?,MediaAdmissionLease?),Error>?
    private var snapshotPassages:Task<Void,Error>?
    private func cancelSnapshotWork(){snapshotContextWorker?.cancel();snapshotWorker?.cancel();snapshotPassages?.cancel()}
    private var timer: Timer?
    private var observers = [NSObjectProtocol]()
    private var busy = false
    private var epoch = UUID()
    private var suspended = false
    private var fingerprints = [String: [UInt8]]()
    private var lastCapture = Date.distantPast
    public convenience init(store: MemoryStore, embedder: LocalEmbedder, settings: AppSettings) {self.init(store:store,embedder:embedder,settings:settings,snapshots:SnapshotCaptureEnvironment())}
    init(store: MemoryStore, embedder: LocalEmbedder, settings: AppSettings,snapshots:SnapshotCaptureEnvironment) {
        self.store = store; self.embedder = embedder; self.settings = settings;self.snapshots=snapshots
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in guard let self, self.running, Date().timeIntervalSince(self.lastCapture) > 1 else { return }; await self.captureOnce() } })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] { observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.suspended = true; self?.epoch = UUID(); self?.cancelSnapshotWork();self?.status = "Sleeping / locked"; self?.replay?.stop(); self?.replay=nil } }) }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] { observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.suspended = false; if let self,self.running {self.configureMode()} } }) }
    }
    public func start() { guard !running else { return }; guard CGPreflightScreenCaptureAccess() else { status = "Screen Recording permission required"; return }; running = true; epoch = UUID(); status = "Listening for changes"; configureMode() }
    private func configureMode() {
        guard settings.snapshotRegions.valid else {status="Invalid capture area · choose a new area in Settings";return}
        if settings.visualCaptureMode == .replay && !settings.allDisplays && settings.snapshotRegions.focusedWindowCrop==nil {
            timer?.invalidate();timer=nil;replay?.stop();
            let session=ReplayCaptureSession(store:store,embedder:embedder,settings:settings,gate:replayGate,onMemory:{[weak self] memory in guard let self else {return};self.metrics.saved+=1;self.onCapture?(memory)},onStatus:{[weak self] text in self?.status=text},onFailure:{[weak self] _ in self?.metrics.errors+=1})
            replay=session;session.start()
        } else {replay?.stop();replay=nil;schedule();Task {await captureOnce()}}
    }
    public func pause(discardReplay:Bool=false) { if discardReplay {replayGate.invalidate();replayGate=ReplayCommitGate()}; replay?.stop(discard:discardReplay);replay=nil; running = false; epoch = UUID();cancelSnapshotWork();timer?.invalidate(); timer = nil; status = "Paused" }
    /// Explicit bounded replay, including a chosen app. Existing permissions
    /// only; never prompts or falls through to a different app when absent.
    public func captureReplay(seconds:Double,targetBundleID:String?=nil) async throws {
        guard settings.snapshotRegions.valid else {throw OSwindError.invalid("Invalid capture area; choose a new area in Settings")}
        guard !settings.allDisplays else {throw OSwindError.invalid("Replay requires focused-window mode; turn off display capture first")}
        guard settings.snapshotRegions.focusedWindowCrop==nil else {throw OSwindError.invalid("Focused-window replay cannot use a crop; choose snapshots or clear the crop")}
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
    private func readSnapshotContext(_ target:String?) async -> WindowContext? {
        let read=snapshots.context
        let worker=Task {await read(target)}
        snapshotContextWorker=worker;defer {snapshotContextWorker=nil}
        return await withTaskCancellationHandler {await worker.value} onCancel:{worker.cancel()}
    }
    private func snapshotCurrent(token:UUID,manual:Bool)->Bool {
        !Task.isCancelled && epoch==token && (running || manual) && !suspended && !snapshots.locked() && snapshots.permitted()
    }
    private func snapshotContext(_ original:WindowContext,token:UUID,manual:Bool,target:String?) async -> WindowContext? {
        guard snapshotCurrent(token:token,manual:manual) else {return nil}
        let now=await readSnapshotContext(target)
        guard snapshotCurrent(token:token,manual:manual) else {return nil}
        guard let now,SnapshotContextBinding.matches(original,now),snapshots.identityCurrent(now,target),
              settings.privacy.exclusion(app:now.bundle,title:now.title,url:now.url,isBrowser:now.browser)==nil else {
            metrics.excluded+=1;status="Context changed · snapshot discarded";return nil
        }
        return now
    }
    public func captureOnce(manual: Bool = false, targetBundleID: String? = nil) async {
        guard settings.snapshotRegions.valid else {status="Invalid capture area · choose a new area in Settings";return}
        guard manual || settings.visualCaptureMode != .replay || settings.allDisplays || settings.snapshotRegions.focusedWindowCrop != nil else {return}
        guard targetBundleID==nil || !settings.allDisplays else {status="Targeted app capture requires focused-window mode";return}
        guard manual || targetBundleID == nil else { status = "Targeted app capture requires a manual request"; return }
        guard !Task.isCancelled,!busy,!suspended,running || manual else {return}
        guard !snapshots.locked() else {status="Locked · capture suspended";return}
        guard snapshots.permitted() else {status="Screen Recording permission required";return}
        if !manual,CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.null)>120 {metrics.idle+=1;status="Idle · saving energy";return}
        // Reserve the operation before the first suspension: pause, a settings
        // change and a second manual request must invalidate or defer this read.
        busy=true;defer {busy=false};let token=epoch,begin=Date();lastCapture=begin
        let initial=await readSnapshotContext(targetBundleID)
        guard snapshotCurrent(token:token,manual:manual) else {return}
        guard let context=initial,snapshots.identityCurrent(context,targetBundleID) else {status="Application context unavailable or busy";return}
        if context.bundle=="com.oswind.desktop" || context.bundle==Bundle.main.bundleIdentifier {status="OSwind window · skipped";return}
        if context.secure {metrics.excluded+=1;status="Protected text field · skipped";return}
        if let reason=settings.privacy.exclusion(app:context.bundle,title:context.title,url:context.url,isBrowser:context.browser) {metrics.excluded+=1;status=reason;return}
        do {
            let frames=try await snapshots.frames(settings,context)
            if frames.isEmpty {if epoch==token {status="Waiting for an eligible capture source"};return}
            for frame in frames {
                guard await snapshotContext(context,token:token,manual:manual,target:targetBundleID) != nil else {return}
                let image=try await frame.capture()
                guard await snapshotContext(context,token:token,manual:manual,target:targetBundleID) != nil else {return}
                guard try await frame.privacyStillMasked() else {metrics.excluded+=1;status="Source privacy changed · snapshot discarded";return}
                guard var captured=await snapshotContext(context,token:token,manual:manual,target:targetBundleID) else {return}
                if !frame.includeAccessibilityText {captured.accessibilityText=""}
                let pixels=Self.fingerprint(image)
                if !manual,let old=fingerprints[frame.display],Self.difference(old,pixels)<2.0 {metrics.unchanged+=1;status="Unchanged · skipped";continue}
                let policy=settings.privacy,quality=settings.profile.jpegQuality,recognize=snapshots.recognize,localEmbedder=embedder,mediaStore=store,title=frame.title,display=frame.display
                let worker=Task.detached(priority:.utility) {() throws -> (Memory,Data?,MediaAdmissionLease?) in
                    try Task.checkCancellation();let regions=try recognize(image);try Task.checkCancellation()
                    let ocr=regions.map(\.text).joined(separator:"\n"),text=policy.sanitize(ocr+(captured.accessibilityText.isEmpty ? "":"\n\n"+captured.accessibilityText))
                    let safeTitle=policy.sanitize(title),safeURL=policy.sanitize(captured.url ?? "")
                    var memory=Memory(app:captured.app,bundleID:captured.bundle,title:safeTitle.text,url:safeURL.text.isEmpty ? nil:safeURL.text,text:text.text,display:display,regions:text.redacted ? []:regions)
                    var data:Data?,lease:MediaAdmissionLease?
                    if policy.retainImages && !text.redacted && !safeTitle.redacted && !safeURL.redacted {
                        // Encoding stays off the main actor. No raw bytes reach
                        // disk until context is checked after recognition.
                        let bytes=NSMutableData()
                        guard let output=CGImageDestinationCreateWithData(bytes,UTType.jpeg.identifier as CFString,1,nil) else {throw OSwindError.unavailable("Cannot encode screenshot")}
                        CGImageDestinationAddImage(output,image,[kCGImageDestinationLossyCompressionQuality:quality] as CFDictionary)
                        guard CGImageDestinationFinalize(output),bytes.length<=64*1024*1024 else {throw OSwindError.unavailable("Cannot encode a bounded screenshot")}
                        data=bytes as Data;try Task.checkCancellation();lease=try mediaStore.mediaWriteLease()
                    }
                    memory.embedding=localEmbedder.embed(memory.searchableText);memory.embeddingModel=memory.embedding==nil ? nil:localEmbedder.modelID
                    do {try Task.checkCancellation();return (memory,data,lease)} catch {lease?.release();throw error}
                }
                snapshotWorker=worker;defer {snapshotWorker=nil}
                let prepared=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
                defer {prepared.2?.release()}
                guard try await frame.privacyStillMasked() else {metrics.excluded+=1;status="Source privacy changed · snapshot discarded";return}
                guard await snapshotContext(context,token:token,manual:manual,target:targetBundleID) != nil else {return}
                var memory=prepared.0;memory.timestamp=begin
                var imageTree:BackupFileTree?,written:String?,admitted=false
                defer {if !admitted,let written {try? imageTree?.remove(written)}}
                if let data=prepared.1,let lease=prepared.2 {
                    let tree=try BackupFileTree(root:store.root.standardizedFileURL.resolvingSymlinksInPath(),writable:true),identity=try tree.identity()
                    guard identity.device==store.mediaRootIdentity.device,identity.inode==store.mediaRootIdentity.inode else {throw OSwindError.invalid("The library directory changed before screenshot admission")}
                    let relative="images/\(memory.id).jpg";imageTree=tree
                    try lease.withActive(for:store.mediaRootIdentity) {try tree.requireRootIdentity(at:store.root);try tree.write(data,as:relative)}
                    written=relative;memory.imagePath=relative
                }
                // The complete AX check preceded the file write. Only a cheap
                // app identity/session check runs here; no actor suspension or
                // cross-process AX call occurs between file and SQL admission.
                guard snapshotCurrent(token:token,manual:manual),snapshots.identityCurrent(context,targetBundleID) else {return}
                try imageTree?.requireRootIdentity(at:store.root);try store.insert(memory);admitted=true
                fingerprints[frame.display]=pixels;metrics.saved+=1
                let saved=memory,passageStore=store
                var pending:String?
                if settings.search.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled {
                    let indexing=Task.detached(priority:.utility) {try passageStore.indexApplePassages(saved,embedder:localEmbedder)}
                    snapshotPassages=indexing;defer {snapshotPassages=nil}
                    do {try await withTaskCancellationHandler {try await indexing.value} onCancel:{indexing.cancel()}}
                    catch {pending=error.localizedDescription}
                }
                guard epoch==token,!Task.isCancelled else {return}
                metrics.lastLatencyMS=Date().timeIntervalSince(begin)*1000
                if let pending {metrics.errors+=1;status="Saved \(captured.app) · search indexing pending: "+pending}
                else {status="Saved \(captured.app) · \(Int(metrics.lastLatencyMS)) ms"}
                // Automatic catch-up sees completed native passages instead of
                // racing the capture worker to build the same long source.
                onCapture?(memory)
            }
        } catch is CancellationError {if epoch==token {status="Snapshot cancelled"}}
        catch let deferral as SnapshotCaptureDeferral {if epoch==token {metrics.excluded+=1;status=deferral.reason}}
        catch {if epoch==token {metrics.errors+=1;status=error.localizedDescription}}
    }
    nonisolated public static func fingerprint(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 32 * 18)
        pixels.withUnsafeMutableBytes { bytes in if let ctx = CGContext(data: bytes.baseAddress, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) { ctx.interpolationQuality = .low; ctx.draw(image, in: CGRect(x: 0,y: 0,width: 32,height: 18)) } }; return pixels
    }
    nonisolated public static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double { guard a.count == b.count, !a.isEmpty else { return .infinity }; return Double(zip(a,b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count) }
}
