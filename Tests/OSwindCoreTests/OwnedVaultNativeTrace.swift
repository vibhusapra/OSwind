import Foundation
import Darwin
@testable import OSwindCore

// Shared only by owned native test fixtures. Public vault construction has no observer.
final class OwnedVaultNativeTrace:@unchecked Sendable {
    struct Item:Codable {let stage:String,event:VaultNativeDiagnostic}
    struct Handle:Codable {let descriptor:Int,path:String?,mounted:Bool}
    struct Boundary:Codable {let stage:String,operation:VaultNativeOperation,mountedDevice:Int32?,ownedHandles:[Handle]}
    struct Report:Codable {let stage:String,failureStage:String?,total:Int,nonzero:Int,dropped:Int,events:[Item],beforeMutations:[Boundary]}
    private let lock=NSLock()
    private let root:URL
    private let rootPrefix:String
    private var stage="create",failureStage:String?,items=[Item](),total=0,nonzero=0,dropped=0
    private var boundaries=[Boundary]()
    init(root:URL) {
        let canonical=root.resolvingSymlinksInPath()
        self.root=canonical
        // F_GETPATH uses the kernel spelling, which can differ from Foundation's
        // /var alias even after resolvingSymlinksInPath(). Retain an exact owned
        // prefix in the same spelling; never widen it to the temporary directory.
        let native=realpath(canonical.path,nil)
        let path=native.map {String(cString:$0)} ?? canonical.path
        if let native {free(native)}
        rootPrefix=path.hasSuffix("/") ? path:path+"/"
    }
    func beforeMutation(_ operation:VaultNativeOperation,_ mountedDevice:Int32?) {
        // Inspect this test process's descriptor names only, without reading
        // file contents or retaining unrelated paths. /dev/fd snapshots can
        // race a concurrent close; failed lookups are simply omitted.
        var owned=[Handle]()
        for name in (try? FileManager.default.contentsOfDirectory(atPath:"/dev/fd")) ?? [] {
            guard let descriptor=Int32(name) else {continue}
            var metadata=stat();guard fstat(descriptor,&metadata)==0 else {continue}
            let mounted=mountedDevice.map {$0==metadata.st_dev} ?? false
            var bytes=[CChar](repeating:0,count:Int(MAXPATHLEN))
            let found=bytes.withUnsafeMutableBytes {fcntl(descriptor,F_GETPATH,$0.baseAddress!)}
            let path=found==0 ? String(cString:bytes):nil
            if mounted || path?.hasPrefix(rootPrefix)==true {owned.append(.init(descriptor:Int(descriptor),path:path,mounted:mounted))}
        }
        lock.withLock {if boundaries.count<128 {boundaries.append(.init(stage:stage,operation:operation,mountedDevice:mountedDevice,ownedHandles:owned.sorted {$0.descriptor<$1.descriptor}))}}
    }
    func setStage(_ value:String) {lock.withLock {stage=value}}
    func markFailure() {lock.withLock {failureStage=stage;stage="failure-cleanup"}}
    func append(_ event:VaultNativeDiagnostic) {lock.withLock {total+=1;if event.summary.status != 0 {nonzero+=1};if items.count==512 {items.removeFirst();dropped+=1};items.append(.init(stage:stage,event:event))}}
    func snapshot()->Report {lock.withLock {.init(stage:stage,failureStage:failureStage,total:total,nonzero:nonzero,dropped:dropped,events:items,beforeMutations:boundaries)}}
    static func redactedJSON(_ encoded:Data,roots:[URL],secret:Data)throws->Data {
        guard encoded.range(of:secret)==nil else {throw OSwindError.invalid("Fixture credential appeared in native diagnostic capture")}
        let encoder=JSONEncoder()
        var text=String(decoding:encoded,as:UTF8.self)
        // Match JSON's escaped representation, including /private aliases and
        // quoted/non-ASCII path components. Longer roots must be replaced first.
        var paths:Set<String>=Set(roots.map { $0.path })
        // Foundation may present /var even after resolving a /private/var
        // symlink. F_GETPATH uses the kernel spelling; pin that spelling too.
        for root in roots {
            if let native=realpath(root.path,nil) {
                paths.insert(String(cString:native));free(native)
            }
        }
        let ordered=paths.sorted { (left:String,right:String)->Bool in
            if left.count != right.count {return left.count>right.count}
            return left<right
        }
        for path in ordered {
            let quoted=String(decoding:try encoder.encode(path),as:UTF8.self)
            text=text.replacingOccurrences(of:String(quoted.dropFirst().dropLast()),with:"<owned-fixture>")
        }
        return Data(text.utf8)
    }
    func save(root:URL,secret:Data,failed:Bool)throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let encoded=try encoder.encode(snapshot())
        // Fixture-only observation can contain owned system-tool text. Refuse
        // to print/write any trace containing the generated credential.
        let exported=try Self.redactedJSON(encoded,roots:[root,self.root],secret:secret)
        let text=String(decoding:exported,as:UTF8.self)
        if let destination=ProcessInfo.processInfo.environment["OSWIND_TEST_VAULT_TRACE_DIR"] {
            let directory=URL(fileURLWithPath:destination,isDirectory:true);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try Data(text.utf8).write(to:directory.appendingPathComponent(root.lastPathComponent+(failed ? "-exception":"-completed")+".json"),options:.withoutOverwriting)
        }
        if failed || snapshot().nonzero>0 {print("Owned vault native result trace: "+text)}
        else {let s=snapshot();print("Owned vault native trace: calls=\(s.total) nonzero=\(s.nonzero) dropped=\(s.dropped)")}
    }
}
