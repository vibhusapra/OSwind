import XCTest
import CSQLite
@testable import OSwindCore

extension SyncIncomingSourceTests {
    @discardableResult private func deliverEntityPuts(_ producer:SyncVersionStore,_ receiver:MemoryStore,_ cache:SyncVersionStore,after:Int64=0)throws->[String:String] {
        var local=[String:String]()
        for operation in try producer.journal.outbox(after:after) {
            if operation.mutation != .put {try receiveDeletion(operation,receiver,cache);continue}
            let record=try packet(operation,producer)
            local[try record.identity.key.digest]=try receive(operation,record,receiver,cache,fetch:{ref in try XCTUnwrap(producer.record(ref,admit:{_ in}))})
        };return local
    }
    func testIncomingEntityDefinitionsAndAliasesUseNativeOwnershipWithoutEcho()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        _=try a.createEntity(kind:.person,name:"Mira",detail:"Owned person notes",aliases:["Mira Vale"])
        _=try a.createEntity(kind:.project,name:"Apollo",detail:"Owned project notes",aliases:["Apollo Mission"]);try drain(a,ac)
        _=try deliverEntityPuts(ac,b,bc)
        let people=try b.entities(kind:.person),projects=try b.entities(kind:.project)
        XCTAssertEqual(people.count,1);XCTAssertEqual(people.first?.name,"Mira");XCTAssertEqual(people.first?.detail,"Owned person notes");XCTAssertEqual(Set(people.first?.aliases ?? []),Set(["Mira","Mira Vale"]))
        XCTAssertEqual(projects.count,1);XCTAssertEqual(projects.first?.name,"Apollo");XCTAssertEqual(Set(projects.first?.aliases ?? []),Set(["Apollo","Apollo Mission"]))
        for operation in try ac.journal.outbox() {let record=try packet(operation,ac);XCTAssertEqual(try bc.resolve(record.identity,content:nil,admit:{_ in}).encoded(),try record.encoded())}
        XCTAssertEqual(try count(b,"personal_sync_changes"),0);XCTAssertTrue(try bc.journal.outbox().isEmpty)
        let rules=try b.entityIndexPlan().revision,through=try XCTUnwrap(ac.journal.outbox().last).dot.counter
        let nativePerson=try XCTUnwrap(a.entities(kind:.person).first);try a.deleteEntity(nativePerson.id);try drain(a,ac);_=try deliverEntityPuts(ac,b,bc,after:through)
        XCTAssertEqual(try b.entityIndexPlan().revision,rules,"Person/alias deletion must not force a full project rescan")
        XCTAssertEqual(try count(b,"memory_entities"),1);XCTAssertTrue(try bc.journal.outbox().isEmpty)
    }
    func testIncomingEntityManualAndAutomaticMentionsKeepExactSpansWithoutClaimingLocalIndex()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let memory=Memory(id:"entity-source",timestamp:now,kind:.note,app:"Owned entity fixture",title:"Owned source",text:"Mira owns Apollo.");try a.insert(memory)
        let person=try a.createEntity(kind:.person,name:"Mira"),project=try a.createEntity(kind:.project,name:"Apollo")
        try a.linkEntity(person.id,to:memory.id)
        try a.saveEntityExtraction(memory:memory,plan:a.entityIndexPlan(),result:.init(candidates:[.init(kind:.person,name:"Mira",start:0,length:4),.init(kind:.project,name:"Apollo",start:10,length:6,method:"project-alias",projectID:project.id)]))
        try drain(a,ac);_=try deliverEntityPuts(ac,b,bc)
        let nativePerson=try XCTUnwrap(b.entities(kind:.person).first),nativeProject=try XCTUnwrap(b.entities(kind:.project).first)
        XCTAssertEqual(try count(b,"entity_mentions"),3);XCTAssertEqual(nativePerson.sourceCount,1);XCTAssertEqual(nativeProject.sourceCount,1)
        let personLink=try XCTUnwrap(b.entitySources(nativePerson.id).first),projectLink=try XCTUnwrap(b.entitySources(nativeProject.id).first)
        XCTAssertEqual(personLink.origin,"automatic");XCTAssertEqual(personLink.surface,"Mira");XCTAssertEqual(projectLink.surface,"Apollo");XCTAssertEqual(try b.entitySourceMemory(projectLink).text,memory.text)
        XCTAssertEqual(try b.entityIndexProgress(processor:EntityExtractor.processor(b.entityIndexPlan())).indexed,0)
        var filter=SearchFilter(query:"Apollo");filter.entityID=nativeProject.id;XCTAssertEqual(try b.search(filter,mode:.keyword).count,1)
        XCTAssertEqual(try count(b,"personal_sync_changes"),0);XCTAssertTrue(try bc.journal.outbox().isEmpty)
    }
    func testIncomingEntityAndProjectRejectionsPreventNativeReassociation()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let memory=Memory(id:"rejected-source",timestamp:now,kind:.note,app:"Owned entity fixture",text:"Mira owns Apollo.");try a.insert(memory)
        let person=try a.createEntity(kind:.person,name:"Mira",aliases:["Mira Vale"]),project=try a.createEntity(kind:.project,name:"Apollo")
        try drain(a,ac);let initial=try deliverEntityPuts(ac,b,bc),through=try XCTUnwrap(ac.journal.outbox().last).dot.counter,sourceIdentity=try ac.catalog.localIdentity(.source,primary:[.text(Data(memory.id.utf8))]),local=try XCTUnwrap(initial[sourceIdentity.key.digest])
        try a.unlinkEntity(person.id,from:memory.id);try a.unlinkEntity(project.id,from:memory.id);try drain(a,ac);_=try deliverEntityPuts(ac,b,bc,after:through)
        XCTAssertEqual(try count(b,"entity_ignored"),2);XCTAssertEqual(try count(b,"entity_project_ignored"),1)
        let nativeProject=try XCTUnwrap(b.entities(kind:.project).first),nativeSource=try XCTUnwrap(b.get(local)),plan=try b.entityIndexPlan()
        try b.saveEntityExtraction(memory:nativeSource,plan:plan,result:.init(candidates:[.init(kind:.person,name:"Mira",start:0,length:4),.init(kind:.project,name:"Apollo",start:10,length:6,method:"project-alias",projectID:nativeProject.id)]))
        XCTAssertEqual(try count(b,"entity_mentions"),0);XCTAssertEqual(try count(b,"personal_sync_changes"),0);XCTAssertTrue(try bc.journal.outbox().isEmpty)
    }
    func testIncomingEntityAliasReplacementAndDeletionFollowRealProducerOrder()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let entity=try a.createEntity(kind:.project,name:"Apollo",aliases:["Old mission"]);try drain(a,ac);_=try deliverEntityPuts(ac,b,bc)
        var through=try XCTUnwrap(ac.journal.outbox().last).dot.counter
        try a.editEntity(entity.id,name:"Orion",detail:"Revised",aliases:["New mission"]);try drain(a,ac)
        XCTAssertTrue(try ac.journal.outbox(after:through).contains {$0.mutation != .put});_=try deliverEntityPuts(ac,b,bc,after:through)
        let native=try XCTUnwrap(b.entities(kind:.project).first);XCTAssertEqual(native.name,"Orion");XCTAssertEqual(Set(native.aliases),Set(["Orion","New mission"]))
        through=try XCTUnwrap(ac.journal.outbox().last).dot.counter
        try a.deleteEntity(entity.id);try drain(a,ac);_=try deliverEntityPuts(ac,b,bc,after:through)
        XCTAssertEqual(try count(b,"memory_entities"),0);XCTAssertEqual(try count(b,"entity_aliases"),0);XCTAssertEqual(try count(b,"personal_sync_changes"),0);XCTAssertTrue(try bc.journal.outbox().isEmpty)
    }
    func testIncomingEntityAliasCollisionRollsBackReceiptAndLeavesLocalOwner()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        _=try a.createEntity(kind:.person,name:"Mira");let native=try b.createEntity(kind:.person,name:"Mira");try drain(a,ac);try drain(b,bc)
        var rejected:SyncRevision?
        for operation in try ac.journal.outbox() {
            let record=try packet(operation,ac)
            if case .entityAlias=record.body {rejected=operation;XCTAssertThrowsError(try receive(operation,record,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))}));break}
            _=try receive(operation,record,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
        }
        let operation=try XCTUnwrap(rejected);XCTAssertTrue(try bc.journal.state(for:operation.key).heads.isEmpty)
        XCTAssertEqual(try b.withRoutineDatabase {try $0.entityID(kind:.person,key:"mira")},native.id);XCTAssertEqual(try b.entity(native.id)?.aliases,["Mira"])
    }
    func testIncomingEntityStaleMentionCannotAttachToChangedCurrentSource()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var memory=Memory(id:"source",timestamp:now,kind:.note,app:"Owned",text:"Mira");try a.insert(memory);let entity=try a.createEntity(kind:.person,name:"Mira");try drain(a,ac);let initial=try deliverEntityPuts(ac,b,bc),identity=try ac.catalog.localIdentity(.source,primary:[.text(Data(memory.id.utf8))]),nativeID=try XCTUnwrap(initial[identity.key.digest])
        try a.linkEntity(entity.id,to:memory.id);try drain(a,ac);let pending=try XCTUnwrap(ac.journal.outbox().last),mention=try packet(pending,ac)
        memory=try XCTUnwrap(b.get(nativeID));memory.text="A different person";try b.insert(memory);try drain(b,bc)
        XCTAssertThrowsError(try receive(pending,mention,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))}))
        XCTAssertEqual(try count(b,"entity_mentions"),0);XCTAssertTrue(try bc.journal.state(for:pending.key).heads.isEmpty)
    }
    func testIncomingEntityIndependentUncuratedDefinitionSurvivesPeerSourceReplacement()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        var memory=Memory(id:"source",timestamp:now,kind:.note,app:"Owned",text:"Mira")
        let other=Memory(id:"other-source",timestamp:now,kind:.note,app:"Owned",text:"Mira")
        for source in [memory,other] {try a.insert(source);try a.saveEntityExtraction(memory:source,plan:a.entityIndexPlan(),result:.init(candidates:[.init(kind:.person,name:"Mira",start:0,length:4)]))}
        try drain(a,ac);var sourceLocal="",entityWire:SyncPortableRecord?
        for operation in try ac.journal.outbox() {
            let record=try packet(operation,ac)
            if case .source=record.body,record.identity == (try ac.catalog.localIdentity(.source,primary:[.text(Data(other.id.utf8))])) {
                // Authored partial projection: authenticated journal receipt is
                // durable while this independent source awaits native admission.
                XCTAssertEqual(try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in}.applied,1);continue
            }
            if case .entityMention(let body)=record.body,body.source.identity == (try ac.catalog.localIdentity(.source,primary:[.text(Data(other.id.utf8))])) {
                XCTAssertEqual(try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in}.applied,1);continue
            }
            let local=try receive(operation,record,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
            if case .source=record.body {sourceLocal=local};if case .entity=record.body {entityWire=record}
        }
        let through=try XCTUnwrap(ac.journal.outbox().last).dot.counter,wire=try XCTUnwrap(entityWire)
        memory.text="No person here";try a.insert(memory);try drain(a,ac)
        for operation in try ac.journal.outbox(after:through) {
            if operation.mutation == .put {let record=try packet(operation,ac);_=try receive(operation,record,b,bc,fetch:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})}
            else {
                // Its native relationship retirement is deferred. Source
                // replacement must still invalidate the stale local span while
                // preserving the independently live entity definition.
                XCTAssertEqual(try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in}.applied,1)
            }
        }
        XCTAssertEqual(try count(b,"entity_mentions"),0);XCTAssertEqual(try count(b,"memory_entities"),1);XCTAssertEqual(try count(b,"entity_aliases"),1)
        XCTAssertEqual(try bc.resolve(wire.identity,content:nil,admit:{_ in}),wire);XCTAssertEqual(try b.get(sourceLocal)?.text,memory.text)
    }

    func testIncomingEntityExplicitMergeTransfersAliasesAndRetiresOldOwner()throws {
        for batch in [1,128] {
        let (a,ac)=try endpoint("producer-\(batch)",producerID),(b,bc)=try endpoint("receiver-\(batch)",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let one=try a.createEntity(kind:.person,name:"Mira",aliases:["Mira Vale"]),two=try a.createEntity(kind:.person,name:"M. Vale");try drain(a,ac);_=try deliverEntityPuts(ac,b,bc)
        let through=try XCTUnwrap(ac.journal.outbox().last).dot.counter
        // Older pending work for the former parent must not move its final
        // deletion ahead of later alias transfers across one-object batches.
        try a.withRoutineDatabase {db in let row=try db.statement("UPDATE memory_entities SET detail='Pending earlier edit' WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,one.id);try db.done(row)}
        try a.mergeEntity(one.id,into:two.id)
        do {try drain(a,ac,limit:batch)}catch {throw OSwindError.invalid("Owned merge outgoing stage: \(error)")}
        do {_=try deliverEntityPuts(ac,b,bc,after:through)}catch {throw OSwindError.invalid("Owned merge incoming stage: \(error)")}
        let native=try XCTUnwrap(b.entities(kind:.person).first);XCTAssertEqual(try count(b,"memory_entities"),1);XCTAssertEqual(native.name,"M. Vale");XCTAssertEqual(Set(native.aliases),Set(["M. Vale","Mira","Mira Vale"]))
        XCTAssertEqual(try count(b,"personal_sync_changes"),0);XCTAssertTrue(try bc.journal.outbox().isEmpty)
        }
    }
    func testIncomingEntityOldExactLinkRemainsValidAfterSourceFavoriteChange()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let memory=Memory(id:"source",timestamp:now,kind:.note,app:"Owned",text:"Mira");try a.insert(memory);let entity=try a.createEntity(kind:.person,name:"Mira");try a.linkEntity(entity.id,to:memory.id);try drain(a,ac);_=try deliverEntityPuts(ac,b,bc)
        let mention=try XCTUnwrap(ac.journal.outbox().last {$0.key.kind == .entityMention}),record=try packet(mention,ac),through=try XCTUnwrap(ac.journal.outbox().last).dot.counter
        _=try a.setFavorite(memory.id,value:true);try drain(a,ac);_=try deliverEntityPuts(ac,b,bc,after:through)
        let lease=try b.mediaWriteLease();defer {lease.release()}
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{_ in},pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        _=try writer.apply(record,admission:lease,fetchExactSource:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})
        XCTAssertEqual(try bc.resolve(record.identity,content:nil,admit:{_ in}),record);XCTAssertEqual(try count(b,"entity_mentions"),1);XCTAssertEqual(try count(b,"personal_sync_changes"),0)
    }
    func testIncomingEntityLateSourceHeadDeletionRollsBackNativeLinkAndReceipt()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let memory=Memory(id:"source",timestamp:now,kind:.note,app:"Owned",text:"Mira");try a.insert(memory);let entity=try a.createEntity(kind:.person,name:"Mira");try drain(a,ac);_=try deliverEntityPuts(ac,b,bc)
        try a.linkEntity(entity.id,to:memory.id);try drain(a,ac);let pending=try XCTUnwrap(ac.journal.outbox().last),record=try packet(pending,ac)
        guard case .entityMention(let body)=record.body else {return XCTFail("Missing mention")}
        let lease=try b.mediaWriteLease();defer {lease.release()};var mutated=false
        let writer=SyncIncomingConversationWriter(library:b,cache:bc,admit:{packet in
            if !mutated,packet.identity==record.identity,try bc.catalog.object(record.identity) != nil {mutated=true;_=try bc.journal.delete(key:body.source.identity.key)}
        },pathsFor:{_,_ in [:]},admitMedia:{_,_,_ in})
        XCTAssertThrowsError(try bc.journal.receive(pending,contentAvailable:{_ in true}) {_ in _=try writer.apply(record,admission:lease,fetchExactSource:{ref in try XCTUnwrap(ac.record(ref,admit:{_ in}))})})
        XCTAssertTrue(mutated);XCTAssertEqual(try count(b,"entity_mentions"),0);XCTAssertTrue(try bc.journal.state(for:pending.key).heads.isEmpty);XCTAssertFalse(try bc.journal.state(for:body.source.identity.key).isDeleted);XCTAssertTrue(try bc.journal.outbox().isEmpty)
    }
    func testIncomingEntityUnknownBodyFreeDeletesCreateBarriersWithoutNativeRows()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        for table in SyncIncomingEntityWriter.tables.sorted(by:{$0.rawValue<$1.rawValue}) {
            let identity=try SyncObjectIdentity(table:table,origin:producerID,lifetime:UUID().uuidString.lowercased()),operation=try ac.journal.delete(key:identity.key)
            try receiveDeletion(operation,b,bc);XCTAssertTrue(try bc.journal.state(for:identity.key).isDeleted);XCTAssertNil(try bc.catalog.object(identity))
        }
        for table in SyncIncomingEntityWriter.tables {XCTAssertEqual(try count(b,table.rawValue),0)};XCTAssertTrue(try bc.journal.outbox().isEmpty)
    }

    func testIncomingEntityPolicyReservationAndNewIDCollisionLeaveNoReceipt()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID),(other,_)=try endpoint("foreign",UUID().uuidString.lowercased());defer {try? a.close();try? b.close();try? other.close()};try bc.journal.allowPeer(producerID)
        _=try a.createEntity(kind:.person,name:"Mira");let existing=try b.createEntity(kind:.person,name:"Independent");try drain(a,ac);try drain(b,bc)
        let operation=try XCTUnwrap(ac.journal.outbox().first),record=try packet(operation,ac),before=try bc.journal.outbox(),own=try b.mediaWriteLease(),foreign=try other.mediaWriteLease(),released=try b.mediaWriteLease();released.release();defer {own.release();foreign.release()}
        let regular=SyncIncomingEntityWriter(library:b,cache:bc,admit:{_ in}),denied=SyncIncomingEntityWriter(library:b,cache:bc,admit:{_ in throw OSwindError.invalid("Owned policy denial")}),collision=SyncIncomingEntityWriter(library:b,cache:bc,admit:{_ in},newID:{_ in existing.id})
        for (writer,lease) in [(regular,foreign),(regular,released),(denied,own),(collision,own)] {
            XCTAssertThrowsError(try bc.journal.receive(operation,contentAvailable:{_ in true}) {_ in _=try writer.apply(record,admission:lease,fetchExactSource:{_ in throw OSwindError.invalid("No source dependency")})})
            XCTAssertTrue(try bc.journal.state(for:operation.key).heads.isEmpty);XCTAssertNil(try bc.catalog.object(record.identity));XCTAssertEqual(try count(b,"memory_entities"),1);XCTAssertEqual(try bc.journal.outbox(),before)
        }
    }
    func testIncomingEntityQuietBackupRetainsNativeLinksAndFreshIdentityExport()throws {
        let (a,ac)=try endpoint("producer",producerID),(b,bc)=try endpoint("receiver",receiverID);defer {try? a.close();try? b.close()};try bc.journal.allowPeer(producerID)
        let memory=Memory(id:"source",timestamp:now,kind:.note,app:"Owned",text:"Mira owns Apollo");try a.insert(memory);let person=try a.createEntity(kind:.person,name:"Mira"),project=try a.createEntity(kind:.project,name:"Apollo");try a.linkEntity(person.id,to:memory.id);try a.unlinkEntity(project.id,from:memory.id);try drain(a,ac);_=try deliverEntityPuts(ac,b,bc)
        let archive=root.appendingPathComponent("entities.oswindbackup"),destination=root.appendingPathComponent("restored");_=try LibraryBackup.create(store:b,destination:archive);_=try LibraryBackup.restore(archive,to:destination)
        let restored=try MemoryStore(root:destination)
        try restored.withRoutineDatabase {db in XCTAssertEqual(try db.eraseCount("SELECT enabled FROM personal_sync_capture"),0);XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM personal_sync_changes"),0);XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM entity_index_state"),0)}
        XCTAssertEqual(try restored.entities(kind:.person).first?.sourceCount,1);XCTAssertEqual(try count(restored,"entity_project_ignored"),1);try restored.close()
        let (fresh,fc)=try endpoint("restored",UUID().uuidString.lowercased());defer {try? fresh.close()}
        XCTAssertEqual(try fc.journal.outbox().filter {$0.key.kind == .entityMention}.count,1);XCTAssertEqual(try fc.journal.outbox().filter {$0.key.kind == .projectRejection}.count,1)
        XCTAssertTrue(try Set(ac.journal.outbox().map {$0.key.digest}).intersection(fc.journal.outbox().map {$0.key.digest}).isEmpty)
    }

}
