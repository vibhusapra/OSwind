import XCTest
@testable import OSwindCore

final class PersonalSyncProtocolTests:XCTestCase {
    let a="00000000-0000-0000-0000-000000000001"
    let b="00000000-0000-0000-0000-000000000002"
    let c="00000000-0000-0000-0000-000000000003"
    func key(_ value:String="owned")throws->SyncObjectKey {try .make(kind:.source,identity:Data(value.utf8))}
    func revision(_ actor:String,_ n:Int64,_ context:SyncClock = .empty,_ text:String?="value")throws->SyncRevision {
        try .init(key:key(),dot:.init(replica:actor,counter:n),context:context,mutation:text==nil ? .delete:.put,content:try text.map {try SyncContentReference(data:Data($0.utf8))})
    }
    func permutations<T>(_ values:[T])->[[T]] {
        if values.isEmpty {return [[]]}
        return values.indices.flatMap {i in var rest=values;let first=rest.remove(at:i);return permutations(rest).map {[first]+$0}}
    }
    func testClockRelationsAndMergePreservePartialOrder() throws {
        let x=try SyncClock([a:4]),y=try SyncClock([b:8]),both=try x.merged(with:y)
        XCTAssertEqual(x.relation(to:y),.concurrent);XCTAssertEqual(x.relation(to:both),.before)
        XCTAssertEqual(both.relation(to:y),.after);XCTAssertEqual(both.relation(to:try y.merged(with:x)),.equal)
        XCTAssertEqual(try both.merged(with:both),both)
    }
    func testClockRejectsInvalidIdentitiesCountsAndExcessPeers() throws {
        XCTAssertThrowsError(try SyncClock(["not-an-identity":1]))
        XCTAssertThrowsError(try SyncClock([a:0]));XCTAssertThrowsError(try SyncClock([a:-1]))
        var values=[String:Int64]()
        for _ in 0..<65 {values[UUID().uuidString.lowercased()]=1}
        XCTAssertThrowsError(try SyncClock(values))
        XCTAssertThrowsError(try SyncDot(replica:a.uppercased().replacingOccurrences(of:"00000000",with:"AAAAAAAA"),counter:1))
        XCTAssertEqual(try SyncClock([a:Int64.max])[a],Int64.max)
    }
    func testObjectIdentityHashesBytesWithoutUnicodeOrTypeAliasing() throws {
        let first=try SyncObjectKey.make(kind:.source,identity:Data("é".utf8))
        let second=try SyncObjectKey.make(kind:.source,identity:Data("e\u{301}".utf8))
        XCTAssertNotEqual(first,second)
        XCTAssertNotEqual(first,try .make(kind:.conversation,identity:Data("é".utf8)))
        XCTAssertThrowsError(try SyncObjectKey.make(kind:.source,identity:Data()))
    }
    func testAllConcurrentArrivalsRetainBothValuesAndSameProjection() throws {
        let revisions=[try revision(a,1,.empty,"alpha"),try revision(b,1,.empty,"beta"),try revision(c,1,.empty,"gamma")]
        var states=[SyncRegister]()
        for order in permutations(revisions) {var state=SyncRegister(key:try key());for r in order {try state.integrate(r)};states.append(state)}
        XCTAssertTrue(states.allSatisfy {$0==states[0] && $0.isConflicted && $0.heads.count==3})
        XCTAssertEqual(states[0].preferred?.dot.replica,a)
    }
    func testCausalResolutionConvergesEvenWhenParentsArriveLater() throws {
        let first=try revision(a,1,.empty,"alpha"),second=try revision(b,1,.empty,"beta")
        let merged=try revision(c,1,SyncClock([a:1,b:1]),"resolved")
        for order in permutations([first,second,merged]) {
            var state=SyncRegister(key:try key());for r in order {try state.integrate(r)}
            XCTAssertFalse(state.isConflicted);XCTAssertEqual(state.heads,[merged])
            XCTAssertEqual(try SyncRegister.decode(state.encoded()),state)
        }
    }
    func testDeleteWinsEveryConcurrentAndLateArrivalOrder() throws {
        let values=[try revision(a,1,.empty,"offline alpha"),try revision(b,1,.empty,"offline beta"),try revision(c,1,.empty,nil)]
        var states=[SyncRegister]()
        for order in permutations(values) {
            var state=SyncRegister(key:try key());for value in order {try state.integrate(value)}
            XCTAssertTrue(state.isDeleted);XCTAssertNil(state.preferred);XCTAssertTrue(state.heads.isEmpty)
            states.append(state)
        }
        XCTAssertTrue(states.allSatisfy {$0==states[0]})
    }
    func testLateDeleteStillCreatesBarrierWhenAlreadySeenInPutContext() throws {
        let deletion=try revision(a,1,.empty,nil)
        let later=try revision(b,1,SyncClock([a:1]),"old object cannot be restored by a put")
        var first=SyncRegister(key:try key()),second=first
        try first.integrate(later);try first.integrate(deletion)
        try second.integrate(deletion);XCTAssertEqual(try second.integrate(later),.suppressedByDeletion)
        XCTAssertEqual(first,second);XCTAssertTrue(first.isDeleted)
    }
    func testDeletionRemainsAcrossPersistenceAndLaterCausalWrites() throws {
        var state=SyncRegister(key:try key());try state.integrate(revision(a,1,.empty,nil))
        state=try SyncRegister.decode(state.encoded())
        let future=try revision(a,2,SyncClock([a:1]),"not an authorized new lifetime")
        XCTAssertEqual(try state.integrate(future),.suppressedByDeletion)
        XCTAssertTrue(state.isDeleted);XCTAssertNil(state.preferred)
        XCTAssertNotEqual(try key("restored-new-lifetime"),state.key)
    }
    func testDuplicateIsIdempotentButLiveRevisionEquivocationRefusesAtomically() throws {
        let first=try revision(a,1,.empty,"alpha");var state=SyncRegister(key:try key())
        try state.integrate(first);let before=state
        XCTAssertEqual(try state.integrate(first),.duplicate)
        XCTAssertThrowsError(try state.integrate(revision(a,1,.empty,"different content")))
        XCTAssertThrowsError(try state.integrate(revision(a,1,.empty,nil)))
        XCTAssertEqual(state,before)
    }
    func testWriterForkAndWrongObjectCannotChangeState() throws {
        var state=SyncRegister(key:try key());try state.integrate(revision(a,1));let before=state
        XCTAssertThrowsError(try state.integrate(revision(a,2,.empty,"missing prior context")))
        let other=try SyncRevision(key:key("other"),dot:.init(replica:b,counter:1),context:.empty,mutation:.delete)
        XCTAssertThrowsError(try state.integrate(other));XCTAssertEqual(state,before)
    }
    func testCausalContextCannotDropKnownTransitiveHistory() throws {
        let original=try revision(a,1,SyncClock([b:1]),"after beta")
        var state=SyncRegister(key:try key());try state.integrate(original);let before=state
        XCTAssertThrowsError(try state.integrate(revision(c,1,SyncClock([a:1]),"omitted beta")))
        XCTAssertEqual(state,before)
    }
    func testRevisionAndStateDecodersValidateInsteadOfBypassingInitializers() throws {
        let original=try revision(a,1),wire=try original.encoded()
        XCTAssertEqual(try SyncRevision.decode(wire),original)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:wire) as? [String:Any])
        object["mutation"]="delete"
        XCTAssertThrowsError(try SyncRevision.decode(JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])))
        object["mutation"]="put";object["unexpected"]=true
        XCTAssertThrowsError(try SyncRevision.decode(JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])))
        var state=SyncRegister(key:try key());try state.integrate(original)
        var encoded=try XCTUnwrap(JSONSerialization.jsonObject(with:state.encoded()) as? [String:Any])
        encoded["heads"]=[]
        XCTAssertThrowsError(try SyncRegister.decode(JSONSerialization.data(withJSONObject:encoded,options:[.sortedKeys,.withoutEscapingSlashes])))
        XCTAssertThrowsError(try SyncRevision.decode(Data(repeating:32,count:SyncProtocolLimits.operationBytes+1)))
    }
    func testContentReferenceChecksDigestLengthAndBounds() throws {
        let data=Data("exact authored original".utf8),reference=try SyncContentReference(data:Data("exact authored original".utf8))
        XCTAssertTrue(reference.matches(data));XCTAssertFalse(reference.matches(Data("changed authored original".utf8)))
        XCTAssertThrowsError(try SyncContentReference(sha256:reference.sha256,bytes:-1))
        XCTAssertThrowsError(try SyncContentReference(sha256:reference.sha256,bytes:SyncProtocolLimits.contentBytes+1))
        XCTAssertThrowsError(try SyncRevision(key:key(),dot:.init(replica:a,counter:1),context:SyncClock([a:1]),mutation:.put,content:reference))
    }
    func testSeededCausalHistoriesConvergeWithDuplicatesAndOfflineDeletes()throws {
        let actors=[a,b,c]
        for seed:UInt64 in 1...24 {
            var random=seed
            func draw(_ bound:Int)->Int {random=random &* 6364136223846793005 &+ 1442695040888963407;return Int((random >> 16) % UInt64(bound))}
            var replicas=try actors.map {_ in SyncRegister(key:try key())},counters=[Int64](repeating:0,count:3),operations=[SyncRevision]()
            for index in 0..<120 {
                let actor=draw(3)
                if !operations.isEmpty,draw(3)==0 {try replicas[actor].integrate(operations[draw(operations.count)])}
                counters[actor]+=1
                let deleted=replicas[actor].isDeleted || (index>80 && draw(9)==0)
                let value=try revision(actors[actor],counters[actor],replicas[actor].clock,deleted ? nil:"seed-\(seed)-operation-\(index)")
                try replicas[actor].integrate(value);operations.append(value)
            }
            var expected=try SyncRegister(key:key());for operation in operations {try expected.integrate(operation)}
            for _ in 0..<4 {
                var shuffled=operations
                for index in shuffled.indices.reversed() {shuffled.swapAt(index,draw(index+1))}
                var actual=try SyncRegister(key:key())
                for (index,operation) in shuffled.enumerated() {try actual.integrate(operation);if index%7==0 {try actual.integrate(operation)}}
                XCTAssertEqual(actual,expected,"Causal delivery did not converge for seed \(seed)")
                XCTAssertEqual(try SyncRegister.decode(actual.encoded()),expected)
            }
        }
    }

}
