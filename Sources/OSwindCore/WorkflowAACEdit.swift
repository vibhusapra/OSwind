import Foundation
import Darwin

struct WorkflowAACEdit:Codable,Sendable {
    let primingFrames:UInt64
    let trailingFrames:UInt64
    let encodedFrames:UInt64
    /// The configured encoder writes one fixed-rate audio edit. Check its
    /// portable container mapping as well as AVFoundation's decoded waveform:
    /// a native decoder may compensate for priming that other players expose.
    static func inspect(url:URL,frames:Int64,packetFrames:UInt32)throws->Self {
        guard frames>0,frames<=2_880_000,packetFrames>0,packetFrames<=4096 else {throw OSwindError.invalid("Invalid AAC framing proof")}
        let tree=try BackupFileTree(root:url.deletingLastPathComponent()),name=url.lastPathComponent,before=try tree.digest(name,limit:256*1024*1024)
        let result=try tree.withFile(name) {file,stamp in
            let reader=Reader(file:file,size:Int(stamp.bytes))
            let movie=try reader.one("moov",in:0..<reader.size),children=try reader.boxes(movie.payload)
            let clock=try reader.clock(try reader.one("mvhd",in:movie.payload))
            var tracks=[(clock:(scale:UInt64,duration:UInt64),edit:Box)]()
            for track in children where track.kind=="trak" {
                let media=try reader.one("mdia",in:track.payload),handler=try reader.one("hdlr",in:media.payload)
                guard handler.payload.count>=12 else {throw OSwindError.invalid("Invalid workflow media handler")}
                if try reader.string(handler.payload.lowerBound+8,4) != "soun" {continue}
                let edits=try reader.one("edts",in:track.payload),edit=try reader.one("elst",in:edits.payload)
                tracks.append((try reader.clock(try reader.one("mdhd",in:media.payload)),edit))
            }
            guard tracks.count==1,clock.scale>0,tracks[0].clock.scale==24000 else {throw OSwindError.invalid("Workflow AAC needs one explicit 24 kHz media timeline")}
            let audio=tracks[0],box=audio.edit,p=box.payload.lowerBound
            guard box.payload.count>=8,try reader.uint(p+4,4)==1 else {throw OSwindError.invalid("Workflow AAC needs one explicit playback edit")}
            let version=try reader.uint(p,1),duration:UInt64,start:UInt64,rate:UInt64
            if version==0 {
                guard box.payload.count==20 else {throw OSwindError.invalid("Invalid workflow AAC edit size")}
                duration=try reader.uint(p+8,4);start=try reader.uint(p+12,4);rate=try reader.uint(p+16,4)
                guard start<UInt64(Int32.max) else {throw OSwindError.invalid("Empty or negative AAC edits are not supported")}
            } else if version==1 {
                guard box.payload.count==28 else {throw OSwindError.invalid("Invalid workflow AAC edit size")}
                duration=try reader.uint(p+8,8);start=try reader.uint(p+16,8);rate=try reader.uint(p+24,4)
                guard start<UInt64(Int64.max) else {throw OSwindError.invalid("Empty or negative AAC edits are not supported")}
            } else {throw OSwindError.invalid("Unknown workflow AAC edit version")}
            guard rate==65536,abs(Double(duration)/Double(clock.scale)-Double(frames)/24000)<=1.0/24000,
                  start<=audio.clock.duration,UInt64(frames)<=audio.clock.duration-start else {throw OSwindError.invalid("Workflow AAC edit does not cover the measured narration")}
            let trailing=audio.clock.duration-start-UInt64(frames)
            guard trailing<UInt64(packetFrames) else {throw OSwindError.invalid("Workflow AAC edit leaves more than one packet outside the measured narration")}
            return Self(primingFrames:start,trailingFrames:trailing,encodedFrames:audio.clock.duration)
        }
        guard try tree.digest(name,limit:256*1024*1024)==before else {throw OSwindError.unavailable("Workflow movie changed during AAC timeline verification")}
        return result
    }
    private struct Box {let kind:String;let payload:Range<Int>}
    private final class Reader {
        let file:Int32,size:Int
        private var operations=0
        init(file:Int32,size:Int) {self.file=file;self.size=size}
        func data(_ offset:Int,_ count:Int)throws->Data {
            operations+=1;try Task.checkCancellation()
            guard operations<=8192,offset>=0,count>=0,count<=32,offset<=size,count<=size-offset else {throw OSwindError.invalid("Invalid bounded workflow movie metadata")}
            var result=Data(count:count),position=0
            while position<count {
                let n=result.withUnsafeMutableBytes {pread(file,$0.baseAddress!.advanced(by:position),count-position,off_t(offset+position))}
                if n<0 && errno==EINTR {continue}
                guard n>0 else {throw OSwindError.invalid("Workflow movie metadata is truncated")};position+=n
            }
            return result
        }
        func uint(_ offset:Int,_ count:Int)throws->UInt64 {try data(offset,count).reduce(UInt64(0)) {($0<<8)|UInt64($1)}}
        func string(_ offset:Int,_ count:Int)throws->String {String(decoding:try data(offset,count),as:UTF8.self)}
        func boxes(_ range:Range<Int>)throws->[Box] {
            var position=range.lowerBound,result=[Box]()
            while position<range.upperBound {
                guard range.upperBound-position>=8,result.count<1024 else {throw OSwindError.invalid("Invalid workflow movie box boundary")}
                var length=try uint(position,4),header=8
                let kind=try string(position+4,4)
                if length==1 {guard range.upperBound-position>=16 else {throw OSwindError.invalid("Truncated extended movie box")};length=try uint(position+8,8);header=16}
                if length==0 {length=UInt64(range.upperBound-position)}
                guard length>=UInt64(header),length<=UInt64(range.upperBound-position) else {throw OSwindError.invalid("Workflow movie box exceeds its parent")}
                result.append(.init(kind:kind,payload:position+header..<position+Int(length)));position+=Int(length)
            }
            return result
        }
        func one(_ kind:String,in range:Range<Int>)throws->Box {
            let matches=try boxes(range).filter {$0.kind==kind}
            guard matches.count==1 else {throw OSwindError.invalid("Missing or ambiguous workflow movie metadata")};return matches[0]
        }
        func clock(_ box:Box)throws->(scale:UInt64,duration:UInt64) {
            let p=box.payload.lowerBound,version=try uint(p,1)
            if version==0 {guard box.payload.count>=20 else {throw OSwindError.invalid("Truncated movie clock")};return (try uint(p+12,4),try uint(p+16,4))}
            if version==1 {guard box.payload.count>=32 else {throw OSwindError.invalid("Truncated movie clock")};return (try uint(p+20,4),try uint(p+24,8))}
            throw OSwindError.invalid("Unknown workflow movie clock version")
        }
    }
}
