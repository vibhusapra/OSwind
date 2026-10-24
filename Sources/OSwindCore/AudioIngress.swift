import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import Accelerate

/// Each device owns one sink. Callbacks copy into a bounded buffer immediately;
/// they never enqueue one actor task or Dispatch block per PCM callback.
final class AudioAccumulator: @unchecked Sendable {
    static let segmentSamples=480_000
    static let maximumCallbackSamples=32_768
    static let maximumWaitingSegments=3
    struct Segment:Sendable {var samples:[Float];var date:Date}
    struct Report:Sendable {var droppedSamples:Int;var failure:String?}
    struct Snapshot {var partialSamples:Int;var waitingSegments:Int;var deliveryScheduled:Bool;var droppedSamples:Int;var active:Bool}
    private let lock=NSLock()
    private var samples=[Float](),pending=[Segment]()
    private var start:Date?
    private var active=true,scheduled=false
    private var dropped=0,failure:String?
    private let emit:@MainActor @Sendable ([Float],Date)->Void
    private let report:@MainActor @Sendable (Report)->Void
    init(emit:@escaping @MainActor @Sendable ([Float],Date)->Void,report:@escaping @MainActor @Sendable (Report)->Void={_ in}) {self.emit=emit;self.report=report}
    var snapshot:Snapshot {lock.withLock {Snapshot(partialSamples:samples.count,waitingSegments:pending.count,deliveryScheduled:scheduled,droppedSamples:dropped,active:active)}}
    func add(_ input:[Float],at end:Date=Date()) {input.withUnsafeBufferPointer {add($0,at:end)}}
    func add(_ input:UnsafeBufferPointer<Float>,at end:Date=Date()) {
        lock.withLock {
            guard active else {return}
            guard input.count>0,input.count<=Self.maximumCallbackSamples else {failLocked("Audio buffer size changed · start to retry");return}
            if start==nil {start=end.addingTimeInterval(-Double(input.count)/16000)}
            let needed=Self.segmentSamples-samples.count,first=min(needed,input.count)
            samples.append(contentsOf:input.prefix(first))
            if samples.count==Self.segmentSamples {
                let date=start!;let chunk=samples;samples=[];start=nil
                if Self.audible(chunk) {
                    if pending.count<Self.maximumWaitingSegments {pending.append(Segment(samples:chunk,date:date))}
                    else {dropped+=chunk.count}
                    scheduleLocked()
                }
                if first<input.count {samples.append(contentsOf:input.dropFirst(first));start=date.addingTimeInterval(30)}
            }
        }
    }
    static func audible(_ input:[Float])->Bool {
        guard !input.isEmpty else {return false};var rms:Float=0
        input.withUnsafeBufferPointer {vDSP_rmsqv($0.baseAddress!,1,&rms,vDSP_Length(input.count))}
        return rms.isFinite && rms>0.003
    }
    func fail(_ message:String) {lock.withLock {guard active else {return};failLocked(message)}}
    private func failLocked(_ message:String) {active=false;samples.removeAll();start=nil;pending.removeAll();failure=message;scheduleLocked()}
    private func scheduleLocked() {guard !scheduled else {return};scheduled=true;Task {@MainActor [self] in deliver()}}
    @MainActor private func deliver() {
        // No suspension between removal and admission: finish() can synchronously
        // reclaim every segment still waiting for this actor.
        while true {
            let next:(Segment?,Report)=lock.withLock {
                let next=pending.isEmpty ? nil:pending.removeFirst()
                let value=Report(droppedSamples:dropped,failure:failure)
                if next==nil {scheduled=false;failure=nil}
                return (next,value)
            }
            report(next.1)
            guard let segment=next.0 else {return}
            emit(segment.samples,segment.date)
        }
    }
    /// Called on the controller actor. Complete pending segments and the partial
    /// segment transfer synchronously; the scheduled delivery cannot race it.
    @MainActor func finish()->[Segment] {
        lock.withLock {
            active=false;var result=pending;pending.removeAll()
            if !samples.isEmpty,let start {result.append(Segment(samples:samples,date:start))}
            samples.removeAll();start=nil;return result
        }
    }
    func stop() {lock.withLock {active=false;samples.removeAll();pending.removeAll();start=nil;failure=nil}}
}

/// Audio sources can be hidden or live on another Space. The onscreen-window
/// inventory omits those application identities and cannot build their excludes.
enum SystemAudioInventory {
    static func read() async throws ->SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
    }
}

/// A new adapter is retained by each stream. Late callbacks can only reach the
/// old inactive sink; stream object addresses never select a later controller.
final class SystemAudioOutput:NSObject,SCStreamOutput,SCStreamDelegate,@unchecked Sendable {
    let sink:AudioAccumulator
    let queue=DispatchQueue(label:"com.oswind.system-audio",qos:.utility)
    init(sink:AudioAccumulator) {self.sink=sink}
    static func accepts(_ format:AudioStreamBasicDescription)->Bool {
        let allowed=kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        return format.mFormatID==kAudioFormatLinearPCM && format.mSampleRate==16000 && format.mBitsPerChannel==32 && format.mChannelsPerFrame==1 && format.mBytesPerFrame==4 && format.mBytesPerPacket==4 && format.mFramesPerPacket==1 && format.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)==(kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked) && format.mFormatFlags & ~allowed==0
    }
    func stream(_ stream:SCStream,didOutputSampleBuffer sampleBuffer:CMSampleBuffer,of type:SCStreamOutputType) {
        guard type == .audio else {return}
        consume(sampleBuffer)
    }
    func consume(_ sampleBuffer:CMSampleBuffer) {
        guard sampleBuffer.isValid,CMSampleBufferDataIsReady(sampleBuffer),sampleBuffer.numSamples>0,sampleBuffer.numSamples<=AudioAccumulator.maximumCallbackSamples,
              let description=sampleBuffer.formatDescription,let format=CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,Self.accepts(format) else {sink.fail("System audio format changed · start to retry");return}
        var list=AudioBufferList(mNumberBuffers:1,mBuffers:AudioBuffer(mNumberChannels:1,mDataByteSize:0,mData:nil));var block:CMBlockBuffer?
        let result=CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,bufferListSizeNeededOut:nil,bufferListOut:&list,bufferListSize:MemoryLayout<AudioBufferList>.size,blockBufferAllocator:nil,blockBufferMemoryAllocator:nil,flags:UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),blockBufferOut:&block)
        guard result==noErr,list.mNumberBuffers==1,list.mBuffers.mNumberChannels==1,Int(list.mBuffers.mDataByteSize)==sampleBuffer.numSamples*4,let pointer=list.mBuffers.mData else {sink.fail("System audio buffer unavailable · start to retry");return}
        sink.add(UnsafeBufferPointer(start:pointer.assumingMemoryBound(to:Float.self),count:sampleBuffer.numSamples))
        withExtendedLifetime(block) {}
    }
    func stream(_ stream:SCStream,didStopWithError error:Error) {sink.fail("System audio interrupted · start to retry")}
}

/// AVAudioEngine serializes callbacks for a tap. This converter is owned by that
/// tap, with no actor dispatch and no input-buffer retention after consume().
final class MicrophoneAudioInput:@unchecked Sendable {
    let source:AVAudioFormat,target:AVAudioFormat,converter:AVAudioConverter,sink:AudioAccumulator
    init(source:AVAudioFormat,sink:AudioAccumulator) throws {
        guard source.sampleRate.isFinite,source.sampleRate>0,let target=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false),let converter=AVAudioConverter(from:source,to:target) else {throw OSwindError.unavailable("Microphone audio format unavailable")}
        self.source=source;self.target=target;self.converter=converter;self.sink=sink
    }
    func consume(_ buffer:AVAudioPCMBuffer) {
        guard buffer.frameLength>0 else {return}
        let capacity=ceil(Double(buffer.frameLength)*16000/source.sampleRate)+16
        guard buffer.format.isEqual(source),capacity.isFinite,capacity>0,capacity<=Double(AudioAccumulator.maximumCallbackSamples),let output=AVAudioPCMBuffer(pcmFormat:target,frameCapacity:AVAudioFrameCount(capacity)) else {sink.fail("Microphone format changed · start to retry");return}
        var supplied=false,error:NSError?
        let status=converter.convert(to:output,error:&error) {_,status in
            if supplied {status.pointee = .noDataNow;return nil}
            supplied=true;status.pointee = .haveData;return buffer
        }
        guard status != .error,error==nil,let floats=output.floatChannelData?[0] else {sink.fail("Microphone conversion failed · start to retry");return}
        guard output.frameLength>0 else {return}
        sink.add(UnsafeBufferPointer(start:floats,count:Int(output.frameLength)))
    }
}
