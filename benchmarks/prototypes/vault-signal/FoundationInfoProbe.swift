import Foundation
import Darwin
import CryptoKit

final class Bytes:@unchecked Sendable {
    let lock=NSLock();var data=Data(),count=0
    func append(_ value:Data) {lock.lock();defer {lock.unlock()};count+=value.count;if data.count+value.count<=4*1024*1024 {data.append(value)}}
    func snapshot()->(Data,Int) {lock.lock();defer {lock.unlock()};return(data,count)}
}
final class Signals:@unchecked Sendable {
    let lock=NSLock();var count=0
    func add(_ n:Int) {lock.lock();count+=n;lock.unlock()}
    func value()->Int {lock.lock();defer {lock.unlock()};return count}
}
func emit(_ object:[String:Any]) {let data=try! JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data([10]))}
func sha(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
let mode=CommandLine.arguments[1],destination=URL(fileURLWithPath:CommandLine.arguments[2]),signals=Signals()
signal(SIGINT,SIG_IGN)
let source=DispatchSource.makeSignalSource(signal:SIGINT,queue:DispatchQueue(label:"owned-info-signal"));source.setEventHandler {signals.add(Int(source.data))};source.resume()
let process=Process(),input=Pipe(),output=Pipe(),error=Pipe(),out=Bytes(),err=Bytes(),readers=DispatchGroup()
process.executableURL=URL(fileURLWithPath:mode=="info" ? "/usr/bin/hdiutil":"/usr/bin/python3")
process.arguments=mode=="info" ? ["info","-plist"]:["-c","import time;time.sleep(.05)"]
process.standardInput=input;process.standardOutput=output;process.standardError=error
emit(["phase":"beforeLaunch","parentPID":getpid(),"parentGroup":getpgrp(),"parentSession":getsid(0)])
do {
    try process.run()
    let child=process.processIdentifier,childGroup=getpgid(child),childSession=getsid(child)
    try output.fileHandleForWriting.close();try error.fileHandleForWriting.close();try input.fileHandleForWriting.close();try input.fileHandleForReading.close()
    for (handle,buffer) in [(output.fileHandleForReading,out),(error.fileHandleForReading,err)] {
        readers.enter();DispatchQueue.global().async {defer {readers.leave();try? handle.close()};while true {let bytes=handle.readData(ofLength:16384);if bytes.isEmpty {break};buffer.append(bytes)}}
    }
    process.waitUntilExit();readers.wait()
    let (stdout,stdoutCount)=out.snapshot(),(stderr,stderrCount)=err.snapshot()
    let reason=process.terminationReason == .exit ? "exit":"signal"
    if process.terminationStatus != 0 {try stderr.write(to:destination.appendingPathExtension("stderr"),options:.withoutOverwriting)}
    emit(["phase":"completed","mode":mode,"status":process.terminationStatus,"termination":reason,"childPID":child,"childGroup":childGroup,"childSession":childSession,"parentSignalsObserved":signals.value(),"stdoutBytes":stdoutCount,"stdoutSHA256":sha(stdout),"stderrBytes":stderrCount,"stderrSHA256":sha(stderr),"rawInventoryRetained":false])
} catch {emit(["phase":"failedLaunch","errorCode":(error as NSError).code]);exit(1)}
