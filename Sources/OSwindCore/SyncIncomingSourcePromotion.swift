import Foundation
import CSQLite

/// Converts live references to immutable originals before a peer replaces their
/// canonical owner. All native/cache metadata is rebound in the same transaction.
struct SyncIncomingSourcePromotion {
    struct Node {let before:Memory,packet:SyncPortableRecord;var original:HistoricalEvidence?;var after:Memory}
    let writer:SyncIncomingSourceWriter
    let root:String
    var nodes:[Node]
    var rebound=[SyncPortableRecord]()
    var db:RoutineDatabase {writer.db}
    /// The replaced root is a pre-write snapshot, not retained evidence unless
    /// an actual citation/pin promoted it. Its obsolete dependency graph must
    /// not block a safe replacement with no such dependency. Live non-root
    /// recaps and every actually preserved original still need the full audit.
    var requiredPackets:[SyncPortableRecord] {
        nodes.filter {Data($0.before.id.utf8) != Data(root.utf8) || $0.original != nil}.map(\.packet)
    }
    static func prepare(_ writer:SyncIncomingSourceWriter,root:String)throws->Self {
        let db=writer.db,row=try db.statement("WITH RECURSIVE linked(id) AS (SELECT ? UNION SELECT r.recap_id FROM recap_sources r JOIN linked l ON r.source_id=l.id) SELECT m.id FROM memories m JOIN linked l ON l.id=m.id ORDER BY m.id LIMIT 513");defer {sqlite3_finalize(row)};db.bind(row,1,root)
        var memories=[Memory](),code=sqlite3_step(row)
        while code==SQLITE_ROW {guard memories.count<512,let memory=try writer.library.get(db.text(row,0)) else {throw OSwindError.unavailable("Incoming source promotion exceeds its bound")};memories.append(memory);code=sqlite3_step(row)};guard code==SQLITE_DONE else {throw db.error()}
        var nodes=[Node]()
        for memory in memories {
            let reference=try writer.cache.sourceVersion(localID:memory.id,revision:.current,admit:writer.admit)
            guard let packet=try writer.cache.record(reference,admit:writer.admit) else {throw OSwindError.unavailable("Prepare the current local source before incoming projection")}
            nodes.append(.init(before:memory,packet:packet,original:nil,after:memory))
        }
        for memory in memories {guard try SyncProtocolLimits.encode(writer.library.get(memory.id))==SyncProtocolLimits.encode(memory) else {throw OSwindError.invalid("Local source changed during incoming admission")}}
        return .init(writer:writer,root:root,nodes:nodes)
    }
    private func nativePaths(_ memory:Memory)->[SyncMediaRole:String] {
        var paths=[SyncMediaRole:String]();paths[.image]=memory.imagePath;paths[.audio]=memory.audioPath;paths[.video]=memory.videoPath;return paths
    }
    private func hasOrdinaryReference(_ owner:String)throws->Bool {
        let row=try db.statement("SELECT EXISTS(SELECT 1 FROM chat_sources WHERE memory_id=? UNION ALL SELECT 1 FROM recap_sources WHERE source_id=? UNION ALL SELECT 1 FROM text_observation_pins p WHERE memory_id=? AND NOT EXISTS(SELECT 1 FROM historical_evidence_pins h WHERE h.memory_id=p.memory_id))");defer {sqlite3_finalize(row)};for i:Int32 in 1...3 {db.bind(row,i,owner)}
        guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()};return sqlite3_column_int(row,0)==1
    }
    private func currentBindings(_ owner:String)throws->[SyncPortableRecord] {
        var result=[SyncPortableRecord]()
        for table in [SyncCanonicalTable.conversationCitation,.recapCitation,.evidencePin] {
            let sql:String
            switch table {
            case .conversationCitation:sql="SELECT turn_id,ordinal FROM chat_sources WHERE memory_id=?"
            case .recapCitation:sql="SELECT recap_id,ordinal FROM recap_sources WHERE source_id=?"
            default:sql="SELECT memory_id FROM text_observation_pins p WHERE memory_id=? AND NOT EXISTS(SELECT 1 FROM historical_evidence_pins h WHERE h.memory_id=p.memory_id)"
            }
            let row=try db.statement(sql);defer {sqlite3_finalize(row)};db.bind(row,1,owner);var code=sqlite3_step(row)
            while code==SQLITE_ROW {
                var primary=[SyncRowCell.text(Data(db.text(row,0).utf8))];if table != .evidencePin {primary.append(.integer(sqlite3_column_int64(row,1)))}
                if let identity=try writer.cache.catalog.preparedIdentity(table,primary:primary),try writer.cache.projectedReference(identity) != nil {result.append(try writer.cache.resolve(identity,content:nil,admit:writer.admit))}
                code=sqlite3_step(row)
            };guard code==SQLITE_DONE else {throw db.error()}
        }
        return result
    }
    mutating func apply()throws {
        // Capture every live native version before changing a single owner or
        // its local provenance. The exact cache packets authenticate old media.
        let beforeNodes=nodes
        for i in nodes.indices where try hasOrdinaryReference(nodes[i].before.id) {
            let node=nodes[i];rebound+=try currentBindings(node.before.id)
            let preserved=try writer.history.adopt(node.packet.reference,cache:writer.cache,pathsFor:{reference,manifests in
                if let current=try beforeNodes.first(where:{try $0.packet.reference==reference}) {return nativePaths(current.before)}
                return try writer.pathsFor(reference,manifests)
            },admit:writer.admit,verifyMedia:writer.verify)
            nodes[i].original=preserved
        }
        for node in nodes {guard try SyncProtocolLimits.encode(writer.library.get(node.before.id))==SyncProtocolLimits.encode(node.before) else {throw OSwindError.invalid("Current source changed while preserving originals")}}
        let originals=Dictionary(uniqueKeysWithValues:nodes.compactMap {n in n.original.map {(Data(n.before.id.utf8),$0)}})
        for node in nodes {
            guard let original=node.original else {continue}
            try writer.library.incomingSourceProjection.withBinding(owner:node.before.id,handle:original.handle,oldRevision:node.before.evidenceHash,newRevision:original.memory.evidenceHash) {
                try SyncChangeCapture.withoutEcho(db,scope:writer.cache.catalog.scope) {
                    let chats=try db.statement("UPDATE chat_sources SET memory_id=NULL,owner_id=?,historical_handle=? WHERE memory_id=?");defer {sqlite3_finalize(chats)};db.bind(chats,1,node.before.id);db.bind(chats,2,original.handle);db.bind(chats,3,node.before.id);try db.done(chats)
                    let recaps=try db.statement("UPDATE recap_sources SET source_id=NULL,owner_id=?,historical_handle=?,revision=? WHERE source_id=?");defer {sqlite3_finalize(recaps)};db.bind(recaps,1,node.before.id);db.bind(recaps,2,original.handle);db.bind(recaps,3,original.memory.evidenceHash);db.bind(recaps,4,node.before.id);try db.done(recaps)
                    let pin=try db.statement("INSERT OR IGNORE INTO historical_evidence_pins SELECT memory_id,? FROM text_observation_pins WHERE memory_id=?");defer {sqlite3_finalize(pin)};db.bind(pin,1,original.handle);db.bind(pin,2,node.before.id);try db.done(pin)
                }
            }
        }
        for i in nodes.indices {
            guard Data(nodes[i].before.id.utf8) != Data(root.utf8),var recap=nodes[i].before.recap else {continue}
            for j in recap.sources.indices where recap.sources[j].historicalHandle==nil {
                if let parent=originals[Data(recap.sources[j].id.utf8)] {recap.sources[j].historicalHandle=parent.handle;recap.sources[j].revision=parent.memory.evidenceHash}
            }
            if recap != nodes[i].before.recap {
                nodes[i].after.recap=recap
                try SyncChangeCapture.withoutEcho(db,scope:writer.cache.catalog.scope) {try writer.library.rebindIncomingRecap(nodes[i].before,to:nodes[i].after)}
            }
        }
        for node in nodes where Data(node.before.id.utf8) != Data(root.utf8) {
            try writer.cache.bindProjection(node.packet.reference,references:writer.references(node.packet,local:node.before.id,paths:nativePaths(node.after)),admit:writer.admit)
        }
        for packet in rebound {try writer.cache.bindProjection(packet.reference,references:writer.references(packet,local:root,paths:[:]),admit:writer.admit)}
    }
    func audit()throws {
        for node in nodes {
            if let original=node.original {
                let after=try writer.history.read(original.handle,sourceID:node.before.id,verifyMedia:writer.library.verifyHistoricalMedia)
                guard try after.reference==original.reference,try SyncProtocolLimits.encode(after.memory)==SyncProtocolLimits.encode(original.memory) else {throw OSwindError.invalid("Preserved original changed during incoming projection")}
            }
            if Data(node.before.id.utf8) != Data(root.utf8) {
                guard try SyncProtocolLimits.encode(writer.library.get(node.before.id))==SyncProtocolLimits.encode(node.after),try writer.cache.resolve(node.packet.identity,content:nil,admit:{_ in}).encoded()==node.packet.encoded() else {throw OSwindError.invalid("Preserved recap changed during incoming projection")}
            }
        }
        for packet in rebound {guard try writer.cache.resolve(packet.identity,content:nil,admit:{_ in}).encoded()==packet.encoded() else {throw OSwindError.invalid("Rebound citation changed during incoming projection")}}
    }
}
