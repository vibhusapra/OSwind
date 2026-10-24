import XCTest
import ScreenCaptureKit
import CoreMedia
import AVFoundation
@testable import OSwindCore

private final class ObservedSystemAudio:NSObject,SCStreamOutput,SCStreamDelegate,@unchecked Sendable {
    let production:SystemAudioOutput
    private let lock=NSLock()
    private var count=0,maximum=0,formats=Set<String>(),invalid=0,interrupted=false
    init(sink:AudioAccumulator) {production=SystemAudioOutput(sink:sink)}
    var metrics:[String:Any] {lock.withLock {["callbacks":count,"maximumCallbackSamples":maximum,"formats":formats.sorted(),"invalidFormats":invalid,"interrupted":interrupted]}}
    func stream(_ stream:SCStream,didOutputSampleBuffer buffer:CMSampleBuffer,of type:SCStreamOutputType) {
        guard type == .audio else {return}
        lock.withLock {
            count+=1;maximum=max(maximum,buffer.numSamples)
            if let description=buffer.formatDescription,let format=CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                formats.insert("\(format.mSampleRate) Hz / \(format.mChannelsPerFrame) ch / \(format.mBitsPerChannel) bit / flags \(format.mFormatFlags) / bytes \(format.mBytesPerFrame)")
                if !SystemAudioOutput.accepts(format) {invalid+=1}
            } else {invalid+=1}
        }
        production.stream(stream,didOutputSampleBuffer:buffer,of:type)
    }
    func stream(_ stream:SCStream,didStopWithError error:Error) {
        lock.withLock {interrupted=true};production.stream(stream,didStopWithError:error)
    }
}

@MainActor final class NativeSystemAudioTests:XCTestCase {
    private struct Source {var bundle:String;var pid:pid_t;var control:URL;var frequency:Double}
    private func source(_ name:String,environment:[String:String],root:URL)throws->Source {
        let bundle=try XCTUnwrap(environment["OSWIND_AUDIO_SOURCE_"+name+"_BUNDLE"]),pid=try XCTUnwrap(environment["OSWIND_AUDIO_SOURCE_"+name+"_PID"].flatMap(Int32.init))
        guard bundle.hasPrefix("com.oswind.fixture.audio."),pid>0 else {throw OSwindError.invalid("Use an owned audio fixture")}
        return Source(bundle:bundle,pid:pid,control:root.appendingPathComponent(name+".play"),frequency:name=="A" ? 440:997)
    }
    private func amplitude(_ samples:[Float],frequency:Double)->Double {
        // Test-only projection on generated tones; not a general audio scorer.
        let values=Array(samples.suffix(16000));guard !values.isEmpty else {return 0}
        var real=0.0,imaginary=0.0
        for (i,value) in values.enumerated() {let phase=2*Double.pi*frequency*Double(i)/16000;real+=Double(value)*cos(phase);imaginary+=Double(value)*sin(phase)}
        return 2*hypot(real,imaginary)/Double(values.count)
    }
    func testOwnedSourcesProduceNativePCMAndRemainIsolatedThroughProductionDecoder() async throws {
        let environment=ProcessInfo.processInfo.environment
        guard environment["OSWIND_TEST_NATIVE_SYSTEM_AUDIO"]=="1" else {throw XCTSkip("Explicit owned system-audio fixtures; no microphone access")}
        guard !SessionState.locked,CGPreflightScreenCaptureAccess() else {throw XCTSkip("Requires existing capture access and unlocked session; never requests permission")}
        let root=URL(fileURLWithPath:try XCTUnwrap(environment["OSWIND_AUDIO_PROBE_ROOT"])),a=try source("A",environment:environment,root:root),b=try source("B",environment:environment,root:root)
        guard a.bundle != b.bundle,a.pid != b.pid else {throw OSwindError.invalid("Separate owned sources are required")}
        let sources=[a,b];defer {for source in sources {try? FileManager.default.removeItem(at:source.control)}}
        let content=try await SystemAudioInventory.read()
        let onScreenOnly=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
        let display=try XCTUnwrap(content.displays.first)
        let ownedApps=content.applications.filter {app in sources.contains {$0.pid==app.processID || $0.bundle==app.bundleIdentifier}}
        let ownWindows=content.windows.filter {$0.title=="OSwind owned audio fixture"}.map {["ownerPID":$0.owningApplication?.processID ?? -1,"bundle":$0.owningApplication?.bundleIdentifier ?? "none","onScreen":$0.isOnScreen] as [String:Any]}
        let identity:[String:Any]=["displayCount":content.displays.count,"applicationCount":content.applications.count,"windowCount":content.windows.count,"fixtureWindowDiscoveryOnScreenOnly":false,"matchedApplications":ownedApps.map {["bundle":$0.bundleIdentifier,"pid":$0.processID]},"ownedWindowMetadata":ownWindows]
        try JSONSerialization.data(withJSONObject:identity,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("owned-source-identity.json"))
        let applications=try sources.map {source in try XCTUnwrap(content.applications.first {$0.bundleIdentifier==source.bundle && $0.processID==source.pid})}
        var observations=[[String:Any]]()
        for (index,source) in sources.enumerated() {
            var failure:String?
            let sink=AudioAccumulator(emit:{_,_ in XCTFail("Only a short partial recording is requested")},report:{failure=$0.failure})
            let observer=ObservedSystemAudio(sink:sink)
            // Include only one owned source. The other fixture plays at the same
            // time to verify isolation; user apps are never included.
            let filter=SCContentFilter(display:display,including:[applications[index]],exceptingWindows:[])
            let config=SCStreamConfiguration();config.capturesAudio=true;config.excludesCurrentProcessAudio=true;config.sampleRate=16000;config.channelCount=1;config.width=2;config.height=2;config.minimumFrameInterval=CMTime(seconds:1,preferredTimescale:1)
            let stream=SCStream(filter:filter,configuration:config,delegate:observer)
            try stream.addStreamOutput(observer,type:.audio,sampleHandlerQueue:observer.production.queue)
            for source in sources {try Data().write(to:source.control)}
            do {
                try await stream.startCapture()
                let deadline=ContinuousClock.now.advanced(by:.seconds(6))
                while sink.snapshot.partialSamples<48000,sink.snapshot.active,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(50))}
                try await stream.stopCapture()
            } catch {try? await stream.stopCapture();sink.stop();throw error}
            for source in sources {try? FileManager.default.removeItem(at:source.control)}
            let segments=sink.finish(),samples=segments.flatMap(\.samples)
            let intended=amplitude(samples,frequency:source.frequency),other=amplitude(samples,frequency:sources[1-index].frequency)
            let metrics=observer.metrics,pass=samples.count>=32000 && failure==nil && intended>0.003 && intended>other*20 && (metrics["invalidFormats"] as? Int)==0 && (metrics["interrupted"] as? Bool)==false
            observations.append(["source":index==0 ? "A":"B","sourceIdentityVerified":true,"sourcePresentInOnscreenOnlyInventory":onScreenOnly.applications.contains {$0.bundleIdentifier==source.bundle && $0.processID==source.pid},"samples":samples.count,"intendedFrequencyHz":source.frequency,"intendedAmplitude":intended,"otherOwnedSourceAmplitude":other,"intendedToOtherAmplitudeRatio":intended/max(other,1e-12),"adapterFailure":failure as Any? ?? NSNull(),"stream":metrics,"passed":pass])
            try JSONSerialization.data(withJSONObject:["format":"OSwind owned native system-audio observations v1","scope":"Two generated tone apps launched through LaunchServices; requested include-only source filter and production inventory/PCM decoder/sink. Known-other-tone isolation only; no general user-audio exclusion, microphone, recognition, controller privacy, device recovery, energy or competitor claim.","observations":observations],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("observations.json"))
            XCTAssertTrue(pass,"Owned source \(index) did not pass real PCM/isolation checks; inspect private aggregate report")
        }
    }
}
