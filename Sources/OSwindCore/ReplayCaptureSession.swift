import Foundation
import AppKit
import ScreenCaptureKit
import Vision

/// One focused-window stream, one OCR consumer and one immutable clip writer.
/// CaptureController owns replacement/lock/settings boundaries; no device access
/// occurs until the user's existing capture action starts this session.
@MainActor final class ReplayCaptureSession {
    private let store:MemoryStore,embedder:LocalEmbedder
    private let gate:ReplayCommitGate
    private var retiring=[UUID:Task<Void,Never>]()
    private var lastFlush=Date(),retryAfter=Date.distantPast
    private let onMemory:@MainActor (Memory)->Void
    private let onStatus:@MainActor (String)->Void
    private let onFailure:@MainActor (String)->Void
    private var source:ReplayScreenSource?
    private var recorder:VisualChunkRecorder?
    private var consumer:Task<Void,Never>?
    private var supervisor:Task<Void,Never>?
    private let contextMonitor:ReplayContextMonitor
    private var generation=UUID()
    private var binding=""
    private var boundContext:WindowContext?
    private var currentInterval=0.0
    private var stopped=false
    var settings:AppSettings
    init(store:MemoryStore,embedder:LocalEmbedder,settings:AppSettings,gate:ReplayCommitGate,targetBundleID:String?=nil,onMemory:@escaping @MainActor (Memory)->Void,onStatus:@escaping @MainActor (String)->Void,onFailure:@escaping @MainActor (String)->Void={_ in}) {
        self.store=store;self.embedder=embedder;self.settings=settings;self.gate=gate;self.onMemory=onMemory;self.onStatus=onStatus;self.onFailure=onFailure
        contextMonitor=ReplayContextMonitor(target:targetBundleID)
    }
    func start() {
        supervisor=Task { [weak self] in
            while !Task.isCancelled {
                guard let self,!self.stopped else {return}
                await self.updateBinding()
                do {try await Task.sleep(nanoseconds:500_000_000)} catch {return}
            }
        }
    }
    /// Synchronous invalidation prevents a late OCR result publishing after a
    /// settings/library boundary. Discard is used for library switches/erasure.
    func stop(discard:Bool=false) {
        contextMonitor.cancel()
        stopped=true;generation=UUID();if discard {supervisor?.cancel()};supervisor=nil
        retire(discard:discard)
    }
    private func retire(discard:Bool=false) {
        generation=UUID();binding="";boundContext=nil;if discard {consumer?.cancel()};consumer=nil
        let previousSource=source,previousRecorder=recorder;source=nil;recorder=nil
        let id=UUID(),notifyFailure=onFailure,notifyStatus=onStatus
        retiring[id]=Task { [weak self] in
            defer {self?.retiring[id]=nil}
            await previousSource?.stop()
            do {try await previousRecorder?.close(commit:!discard)} catch {if !discard {notifyFailure(error.localizedDescription);notifyStatus("Replay finalization: "+error.localizedDescription)}}
        }
    }
    func waitUntilStopped() async {for task in Array(retiring.values) {await task.value}}
    private static func key(_ context:WindowContext)->String {ReplayContextMonitor.key(context)}
    private func eligible() async ->WindowContext? {
        guard settings.snapshotRegions.valid,settings.snapshotRegions.focusedWindowCrop==nil,!stopped,!Task.isCancelled else {return nil}
        let result=await contextMonitor.fresh(policy:settings.privacy)
        guard !stopped,!Task.isCancelled,let context=result else {return nil}
        return context
    }
    private func updateBinding() async {
        guard !stopped,!Task.isCancelled,Date()>=retryAfter else {return}
        if Date().timeIntervalSince(lastFlush)>=5 {
            lastFlush=Date()
            do {try await recorder?.flush()} catch {guard !stopped else {return};retire(discard:true);retryAfter=Date().addingTimeInterval(10);onFailure(error.localizedDescription);onStatus("Replay finalization: "+error.localizedDescription);return}
        }
        guard !stopped else {return}
        guard settings.snapshotRegions.valid,settings.snapshotRegions.focusedWindowCrop==nil else {if source != nil {retire(discard:true)};onStatus("Replay paused · invalid capture area");return}
        let interval=settings.profile.replayInterval(lowPower:ProcessInfo.processInfo.isLowPowerModeEnabled,thermalLimited:ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical)
        guard contextMonitor.available else {if source != nil {retire()};onStatus("Replay paused · locked, idle or excluded");return}
        // Frame events own the expensive complete AX observations. The
        // supervisor only checks session/focused-window identity and cadence while
        // this stream is bound. Its next frame is never admitted from a cache.
        if source != nil,await contextMonitor.canKeepBinding(boundContext,intervalUnchanged:currentInterval==interval) {return}
        guard let context=await eligible() else {guard !stopped else {return};if source != nil {retire()};onStatus("Replay paused · locked, idle or excluded");return}
        let key=Self.key(context)
        guard source==nil || binding != key || currentInterval != interval else {return}
        retire();let token=generation;binding=key;currentInterval=interval
        do {
            let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
            guard !stopped,generation==token,let now=await eligible(),Self.key(now)==key else {return}
            guard !stopped,generation==token else {return}
            let candidates=content.windows.filter {$0.owningApplication?.processID==context.pid && $0.windowLayer==0 && $0.frame.width>100 && $0.frame.height>100}
            guard let selected=FocusedWindowBinding.select(candidates.map {CaptureWindowDescriptor(frame:$0.frame,title:$0.title)},context:context) else {onStatus("Replay waiting for an unambiguous focused window");return}
            let window=candidates[selected]
            guard settings.privacy.exclusion(app:context.bundle,title:window.title ?? context.title,url:context.url,isBrowser:context.browser)==nil else {return}
            let source=try ReplayScreenSource(filter:SCContentFilter(desktopIndependentWindow:window),maximumDimension:settings.profile.maxDimension,interval:interval)
            let notify=onMemory
            let writer=VisualChunkRecorder(store:store,embedder:embedder,gate:gate,onMemory:{memory in await notify(memory)})
            self.source=source;recorder=writer
            let policy=settings.privacy,display="window-\(window.windowID)"
            try await source.start()
            guard !stopped,generation==token else {await source.stop();try? await writer.close(commit:false);return}
            // Retain window metadata, not the tree body, for supervision.
            var observed=context;observed.accessibilityText="";observed.url=nil;observed.secure=false;boundContext=observed
            onStatus("Replay · \(interval.formatted()) s · hardware HEVC")
            consumer=Task { [weak self] in
                do {
                    for try await frame in source.frames {
                        try Task.checkCancellation()
                        guard let self,self.generation==token,let before=await self.eligible(),Self.key(before)==key else {break}
                        guard self.generation==token,!self.stopped else {break}
                        let extracted=try await Task.detached(priority:.utility) {
                            try VisualOCR.regions(frame.buffer)
                        }.value
                        try Task.checkCancellation()
                        guard self.generation==token,let after=await self.eligible(),Self.key(after)==key else {break}
                        guard self.generation==token,!self.stopped else {break}
                        let text=extracted.map(\.text).joined(separator:"\n")+(before.accessibilityText.isEmpty ? "":"\n\n"+before.accessibilityText)
                        let input=ReplayFrameInput(buffer:frame.buffer,time:frame.time,capturedAt:frame.capturedAt,app:before.app,bundle:before.bundle,title:before.title,url:before.url,display:display,text:text,regions:extracted,secure:before.secure,browser:before.browser)
                        try await writer.append(input,privacy:policy,interval:interval)
                    }
                    if let self,self.generation==token {self.retire()}
                } catch is CancellationError {} catch {
                    guard let self,self.generation==token else {return};self.retire(discard:true);self.retryAfter=Date().addingTimeInterval(10);self.onFailure(error.localizedDescription);self.onStatus("Replay: "+error.localizedDescription)
                }
            }
        } catch {if generation==token {retire(discard:true);retryAfter=Date().addingTimeInterval(10);onFailure(error.localizedDescription);onStatus("Replay: "+error.localizedDescription)}}
    }
    deinit {consumer?.cancel();supervisor?.cancel()}
}
