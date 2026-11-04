import Foundation

/// Explicit outcome for an admitted peer put. A retired lifetime has no local
/// identifier and must never be reported as a successfully projected record.
enum SyncIncomingProjectionOutcome:Equatable {
    case projected(String)
    case retired(key:SyncObjectKey,parents:[SyncObjectKey])
}

struct SyncRetiredDependency {
    let key:SyncObjectKey
    let clock:SyncClock
}

extension SyncPortableRecord {
    /// Ownership/evidence edges, rather than every optional scope reference.
    /// Optional run conversations and entity filters need their own surviving
    /// projection policy; deleting an independent owner to avoid that work is
    /// not equivalent to native ON DELETE SET NULL or a missing query scope.
    var retirementParents:[SyncObjectIdentity] {
        switch body {
        case .source(let value):return value.sourceReferences.map(\.identity)
        case .turn(let value):return [value.conversation]
        case .conversationCitation(let value),.recapCitation(let value):return [value.owner,value.link.source.identity]
        case .routineRun(let value):return [value.recipe.routine]
        case .entityAlias(let value):return [value.entity]
        case .entityMention(let value):return [value.source.identity,value.entity]
        case .entityRejection(let value):return [value.source.identity]
        case .projectRejection(let value):return [value.source.identity,value.entity]
        case .evidencePin(let value):return [value.source.identity]
        case .conversation,.routine,.entity:return []
        }
    }
    func erasedParents(cache:SyncVersionStore)throws->[SyncRetiredDependency] {
        var result=[SyncObjectKey:SyncClock]()
        for identity in retirementParents {
            try Task.checkCancellation()
            let key=try identity.key,state=try cache.journal.state(for:key)
            if state.isDeleted {result[key]=state.clock}
        }
        return result.keys.sorted(by:Self.retirementOrder).map {.init(key:$0,clock:result[$0]!)}
    }
    /// Turn packets do not embed their citation list, so a late answer citation
    /// can first reveal its erased evidence owner. Recap source packets already
    /// carry the authoritative parent list and retire through that list above.
    /// A stale/forged derived recap row must not erase an independent source.
    func ownersOfErasedEvidence(_ causes:Set<SyncObjectKey>)throws->[SyncObjectKey] {
        switch body {
        case .conversationCitation(let value):
            let source=try value.link.source.identity.key
            guard causes.contains(source) else {return []}
            return [try value.owner.key]
        default:return []
        }
    }
    static func retirementOrder(_ lhs:SyncObjectKey,_ rhs:SyncObjectKey)->Bool {
        lhs.kind==rhs.kind ? lhs.digest<rhs.digest:lhs.kind.rawValue<rhs.kind.rawValue
    }
}
