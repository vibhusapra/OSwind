import Foundation

public struct JSONImportResult:Codable,Sendable {
    public var imported=0
    public var excluded=0
    public var skippedLinkedRecaps=0
    public init() {}
}
enum RecapImport {
    /// Stable topological order. Inputs already have a total 100 MB bound; do not recurse on a chain.
    static func ordered(_ memories:[Memory]) throws -> [Memory] {
        var byID=[String:Int](),degree=Array(repeating:0,count:memories.count),children=[String:[Int]]()
        for (i,memory) in memories.enumerated() {
            guard !memory.id.isEmpty,memory.id.count<200,!memory.id.utf8.contains(0),byID.updateValue(i,forKey:memory.id)==nil else {throw OSwindError.invalid("Imported source IDs must be unique, nonempty and under 200 characters")}
            if let recap=memory.recap {_ = try recap.validated()}
        }
        for (i,memory) in memories.enumerated() {
            for id in Set(memory.recap?.sources.map(\.id) ?? []) where byID[id] != nil {
                degree[i]+=1;children[id,default:[]].append(i)
            }
        }
        var queue=degree.indices.filter {degree[$0]==0},head=0,result=[Memory]();result.reserveCapacity(memories.count)
        while head<queue.count {
            try Task.checkCancellation();let i=queue[head];head+=1;result.append(memories[i])
            for child in children[memories[i].id] ?? [] {degree[child]-=1;if degree[child]==0 {queue.append(child)}}
        }
        guard result.count==memories.count else {throw OSwindError.invalid("Imported recap source links form a cycle")}
        return result
    }
}
