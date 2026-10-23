import Foundation
import AVFoundation

/// Decode/resample in bounded buffers. The original import remains available for
/// optional retention; ASR gets a separate 16 kHz mono PCM WAV.
enum AudioNormalization {
    static func convert(_ source: URL, to tree: BackupFileTree, as member: String) throws -> Double {
        let input=try AVAudioFile(forReading:source), format=input.processingFormat
        guard format.sampleRate.isFinite,format.sampleRate>0,input.length>0,Double(input.length)/format.sampleRate<=86400,
              let target=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false),
              let converter=AVAudioConverter(from:format,to:target),let sourceBuffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:8192),let output=AVAudioPCMBuffer(pcmFormat:target,frameCapacity:8192) else { throw OSwindError.invalid("Unsupported, empty or longer-than-24-hour audio file") }
        return try tree.withNewFile(member) { descriptor in
            let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:false)
            try handle.write(contentsOf:WAV.data(samples:[]))
            var ended=false, frames: UInt64=0, idle=0
            while true {
                try Task.checkCancellation(); var failure: Error?, conversion: NSError?
                let before=input.framePosition
                let status=converter.convert(to:output,error:&conversion) { requested,state in
                    if ended || input.framePosition>=input.length { ended=true; state.pointee = .endOfStream; return nil }
                    do {
                        try input.read(into:sourceBuffer,frameCount:min(sourceBuffer.frameCapacity,max(1,requested)))
                        if sourceBuffer.frameLength==0 { ended=true; state.pointee = .endOfStream; return nil }
                        state.pointee = .haveData; return sourceBuffer
                    } catch { failure=error; ended=true; state.pointee = .endOfStream; return nil }
                }
                if let failure { throw failure }; if let conversion { throw conversion }
                if output.frameLength>0 {
                    guard let samples=output.floatChannelData?[0] else { throw OSwindError.invalid("Missing decoded audio samples") }
                    let count=Int(output.frameLength); frames+=UInt64(count)
                    guard frames<=86400*16000 else { throw OSwindError.invalid("Audio exceeds 24 hours") }
                    let pcm=WAV.data(samples:Array(UnsafeBufferPointer(start:samples,count:count)))
                    try handle.write(contentsOf:Data(pcm.dropFirst(44)))
                }
                if status == .endOfStream { break }
                guard status != .error else { throw OSwindError.invalid("Audio conversion failed") }
                if output.frameLength==0 && input.framePosition==before { idle+=1; guard idle<8 else { throw OSwindError.invalid("Audio decoder made no progress") } } else { idle=0 }
            }
            guard frames>0 else { throw OSwindError.invalid("No decoded audio samples") }
            var header=WAV.data(samples:[]), size=UInt32(frames*2).littleEndian, riff=UInt32(frames*2+36).littleEndian
            withUnsafeBytes(of:&riff) { header.replaceSubrange(4..<8,with:$0) }; withUnsafeBytes(of:&size) { header.replaceSubrange(40..<44,with:$0) }
            try handle.seek(toOffset:0); try handle.write(contentsOf:header)
            return Double(frames)/16000
        }
    }
}
