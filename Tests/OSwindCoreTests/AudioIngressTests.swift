import XCTest
import AVFoundation
import CoreMedia
@testable import OSwindCore

@MainActor final class AudioIngressTests:XCTestCase {
    private func wait(_ condition:()->Bool) async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(5))
        while !condition(),ContinuousClock.now<end {try await Task.sleep(for:.milliseconds(2))};XCTAssertTrue(condition())
    }
    private func feed(_ sink:AudioAccumulator,count:Int,value:Float=0.05,end:Date=Date()) {
        var left=count
        while left>0 {let size=min(left,AudioAccumulator.maximumCallbackSamples);sink.add(Array(repeating:value,count:size),at:end.addingTimeInterval(-Double(left-size)/16000));left-=size}
    }
    func testStalledActorHasOneDeliveryAndThreeWaitingSegmentsWithAccountedDrops() async throws {
        var emitted=[Int](),reports=[AudioAccumulator.Report]()
        let sink=AudioAccumulator(emit:{samples,_ in emitted.append(samples.count)},report:{reports.append($0)})
        feed(sink,count:AudioAccumulator.segmentSamples*30)
        let state=sink.snapshot
        XCTAssertEqual(state.waitingSegments,3);XCTAssertEqual(state.partialSamples,0);XCTAssertTrue(state.deliveryScheduled)
        XCTAssertEqual(state.droppedSamples,27*480000);XCTAssertTrue(emitted.isEmpty)
        try await wait {!sink.snapshot.deliveryScheduled}
        XCTAssertEqual(emitted,[480000,480000,480000]);XCTAssertEqual(reports.last?.droppedSamples,27*480000)
        sink.stop()
    }
    func testFinishSynchronouslyReclaimsQueuedAndPartialWithoutDuplicateDelivery() async throws {
        var emitted=0
        let sink=AudioAccumulator(emit:{_,_ in emitted+=1})
        let end=Date(timeIntervalSince1970:2_000_000_000)
        feed(sink,count:480000*2+16000,end:end)
        let result=sink.finish()
        XCTAssertEqual(result.map {$0.samples.count},[480000,480000,16000])
        XCTAssertEqual(result[0].date.timeIntervalSince1970,end.timeIntervalSince1970-61,accuracy:0.001)
        XCTAssertEqual(result[1].date.timeIntervalSince(result[0].date),30,accuracy:0.001)
        XCTAssertEqual(result[2].date.timeIntervalSince(result[1].date),30,accuracy:0.001)
        sink.add([0.5]);try await wait {!sink.snapshot.deliveryScheduled};XCTAssertEqual(emitted,0);XCTAssertFalse(sink.snapshot.active)
    }
    func testStopDropsQueuedWorkAndLateCallbacksWithoutASecondDelivery() async throws {
        var emitted=0
        let sink=AudioAccumulator(emit:{_,_ in emitted+=1})
        feed(sink,count:480000);sink.stop();feed(sink,count:480000)
        try await wait {!sink.snapshot.deliveryScheduled}
        XCTAssertEqual(emitted,0);XCTAssertEqual(sink.snapshot.waitingSegments,0);XCTAssertEqual(sink.snapshot.partialSamples,0)
    }
    func testOversizeCallbackFailsBeforeAppendingAndDiscardsQueuedSegments() async throws {
        var emitted=0,reports=[AudioAccumulator.Report]()
        let sink=AudioAccumulator(emit:{_,_ in emitted+=1},report:{reports.append($0)})
        feed(sink,count:480000);sink.add(Array(repeating:0.1,count:AudioAccumulator.maximumCallbackSamples+1))
        XCTAssertFalse(sink.snapshot.active);XCTAssertEqual(sink.snapshot.partialSamples,0);XCTAssertEqual(sink.snapshot.waitingSegments,0)
        try await wait {!sink.snapshot.deliveryScheduled}
        XCTAssertEqual(emitted,0);XCTAssertTrue(reports.last?.failure?.contains("buffer size") == true)
    }
    func testConcurrentCallbacksHaveBoundedStorageAndExactAcceptedSampleAccounting() async throws {
        let sink=AudioAccumulator(emit:{_,_ in XCTFail("Actor deliberately stalled until finish")})
        let input=Array(repeating:Float(0.05),count:1000)
        DispatchQueue.concurrentPerform(iterations:1000) {_ in sink.add(input)}
        XCTAssertEqual(sink.snapshot.waitingSegments,2);XCTAssertEqual(sink.snapshot.partialSamples,40000);XCTAssertEqual(sink.snapshot.droppedSamples,0)
        let result=sink.finish();XCTAssertEqual(result.reduce(0) {$0+$1.samples.count},1000000)
        try await wait {!sink.snapshot.deliveryScheduled}
    }
    func testSilenceDoesNotFillDeliveryMailbox() {
        let sink=AudioAccumulator(emit:{_,_ in XCTFail("Silence")})
        feed(sink,count:480000*4,value:0)
        XCTAssertEqual(sink.snapshot.waitingSegments,0);XCTAssertEqual(sink.snapshot.partialSamples,0);XCTAssertFalse(sink.snapshot.deliveryScheduled);sink.stop()
    }
    nonisolated private static func format()->AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate:16000,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,mBytesPerPacket:4,mFramesPerPacket:1,mBytesPerFrame:4,mChannelsPerFrame:1,mBitsPerChannel:32,mReserved:0)
    }
    func testSystemFormatRequiresExactRateFloatPackingMonoAndPacketLayout() {
        let good=Self.format();XCTAssertTrue(SystemAudioOutput.accepts(good))
        var planar=good;planar.mFormatFlags |= kAudioFormatFlagIsNonInterleaved;XCTAssertTrue(SystemAudioOutput.accepts(planar))
        for mutation in 0..<11 {
            var bad=good
            switch mutation {
            case 0:bad.mSampleRate=48000
            case 1:bad.mSampleRate = .nan
            case 2:bad.mChannelsPerFrame=2
            case 3:bad.mBitsPerChannel=16
            case 4:bad.mFormatFlags=kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
            case 5:bad.mFormatFlags &= ~kAudioFormatFlagIsPacked
            case 6:bad.mFormatFlags |= kAudioFormatFlagIsBigEndian
            case 7:bad.mFormatFlags |= kAudioFormatFlagIsAlignedHigh
            case 8:bad.mBytesPerFrame=8
            case 9:bad.mBytesPerPacket=8
            default:bad.mFramesPerPacket=2
            }
            XCTAssertFalse(SystemAudioOutput.accepts(bad),"mutation \(mutation)")
        }
    }
    private func buffer(frames:Int,rate:Double=16000)->CMSampleBuffer {
        var asbd=Self.format();asbd.mSampleRate=rate;var format:CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:&asbd,layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&format),noErr)
        var block:CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:frames*4,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:frames*4,flags:0,blockBufferOut:&block),noErr)
        let samples=Array(repeating:Float(0.05),count:frames)
        samples.withUnsafeBytes {XCTAssertEqual(CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:block!,offsetIntoDestination:0,dataLength:$0.count),noErr)}
        var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:Int32(rate)),presentationTimeStamp:.zero,decodeTimeStamp:.invalid),size=4,result:CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:block!,formatDescription:format!,sampleCount:frames,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:1,sampleSizeArray:&size,sampleBufferOut:&result),noErr)
        return result!
    }
    func testActualCoreMediaBufferIsCopiedIntoOwnedSinkAndOldAdapterCannotReachReplacement() async throws {
        let old=AudioAccumulator(emit:{_,_ in XCTFail("Stopped old source")}),fresh=AudioAccumulator(emit:{_,_ in XCTFail("Finishing synchronously")})
        let oldOutput=SystemAudioOutput(sink:old),newOutput=SystemAudioOutput(sink:fresh),data=buffer(frames:16000)
        old.stop();oldOutput.consume(data);newOutput.consume(data)
        XCTAssertEqual(old.snapshot.partialSamples,0);let partial=fresh.finish()
        XCTAssertEqual(partial.count,1);XCTAssertEqual(partial.first?.samples.count,16000);XCTAssertEqual(partial[0].samples[0],0.05,accuracy:0.0001)
    }
    func testActualCoreMediaWrongRateAndOversizedBuffersFailClosed() async throws {
        for data in [buffer(frames:16000,rate:48000),buffer(frames:AudioAccumulator.maximumCallbackSamples+1)] {
            var reason:String?
            let sink=AudioAccumulator(emit:{_,_ in XCTFail("Invalid format")},report:{reason=$0.failure})
            SystemAudioOutput(sink:sink).consume(data)
            XCTAssertFalse(sink.snapshot.active);XCTAssertEqual(sink.snapshot.partialSamples,0)
            try await wait {!sink.snapshot.deliveryScheduled};XCTAssertTrue(reason?.contains("format changed") == true)
        }
    }
    func testRealDeviceFreeMicrophoneConversionResamplesAndDownmixes() throws {
        for rate in [44100.0,48000.0] {
            let sink=AudioAccumulator(emit:{_,_ in XCTFail("Partial buffer only")})
            let format=try XCTUnwrap(AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:rate,channels:2,interleaved:false))
            let converter=try MicrophoneAudioInput(source:format,sink:sink)
            let input=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096));input.frameLength=4096
            for channel in 0..<2 {for i in 0..<4096 {input.floatChannelData![channel][i]=0.05}}
            for _ in 0..<10 {converter.consume(input)}
            let output=sink.finish();let count=output.reduce(0) {$0+$1.samples.count}
            XCTAssertTrue(sink.snapshot.active==false);XCTAssertEqual(output.count,1)
            XCTAssertEqual(Double(count),40960*16000/rate,accuracy:100)
            XCTAssertTrue(AudioAccumulator.audible(output[0].samples));XCTAssertLessThanOrEqual(output[0].samples.map {abs($0)}.max() ?? 1,0.11)
        }
    }
    func testMicrophoneFormatChangeAndOversizedBufferFailBeforeAdmission() async throws {
        let format=try XCTUnwrap(AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false))
        let changed=try XCTUnwrap(AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48000,channels:1,interleaved:false))
        for (inputFormat,count) in [(changed,4096),(format,AudioAccumulator.maximumCallbackSamples+1)] {
            var reason:String?
            let sink=AudioAccumulator(emit:{_,_ in XCTFail("Bad microphone buffer")},report:{reason=$0.failure})
            let converter=try MicrophoneAudioInput(source:format,sink:sink)
            let input=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:inputFormat,frameCapacity:AVAudioFrameCount(count)));input.frameLength=AVAudioFrameCount(count)
            converter.consume(input);XCTAssertEqual(sink.snapshot.partialSamples,0);XCTAssertFalse(sink.snapshot.active)
            try await wait {!sink.snapshot.deliveryScheduled};XCTAssertTrue(reason?.contains("format changed") == true)
        }
    }
    func testAppFilterUsesTheSameCaseInsensitiveRuleAsForegroundPrivacy() {
        var policy=PrivacyPolicy();policy.excludedApps=["ORG.FIXTURE.Secret"]
        for id in ["org.fixture.secret","Org.Fixture.Secret","ORG.FIXTURE.SECRET"] {
            XCTAssertTrue(policy.excludesApplication(id));XCTAssertEqual(policy.exclusion(app:id,title:"",url:nil),"Excluded application")
        }
        XCTAssertFalse(policy.excludesApplication("org.fixture.secret.helper"))
    }
}
