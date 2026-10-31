import XCTest
import Foundation
import CryptoKit
import CSQLite
@testable import OSwindCore

final class NativeANNIntegrityTests:XCTestCase {
    private struct Build:Codable {let workers:Int,count:Int,found:Int,missing:[UInt64],graph:String,sha256:String}
    func testNativeEnumerationWithBudgetAboveCorpusKeepsEveryAuthoredMember()throws {
        let rows=(0..<256).map {IndexedVector(key:UInt64($0+1),revision:Int64($0+1),vector:VectorScalingEvaluation.vector(row:$0,dimensions:32),parentKey:UInt64($0+1))},expected=Set(rows.map(\.key)),query=VectorScalingEvaluation.vector(row:42,dimensions:32)
        var builds=[Build]();let output=try OwnedIndexedRetrievalProbe.outputDirectory(prefix:"native-control-")
        for workers in [1,2,4] {
            let native=try NativeANN(dimensions:32);try native.reserve(768);try native.addBatch(rows,threads:workers)
            let keys=try native.search(query,count:2000);var digest="",name=""
            if let output {
                name="workers-\(workers).usearch";let file=output.appendingPathComponent(name);try native.save(file);digest=SHA256.hash(data:try Data(contentsOf:file)).map {String(format:"%02x",$0)}.joined()
            }
            builds.append(.init(workers:workers,count:try native.count,found:keys.count,missing:expected.subtracting(keys).sorted(),graph:name,sha256:digest))
            if let output {try SyncProtocolLimits.encode(builds).write(to:output.appendingPathComponent("builds.json"),options:.atomic)}
            XCTAssertEqual(try native.count,256)
            XCTAssertEqual(Set(keys),expected,"Unfiltered native search with a budget above the complete corpus, workers=\(workers)")
        }
    }
    func testLegacyParallelCacheCannotHideItsPresentOriginalFromIndexedSearch() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-native-cache-"+UUID().uuidString),store=try MemoryStore(root:root)
        defer {try? store.close();try? FileManager.default.removeItem(at:root)}
        for i in 0..<256 {
            var memory=Memory(id:"row-\(i)",timestamp:Date(timeIntervalSince1970:Double(i)),kind:i%2==0 ? .note:.audio,app:i%4==0 ? "A":"B",text:"Fixture \(i)",favorite:i%3==0,tags:i%5==0 ? ["work"]:[])
            memory.embedding=VectorScalingEvaluation.vector(row:i,dimensions:32);memory.embeddingModel="fixture";try store.insert(memory)
        }
        let file=try XCTUnwrap(Bundle.module.url(forResource:"parallel-orphans-v2",withExtension:"usearch",subdirectory:"NativeANN")),data=try Data(contentsOf:file),digest=SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
        let provenance=try XCTUnwrap(Bundle.module.url(forResource:"provenance",withExtension:"json",subdirectory:"NativeANN")),metadata=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:provenance)) as? [String:Any])
        XCTAssertEqual(digest,metadata["graphSHA256"] as? String)
        let legacy="usearch-2.26.5-f16-cos-m32-passages-v2",source=try VectorIndexSource(root:root,modelID:"fixture",dimensions:32),state=try source.state()
        let prefix=SHA256.hash(data:Data("\(state.identity)\nfixture\n32\n\(legacy)".utf8)).map {String(format:"%02x",$0)}.joined(),directory=root.appendingPathComponent("indexes",isDirectory:true)
        try Paths.ensure(directory);let name=prefix+"-owned-legacy.usearch",graph=directory.appendingPathComponent(name);try data.write(to:graph,options:.atomic)
        let manifest=ANNManifest(storeID:state.identity,modelID:"fixture",dimensions:32,format:legacy,sequence:state.head,count:256,graph:name,sha256:digest)
        try JSONEncoder().encode(manifest).write(to:directory.appendingPathComponent(prefix+".json"),options:.atomic)
        let query=VectorScalingEvaluation.vector(row:114,dimensions:32),old=try NativeANN(dimensions:32);try old.load(graph)
        XCTAssertEqual(try old.count,256);XCTAssertFalse(try old.search(query,count:2000).contains(115),"The retained graph must still reproduce its orphan")
        func frames()throws->[Data] {try store.withRoutineDatabase {db in
            let s=try db.statement("SELECT oswind_sync_row_v1(id,timestamp,kind,app,title,url,text,favorite,payload,embedding,embedding_model) FROM memories ORDER BY id");defer {sqlite3_finalize(s)};var result=[Data](),code=sqlite3_step(s)
            while code==SQLITE_ROW {guard let p=sqlite3_column_blob(s,0) else {throw db.error()};result.append(Data(bytes:p,count:Int(sqlite3_column_bytes(s,0))));code=sqlite3_step(s)};guard code==SQLITE_DONE else {throw db.error()};return result
        }}
        let before=try frames(),filter=SearchFilter(query:"meaning",limit:5),exact=try store.search(filter,mode:.semantic,vector:query,modelID:"fixture",minimumSimilarity:-1)
        XCTAssertEqual(exact.first?.id,"row-114")
        _=try await store.buildSearchIndex(modelID:"fixture",dimensions:32)
        var strategy="";let indexed=try store.search(filter,mode:.semantic,vector:query,modelID:"fixture",minimumSimilarity:-1,indexPolicy:.indexed) {strategy=$0.strategy}
        XCTAssertEqual(indexed.map(\.id),exact.map(\.id));XCTAssertEqual(strategy,"ann-exact-rerank")
        XCTAssertEqual(try frames(),before);XCTAssertEqual(try Data(contentsOf:graph),data)
    }
    func testSerialReplayWithEitherThreadHintKeepsAllLiveMembers()throws {
        for hint in [1,4] {
            var rows=(0..<256).map {IndexedVector(key:UInt64($0+1),revision:Int64($0+1),vector:VectorScalingEvaluation.vector(row:$0,dimensions:32),parentKey:UInt64($0+1))}
            let native=try NativeANN(dimensions:32);try native.reserve(1024);try native.addBatch(rows,threads:hint)
            for round in 0..<4 {
                let indices=Array((round*64)..<(round*64+64))
                for i in indices {try native.remove(rows[i].key);rows[i].vector=VectorScalingEvaluation.vector(row:1000+i,dimensions:32)}
                try native.addBatch(indices.map {rows[$0]},threads:hint)
                XCTAssertEqual(try native.count,256)
                XCTAssertEqual(Set(try native.search(rows[0].vector!,count:2000)),Set(rows.map(\.key)),"replay round \(round), hint \(hint)")
            }
        }
    }
    func testSerialPagedAppendKeepsEveryAuthoredMember()throws {
        let native=try NativeANN(dimensions:32);try native.reserve(1536);var expected=Set<UInt64>()
        for first in stride(from:0,to:1024,by:256) {
            let rows=(first..<first+256).map {IndexedVector(key:UInt64($0+1),revision:Int64($0+1),vector:VectorScalingEvaluation.vector(row:$0,dimensions:32),parentKey:UInt64($0+1))}
            try native.addBatch(rows,threads:4);expected.formUnion(rows.map(\.key))
            XCTAssertEqual(try native.count,expected.count)
            XCTAssertEqual(Set(try native.search(VectorScalingEvaluation.vector(row:42,dimensions:32),count:2000)),expected)
        }
    }
}
