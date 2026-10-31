import XCTest
import Foundation
import CryptoKit
import CSQLite
import USearchC
import Darwin
@testable import OSwindCore

struct OwnedIndexedObservation:Codable {
    let scope:SearchFilter
    let exact:[String]
    let indexed:[String]
    let strategy:String
}
/// Opt-in diagnostics for this one authored fixture. Does not alter assertions,
/// source rows, native options or the live index. Never scans a temp directory.
enum OwnedIndexedRetrievalProbe {
    static let kind="OSwind authored indexed retrieval probe v1"
    private struct Marker:Codable {let kind:String;let nonce:String;let uid:UInt32}
    private struct VectorRow {let id:String;let key:UInt64;let vector:[Float]}
    private struct Member:Codable {
        let key:UInt64,id:String,present:Bool,fetched:Int,nonfinite:Int
        let maximumError:Double?
        let nativeBits:[UInt32]
    }
    private struct Reachability:Codable {let fromKey:UInt64;let found:Int;let missing:[UInt64]}
    private struct Live:Codable {let sequence:Int64,count:Int,format:String;let keys200:[UInt64],keys2000:[UInt64];let reachability:[Reachability]}
    private struct Report:Codable {
        let kind:String,nonce:String,state:String,sourceFramesSHA256:String,databaseSHA256:String,liveGraphSHA256:String
        let sourceRows:Int,query:[Float],observations:[OwnedIndexedObservation],live:Live
        let loadedKeys200:[UInt64],loadedKeys2000:[UInt64],loadedCount:Int,loadedExpansion:Int,members:[Member]
    }
    private static func sha(_ url:URL)throws->String {SHA256.hash(data:try Data(contentsOf:url)).map {String(format:"%02x",$0)}.joined()}
    private static func context()throws->(URL,Marker)? {
        guard let value=ProcessInfo.processInfo.environment["OSWIND_TEST_INDEXED_RETRIEVAL_OUTPUT"] else {return nil}
        let parent=URL(fileURLWithPath:value,isDirectory:true)
        guard parent.path==value,parent.standardizedFileURL.path==value,parent.resolvingSymlinksInPath().path==value else {throw OSwindError.invalid("Probe parent must be an absolute nonsymlink directory")}
        let attributes=try FileManager.default.attributesOfItem(atPath:parent.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,(attributes[.ownerAccountID] as? NSNumber)?.uint32Value==getuid(),(attributes[.posixPermissions] as? NSNumber)?.intValue==0o700 else {throw OSwindError.invalid("Probe parent ownership differs")}
        let markerURL=parent.appendingPathComponent("owned-probe.json"),markerAttributes=try FileManager.default.attributesOfItem(atPath:markerURL.path)
        guard markerAttributes[.type] as? FileAttributeType == .typeRegular,(markerAttributes[.size] as? NSNumber)?.intValue ?? 4097 <= 4096 else {throw OSwindError.invalid("Probe marker differs")}
        let marker=try JSONDecoder().decode(Marker.self,from:Data(contentsOf:markerURL));try SyncProtocolLimits.uuid(marker.nonce)
        guard marker.kind==kind,marker.uid==getuid() else {throw OSwindError.invalid("Probe marker scope differs")}
        return (parent,marker)
    }
    static func outputDirectory(prefix:String)throws->URL? {
        guard prefix=="native-build-" || prefix=="native-control-" else {throw OSwindError.invalid("Invalid owned probe prefix")}
        guard let (parent,_)=try context() else {return nil}
        let output=parent.appendingPathComponent(prefix+UUID().uuidString.lowercased(),isDirectory:true)
        guard !FileManager.default.fileExists(atPath:output.path) else {throw OSwindError.invalid("Probe output exists")};try Paths.ensure(output);return output
    }
    static func capture(store:MemoryStore,root:URL,observations:[OwnedIndexedObservation])throws {
        guard let (parent,marker)=try context() else {return}
        var vectors=[VectorRow](),frames=SHA256()
        try store.withRoutineDatabase {db in
            let s=try db.statement("SELECT m.id,m.timestamp,m.kind,m.app,m.title,m.url,m.text,m.favorite,m.payload,m.embedding,m.embedding_model,r.key,oswind_sync_row_v1(m.id,m.timestamp,m.kind,m.app,m.title,m.url,m.text,m.favorite,m.payload,m.embedding,m.embedding_model) FROM memories m JOIN vector_keys r ON r.memory_id=m.id AND r.model='fixture' AND r.ordinal=0 ORDER BY r.key");defer {sqlite3_finalize(s)}
            var code=sqlite3_step(s),seen=Set<Int>()
            while code==SQLITE_ROW {
                let id=db.text(s,0);guard id.hasPrefix("row-"),let i=Int(id.dropFirst(4)),(0..<256).contains(i),id=="row-\(i)",seen.insert(i).inserted,sqlite3_column_double(s,1)==Double(i),db.text(s,2)==(i%2==0 ? "note":"audio"),db.text(s,3)==(i%4==0 ? "A":"B"),db.text(s,4).isEmpty,sqlite3_column_type(s,5)==SQLITE_NULL,db.text(s,6)=="Fixture \(i)",sqlite3_column_int(s,7)==(i%3==0 ? 1:0),db.text(s,10)=="fixture",sqlite3_column_bytes(s,9)==128,let p=sqlite3_column_blob(s,9),let payload=sqlite3_column_blob(s,8),let frame=sqlite3_column_blob(s,12),sqlite3_column_int64(s,11)>0 else {throw OSwindError.invalid("Probe refuses nonfixture source rows")}
                let expected=VectorScalingEvaluation.vector(row:i,dimensions:32),raw=Data(bytes:p,count:128)
                guard expected.withUnsafeBytes({Data($0)})==raw else {throw OSwindError.invalid("Probe vector differs from authored generator")}
                let memory=try JSONDecoder().decode(Memory.self,from:Data(bytes:payload,count:Int(sqlite3_column_bytes(s,8))))
                guard memory.id==id,memory.timestamp.timeIntervalSince1970==Double(i),memory.kind.rawValue==(i%2==0 ? "note":"audio"),memory.app==(i%4==0 ? "A":"B"),memory.title.isEmpty,memory.url==nil,memory.text=="Fixture \(i)",memory.favorite==(i%3==0),memory.tags==(i%5==0 ? ["work"]:[]),memory.embedding==nil,memory.embeddingModel=="fixture",memory.imagePath==nil,memory.audioPath==nil,memory.videoPath==nil,memory.transcript==nil,memory.recap==nil,memory.textObservation==nil,memory.audioSessionID==nil,memory.bundleID.isEmpty,memory.regions.isEmpty,memory.endTimestamp==nil,memory.display==nil,memory.searchPreview==nil else {throw OSwindError.invalid("Probe source is not the authored fixture")}
                let bytes=Data(bytes:frame,count:Int(sqlite3_column_bytes(s,12)));var length=UInt64(bytes.count).littleEndian
                withUnsafeBytes(of:&length) {frames.update(data:Data($0))};frames.update(data:bytes)
                vectors.append(.init(id:id,key:UInt64(sqlite3_column_int64(s,11)),vector:expected));code=sqlite3_step(s)
            }
            guard code==SQLITE_DONE,seen.count==256 else {throw OSwindError.invalid("Probe requires the complete 256-row fixture")}
            let count=try db.statement("SELECT COUNT(*) FROM memories");defer {sqlite3_finalize(count)};guard sqlite3_step(count)==SQLITE_ROW,sqlite3_column_int64(count,0)==256 else {throw OSwindError.invalid("Probe refuses additional source rows")}
        }
        let destination=parent.appendingPathComponent(UUID().uuidString.lowercased(),isDirectory:true)
        guard !FileManager.default.fileExists(atPath:destination.path) else {throw OSwindError.invalid("Probe destination exists")};try Paths.ensure(destination)
        let database=destination.appendingPathComponent("memory.sqlite"),snapshot=try BackupDatabase(database,createPrivate:true)
        try store.withRoutineDatabase {db in
            guard let backup=sqlite3_backup_init(snapshot.handle,"main",db.handle,"main") else {throw db.error()}
            let status=sqlite3_backup_step(backup,-1),finish=sqlite3_backup_finish(backup)
            guard status==SQLITE_DONE,finish==SQLITE_OK else {throw db.error()}
        };snapshot.close()
        let query=VectorScalingEvaluation.vector(row:42,dimensions:32),graph=destination.appendingPathComponent("live.usearch")
        guard let cache=Mirror(reflecting:store).children.first(where:{$0.label=="annCache"})?.value as? ANNCache else {throw OSwindError.invalid("Owned fixture cache reflection unavailable")}
        let reader=try VectorIndexSource(root:root,modelID:"fixture",dimensions:32),state=try reader.state();let all=Set(vectors.map(\.key))
        guard let live=try cache.withReady(modelID:"fixture",dimensions:32,identity:state.identity,snapshotHead:state.head,{native,sequence in
            guard native is NativeANN else {throw OSwindError.invalid("Probe expects the native HNSW backend")}
            let first=try native.search(query,count:200),complete=try native.search(query,count:2000)
            var reachability=[Reachability]()
            for row in vectors {let keys=try native.search(row.vector,count:2000);reachability.append(.init(fromKey:row.key,found:keys.count,missing:all.subtracting(keys).sorted()))}
            try native.save(graph)
            return Live(sequence:sequence,count:try native.count,format:native.indexFormat,keys200:first,keys2000:complete,reachability:reachability)
        }) else {throw OSwindError.invalid("Owned fixture index is not ready")}
        let loaded=try NativeANN(dimensions:32);try loaded.load(graph)
        var options=usearch_init_options_t(metric_kind:usearch_metric_cos_k,metric:nil,quantization:usearch_scalar_f16_k,dimensions:32,connectivity:32,expansion_add:128,expansion_search:8192,multi:false),error:usearch_error_t?
        guard let handle=usearch_init(&options,&error),error==nil else {throw OSwindError.invalid("Cannot open probe graph reader")};defer {var e:usearch_error_t?;usearch_free(handle,&e)}
        graph.path.withCString {usearch_load(handle,$0,&error)};guard error==nil,usearch_dimensions(handle,&error)==32,error==nil else {throw OSwindError.invalid("Probe graph reader dimensions differ")}
        let expansion=Int(usearch_expansion_search(handle,&error));guard error==nil else {throw OSwindError.invalid("Cannot read probe graph expansion")}
        var members=[Member]()
        for row in vectors {
            let present=usearch_contains(handle,row.key,&error);guard error==nil else {throw OSwindError.invalid("Cannot inspect probe graph membership")}
            var values=[Float](repeating:0,count:32)
            let fetched=values.withUnsafeMutableBufferPointer {usearch_get(handle,row.key,1,$0.baseAddress,usearch_scalar_f32_k,&error)};guard error==nil else {throw OSwindError.invalid("Cannot inspect probe graph vector")}
            let finite=values.allSatisfy(\.isFinite),normalized=LocalEmbedder.normalized(row.vector)
            let deviation=finite && fetched==1 ? zip(values,normalized).map {abs(Double($0)-Double($1))}.max():nil
            members.append(.init(key:row.key,id:row.id,present:present,fetched:Int(fetched),nonfinite:values.filter {!$0.isFinite}.count,maximumError:deviation,nativeBits:values.map(\.bitPattern)))
        }
        let report=Report(kind:kind,nonce:marker.nonce,state:"completed",sourceFramesSHA256:frames.finalize().map {String(format:"%02x",$0)}.joined(),databaseSHA256:try sha(database),liveGraphSHA256:try sha(graph),sourceRows:256,query:query,observations:observations,live:live,loadedKeys200:try loaded.search(query,count:200),loadedKeys2000:try loaded.search(query,count:2000),loadedCount:try loaded.count,loadedExpansion:expansion,members:members)
        try SyncProtocolLimits.encode(report).write(to:destination.appendingPathComponent("probe.json"),options:.atomic)
        print("OWNED_INDEXED_PROBE completed=\(destination.lastPathComponent) mismatches=\(observations.filter {$0.exact != $0.indexed}.count)")
    }
}
