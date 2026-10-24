import Foundation
import CryptoKit
import Metal

/// Explicit public/synthetic fixture admission, not a screen-capture/privacy
/// benchmark. Creates a NEW isolated library and never opens normal history.
public enum VisualMemoryEvaluation {
    struct Fixture:Decodable {var queries:[String];var images:[String];var targets:[Int]}
    public struct Report:Codable,Sendable {
        public var scope="Fixed public/synthetic image fixture through native visual index, query, source validation and reopen; not desktop capture, battery, cold-start or a competitor benchmark"
        public var schema:Int
        public var modelID:String
        public var corpusSHA256:String
        public var images:Int
        public var queries:Int
        public var indexedFrames:Int
        public var indexingSeconds:Double
        public var queryMedianMilliseconds:Double
        public var queryP95Milliseconds:Double
        public var recallAt1:Double
        public var recallAt5:Double
        public var recallAt10:Double
        public var reopenedIndexSources:Int
        public var scopedResultsVerified:Bool
        public var gpu:String
        public var os:String
        public var limits=["Single process/trial, uncontrolled Core ML/OS caches and host background activity.","Index time includes local model preparation. Query time includes text embedding, exact vector scan, source byte checks and result loading.","Fixture admission copies explicit supplied images with empty OCR; it does not measure capture permission, OCR, secret detection or background capture latency.","No image, caption, source path or raw vector is included in this aggregate report."]
    }
    public static func run(fixtureURL:URL,newRoot:URL,configuration:VisualSearchConfiguration,progress:@escaping @Sendable (VisualIndexProgress)->Void={_ in}) async throws -> Report {
        _ = try configuration.selectedDirectory();try BackupWorkspace.requireNewDestination(newRoot)
        let tree=try BackupFileTree(root:fixtureURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()),input=try tree.read(fixtureURL.lastPathComponent,limit:2*1024*1024)
        let fixture=try JSONDecoder().decode(Fixture.self,from:input)
        guard (1...256).contains(fixture.images.count),(1...1024).contains(fixture.queries.count),fixture.queries.count==fixture.targets.count,
              fixture.queries.allSatisfy({!$0.isEmpty && $0.count<=4000}),fixture.targets.allSatisfy({(0..<fixture.images.count).contains($0)}) else {throw OSwindError.invalid("Use 1–256 images and 1–1024 queries with a valid image target for every query")}
        let store=try MemoryStore(root:newRoot);defer {try? store.close()}
        var hashes=[String]()
        for (index,path) in fixture.images.enumerated() {
            try Task.checkCancellation();guard path.hasPrefix("/"),!path.utf8.contains(0) else {throw OSwindError.invalid("Use absolute fixture image paths")}
            let url=URL(fileURLWithPath:path),source=try BackupFileTree(root:url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()),data=try source.read(url.lastPathComponent,limit:64*1024*1024)
            _ = try VisualImageInput.pixels(data:data)
            hashes.append(BackupSHA256.hex(data))
            let activity=try store.mediaWriteLease();defer {activity.release()}
            let relative="images/source-\(index).image"
            try data.write(to:newRoot.appendingPathComponent(relative),options:.withoutOverwriting)
            var memory=Memory(id:"fixture-\(index)",timestamp:Date(timeIntervalSince1970:1_700_000_000+Double(index)),app:index%2==0 ? "Fixture A":"Fixture B",bundleID:"org.oswind.visual-fixture",title:"Public/synthetic fixture \(index)",text:"",imagePath:relative)
            memory.tags=[index%2==0 ? "even":"odd"];try store.insert(memory)
        }
        struct Corpus:Encodable {var images:[String];var queries:[String];var targets:[Int]}
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        let corpus=BackupSHA256.hex(try encoder.encode(Corpus(images:hashes,queries:fixture.queries,targets:fixture.targets)))
        var settings=AppSettings();settings.search.visual=configuration;try settings.save(root:newRoot)
        let engine=VisualRetrievalEngine(store:store),start=Date(),indexed=try await engine.rebuild(configuration:configuration,progress:progress),indexSeconds=Date().timeIntervalSince(start)
        guard indexed.failedSources==0,indexed.indexedSources==fixture.images.count else {throw OSwindError.unavailable("Visual fixture indexing incomplete: "+indexed.errors.joined(separator:"; "))}
        var latencies=[Double](),correct=[Int](repeating:0,count:3)
        for (index,query) in fixture.queries.enumerated() {
            try Task.checkCancellation();let begin=Date(),result=try await engine.search(SearchFilter(query:query,limit:10),configuration:configuration,interpretQuery:false)
            latencies.append(Date().timeIntervalSince(begin)*1000)
            guard result.hits.allSatisfy({$0.visual != nil}),result.modelID==indexed.modelID else {throw OSwindError.unavailable("Visual benchmark lost model or source identity")}
            let expected="fixture-\(fixture.targets[index])"
            for (offset,k) in [1,5,10].enumerated() {if result.hits.prefix(k).contains(where:{$0.id==expected}) {correct[offset]+=1}}
        }
        let scoped=try await engine.search(SearchFilter(query:fixture.queries[0],app:"Fixture A",tag:"even",limit:10),configuration:configuration,interpretQuery:false)
        guard scoped.hits.allSatisfy({$0.memory.app=="Fixture A" && $0.memory.tags.contains("even")}) else {throw OSwindError.unavailable("Visual query escaped its source scope")}
        try store.close();let reopened=try MemoryStore(root:newRoot);defer {try? reopened.close()}
        let coverage=try reopened.visualCoverage(modelID:indexed.modelID)
        guard coverage.indexedSources==fixture.images.count else {throw OSwindError.unavailable("Visual index did not survive reopening")}
        let sorted=latencies.sorted(),denominator=Double(fixture.queries.count)
        return Report(schema:MemoryStore.schemaVersion,modelID:indexed.modelID,corpusSHA256:corpus,images:fixture.images.count,queries:fixture.queries.count,indexedFrames:coverage.indexedFrames,indexingSeconds:indexSeconds,queryMedianMilliseconds:sorted[sorted.count/2],queryP95Milliseconds:sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))],recallAt1:Double(correct[0])/denominator,recallAt5:Double(correct[1])/denominator,recallAt10:Double(correct[2])/denominator,reopenedIndexSources:coverage.indexedSources,scopedResultsVerified:true,gpu:MTLCreateSystemDefaultDevice()?.name ?? "unavailable",os:ProcessInfo.processInfo.operatingSystemVersionString)
    }
}
