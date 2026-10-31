import XCTest
import CSQLite
import CryptoKit
@testable import OSwindCore

final class SyncPortableRecordTests:XCTestCase {
    let origin="00000000-0000-0000-0000-000000000101"
    let now=Date(timeIntervalSinceReferenceDate:815_000_000.1234567)
    var root:URL!,store:MemoryStore!
    var identities:[String:SyncObjectIdentity]=[:],sources:[String:SyncPortableRecord]=[:],records:[String:SyncPortableRecord]=[:]
    var recipeID="",conversationID="",entityID="",turnID="",recapID=""
    let sourceID="OWNED-LOCAL-SOURCE-ID",sampleID="OWNED-LOCAL-SAMPLE-ID"
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-portable-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError()throws {try store.close();store=nil;try FileManager.default.removeItem(at:root)}
    func identity(_ table:SyncCanonicalTable,_ primary:[SyncRowCell])throws->SyncObjectIdentity {
        let key=table.rawValue+":"+SyncProtocolLimits.hex(try SyncIdentityCatalog.keyFrame(table,primary))
        if let id=identities[key] {return id};let id=try SyncObjectIdentity(table:table,origin:origin,lifetime:UUID().uuidString.lowercased());identities[key]=id;return id
    }
    func identity(_ table:SyncCanonicalTable,_ id:String)throws->SyncObjectIdentity {try identity(table,[.text(Data(id.utf8))])}
    func exporter()->SyncPortableExporter {
        .init(references:.init(identity:{try self.identity($0,$1)},source:{id,expected in
            guard let memory=try self.store.get(id),let record=self.sources[id] else {throw OSwindError.invalid("Owned source version unavailable")}
            switch expected {case .current:break;case .evidence(let hash):guard hash==memory.evidenceHash else {throw OSwindError.invalid("Owned evidence changed")};case .entity(let hash):guard hash==memory.entityRevision else {throw OSwindError.invalid("Owned mention changed")}}
            return try record.reference
        },media:{_ in []},recipe:{id,ordinal in .init(routine:try self.identity(.routine,id),editorOrigin:self.origin,ordinal:ordinal,definition:nil)},session:{_ in nil}))
    }
    func rows(_ table:SyncCanonicalTable)throws->[SyncRowSnapshot] {
        try store.withRoutineDatabase {db in
            let row=try db.statement("SELECT "+table.schema.snapshot("t")+" FROM "+table.rawValue+" t ORDER BY "+table.schema.primary.joined(separator:","));defer {sqlite3_finalize(row)}
            var result=[SyncRowSnapshot](),code=sqlite3_step(row)
            while code==SQLITE_ROW {guard let p=sqlite3_column_blob(row,0) else {throw db.error()};result.append(try .decode(Data(bytes:p,count:Int(sqlite3_column_bytes(row,0)))));code=sqlite3_step(row)}
            guard code==SQLITE_DONE else {throw db.error()};return result
        }
    }
    func make(_ table:SyncCanonicalTable,_ row:SyncRowSnapshot)throws->SyncPortableRecord {
        let primary=table.schema.primary.map {row.cells[table.schema.columns.firstIndex(of:$0)!]};return try exporter().record(identity:identity(table,primary),row:row)
    }
    func seedGraph()throws {
        let memory=Memory(id:sourceID,timestamp:now,kind:.note,app:"Owned",title:"Authored source",text:"Alice owns Orion.")
        try store.insert(memory)
        var sampled=Memory(id:sampleID,timestamp:now,endTimestamp:now.addingTimeInterval(2),kind:.screen,app:"Owned",title:"Authored samples",text:"Sampled text",display:AccessibilityCaptureRecord.display)
        sampled.textObservation = .init(sessionID:"00000000-0000-0000-0000-000000000102",samples:2,largestGapSeconds:2);try store.insert(sampled);try store.withRoutineDatabase {try $0.pinTextObservation(sampled)}
        let entity=try store.createEntity(kind:.project,name:"Orion",detail:"Owned project",aliases:["Project Orion"]);entityID=entity.id;try store.linkEntity(entity.id,to:sourceID)
        let rejected=try store.createEntity(kind:.person,name:"Alice");try store.unlinkEntity(rejected.id,from:sourceID)
        let project=try store.createEntity(kind:.project,name:"Pluto");try store.unlinkEntity(project.id,from:sourceID)
        let chat=try store.createChat(title:"Owned conversation");conversationID=chat.id
        let filter=SearchFilter(query:"",app:"Owned",entityID:entity.id,limit:24)
        let answer=Answer(text:"Alice owns Orion [1].",sources:[SearchHit(memory:memory,score:1,match:"owned",passage:.init(start:0,length:5))],provider:"owned",duration:0.25,warnings:[])
        turnID=try store.appendChatTurn(sessionID:chat.id,question:"Who owns Orion?",answer:answer,filter:filter).id
        recapID=try store.saveRecap(answer,title:"Owned recap").id
        var recipe=RoutineDefinition();recipe.id="OWNED-LOCAL-RECIPE-ID";recipe.title="Owned recipe";recipe.ai.provider = .compatible;recipe.ai.endpoint="https://owned-fake-endpoint.invalid";recipe.ai.model="/Users/OWNED-FAKE-DEVICE/recipe-model";recipe.allowRemote=true;recipe.ai.allowRemote=true
        recipeID=recipe.id;let saved=try store.saveRoutine(recipe,now:now);let claim=try XCTUnwrap(store.claimRoutine(id:recipe.id,now:now));_=try store.finishRoutine(claim.run.id,status:.failed,message:"Owned failure history")
        recipe.prompt="Updated owned prompt";_=try store.saveRoutine(recipe,expectedRevision:saved.revision,now:now)
    }
    func prepareGraph()throws->[SyncPortableRecord] {
        let sourceRows=try rows(.source).sorted {a,b in
            func linked(_ row:SyncRowSnapshot)->Bool {if case .blob(let data)=row.cells[8] {return (try? JSONDecoder().decode(Memory.self,from:data).recap) != nil};return false}
            return !linked(a) && linked(b)
        }
        var result=[SyncPortableRecord]()
        for row in sourceRows {
            let record=try make(.source,row);if case .text(let id)=row.cells[0] {sources[String(decoding:id,as:UTF8.self)]=record};result.append(record)
        }
        for table in SyncCanonicalTable.allCases where table != .source {for row in try rows(table) {result.append(try make(table,row))}}
        for record in result {records[try record.identity.key.digest]=record};return result
    }
    func resolve(_ id:SyncObjectIdentity,_ version:SyncContentReference?)throws->SyncPortableRecord {
        guard let record=records[try id.key.digest] else {throw OSwindError.invalid("Owned dependency absent")};return record
    }
    func note(_ text:String="authored")throws->SyncPortableRecord {
        try .init(identity:identity(.source,sourceID),body:.source(.init(memory:Memory(id:sourceID,timestamp:now,kind:.note,text:text),origin:origin,media:[]) {_,_ in throw OSwindError.invalid("No recap expected")}))
    }
    func testActualCanonicalRowsFromAllThirteenTablesExportAndDecodeWithExactDependencies()throws {
        try seedGraph()
        let before=try Dictionary(uniqueKeysWithValues:SyncCanonicalTable.allCases.map {table in (table,try rows(table).map {try $0.encoded()})})
        let all=try prepareGraph();XCTAssertEqual(Set(all.map(\.identity.table)),Set(SyncCanonicalTable.allCases))
        for record in all {
            let data=try record.encoded();XCTAssertEqual(try SyncPortableRecord.decode(data,expected:record.reference),record);try record.validateDependencies(resolve:resolve)
            let text=String(decoding:data,as:UTF8.self)
            for local in [sourceID,sampleID,recipeID,conversationID,entityID,turnID,"owned-fake-endpoint.invalid","OWNED-FAKE-DEVICE"] {XCTAssertFalse(text.contains(local),record.identity.table.rawValue+" leaked local identity/config")}
        }
        XCTAssertEqual(try store.chats().count,1);XCTAssertEqual(try store.routines().count,1)
        for table in SyncCanonicalTable.allCases {XCTAssertEqual(try rows(table).map {try $0.encoded()},before[table],table.rawValue+" original row bytes changed")}
    }
    func testImmutableSourceReferenceRefusesLatestVersionSubstitution()throws {
        let original=try note("original evidence"),newer=try note("replacement evidence"),owner=try identity(.turn,"owned turn")
        let citation=try SyncPortableRecord(identity:identity(.conversationCitation,[.text(Data("owned turn".utf8)),.integer(0)]),body:.conversationCitation(.init(owner:owner,ordinal:0,link:.init(source:original.reference,score:1,match:"owned",passage:.init(start:0,length:8)))))
        let turn=try SyncPortableRecord(identity:owner,body:.turn(.init(conversation:identity(.conversation,"chat"),timestamp:now,question:"Question",text:"Answer",provider:"owned",duration:0,warnings:[],filter:SyncFilterBody(SearchFilter(),resolve:{_ in throw OSwindError.invalid("No entity")}),timeZone:nil)))
        XCTAssertThrowsError(try citation.validateDependencies {id,_ in id==owner ? turn:newer})
        XCTAssertNoThrow(try citation.validateDependencies {id,_ in id==owner ? turn:original})
    }
    func testCanonicalDecoderRefusesUnknownFieldsWhitespaceAndWrongContentOrIdentity()throws {
        let record=try note(),data=try record.encoded();var value=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]);value["endpoint"]="https://owned.invalid"
        XCTAssertThrowsError(try SyncPortableRecord.decode(JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.withoutEscapingSlashes])))
        XCTAssertThrowsError(try SyncPortableRecord.decode(Data(" ".utf8)+data))
        let different=try note("different");XCTAssertThrowsError(try SyncPortableRecord.decode(data,expected:different.reference))
        let identity=try self.identity(.source,"other");XCTAssertThrowsError(try SyncPortableRecord.decode(data,expected:.init(identity:identity,content:record.reference.content)))
    }
    func testRecipeTransportOmitsDeviceAuthorityAndHistoryDoesNotPretendOldDefinitionExists()throws {
        try seedGraph();let all=try prepareGraph()
        let recipe=try XCTUnwrap(all.first(where:{$0.identity.table == .routine}));guard case .routine(let body)=recipe.body else {return XCTFail("Missing recipe")}
        let projected=try body.projected(id:"receiver-local-recipe");XCTAssertFalse(projected.enabled);XCTAssertFalse(projected.allowRemote);XCTAssertEqual(projected.ai,AIConfiguration())
        let data=String(decoding:try recipe.encoded(),as:UTF8.self);for key in ["endpoint","allowRemote","enabled","next_due","recipe-model"] {XCTAssertFalse(data.contains(key))}
        let run=try XCTUnwrap(all.first(where:{$0.identity.table == .routineRun}));guard case .routineRun(let history)=run.body else {return XCTFail("Missing history")}
        XCTAssertEqual(history.recipe.ordinal,1);XCTAssertNil(history.recipe.definition);XCTAssertEqual(history.recipe.routine,recipe.identity);XCTAssertEqual(history.status,.failed)
        var lookup:[SyncContentReference?]=[];try run.validateDependencies {id,version in lookup.append(version);return try self.resolve(id,version)};XCTAssertTrue(lookup.contains(where:{$0==nil}))
    }
    func testPortableSourcePreservesDatesAndOriginalUnicodeWithoutLocalCachesOrPaths()throws {
        var memory=Memory(id:sourceID,timestamp:now,kind:.note,app:"Owned",title:"e\u{301}\0title",text:"e\u{301} and é\0authored",favorite:true,tags:["Owned"])
        memory.embedding=[1,2];memory.embeddingModel="/Users/OWNED-FAKE-DEVICE/local-model"
        let source=try SyncSourceBody(memory:memory,origin:origin,media:[]) {_,_ in throw OSwindError.invalid("No recap")}
        let record=try SyncPortableRecord(identity:identity(.source,sourceID),body:.source(source));let decoded=try SyncPortableRecord.decode(record.encoded());guard case .source(let restored)=decoded.body else {return XCTFail("Missing source")}
        let local=try restored.projectedMemory(id:"destination",paths:[:]) {_ in throw OSwindError.invalid("No recap")}
        XCTAssertEqual(local.timestamp.timeIntervalSinceReferenceDate.bitPattern,memory.timestamp.timeIntervalSinceReferenceDate.bitPattern);XCTAssertEqual(Data(local.text.utf8),Data(memory.text.utf8));XCTAssertEqual(Data(local.title.utf8),Data(memory.title.utf8));XCTAssertNil(local.embedding);XCTAssertNil(local.embeddingModel);XCTAssertNil(local.searchPreview)
        XCTAssertFalse(String(decoding:try record.encoded(),as:UTF8.self).contains("OWNED-FAKE-DEVICE"))
    }
    func testUnpreparedOrInventedMediaCannotBecomeARecord()throws {
        var memory=Memory(id:sourceID,timestamp:now,kind:.note,text:"owned",imagePath:"media/owned.png")
        XCTAssertThrowsError(try SyncSourceBody(memory:memory,origin:origin,media:[]) {_,_ in throw OSwindError.invalid("No recap")})
        let data=Data("owned asset".utf8),manifest=try SyncMediaManifest(role:.image,sha256:SyncProtocolLimits.hex(data),bytes:Int64(data.count),chunks:[SyncContentReference(data:data)])
        XCTAssertNoThrow(try SyncSourceBody(memory:memory,origin:origin,media:[manifest]) {_,_ in throw OSwindError.invalid("No recap")})
        memory.imagePath=nil;XCTAssertThrowsError(try SyncSourceBody(memory:memory,origin:origin,media:[manifest]) {_,_ in throw OSwindError.invalid("No recap")})
    }
    func testStreamingAssetCanExceedRecordLimitAndVerifiesEveryChunkAndFullDigest()throws {
        let chunk=Data(repeating:0x4f,count:SyncMediaManifest.chunkBytes),reference=try SyncContentReference(data:chunk);var hash=SHA256()
        for _ in 0..<17 {hash.update(data:chunk)}
        let manifest=SyncMediaManifest(role:.video,sha256:hash.finalize().map {String(format:"%02x",$0)}.joined(),bytes:Int64(chunk.count)*17,chunks:Array(repeating:reference,count:17))
        XCTAssertGreaterThan(manifest.bytes,SyncProtocolLimits.contentBytes);var reads=0
        try manifest.verify {_ in reads+=1;return chunk};XCTAssertEqual(reads,17)
        XCTAssertThrowsError(try manifest.verify {_ in Data("corrupt".utf8)})
        let wrong=SyncMediaManifest(role:.video,sha256:String(repeating:"0",count:64),bytes:manifest.bytes,chunks:manifest.chunks);XCTAssertThrowsError(try wrong.verify {_ in chunk})
    }
    func testInvalidChunkLayoutsRefuseBeforeAnyRead()throws {
        let short=try SyncContentReference(data:Data("owned".utf8))
        for manifest in [SyncMediaManifest(role:.audio,sha256:short.sha256,bytes:10,chunks:[short,short]),.init(role:.audio,sha256:short.sha256,bytes:short.bytes+1,chunks:[short]),.init(role:.audio,sha256:short.sha256,bytes:0,chunks:[])] {
            var reads=0;XCTAssertThrowsError(try manifest.verify {_ in reads+=1;return Data()});XCTAssertEqual(reads,0)
        }
    }
    func fresh(_ table:SyncCanonicalTable)throws->SyncObjectIdentity {try .init(table:table,origin:origin,lifetime:UUID().uuidString.lowercased())}
    func changed(_ record:SyncPortableRecord,_ change:(inout [String:Any])->Void)throws->SyncPortableRecord {
        var packet=try XCTUnwrap(JSONSerialization.jsonObject(with:record.encoded()) as? [String:Any]);var body=try XCTUnwrap(packet["body"] as? [String:Any]);let name=try XCTUnwrap(body.keys.first);var tagged=try XCTUnwrap(body[name] as? [String:Any]);var fields=try XCTUnwrap(tagged["_0"] as? [String:Any]);change(&fields);tagged["_0"]=fields;body[name]=tagged;packet["body"]=body
        return try JSONDecoder().decode(SyncPortableRecord.self,from:JSONSerialization.data(withJSONObject:packet,options:[.sortedKeys,.withoutEscapingSlashes]))
    }
    func testPinRowsForOrdinaryAndSampledSourcesAreBothPreservedAndVersionBound()throws {
        try seedGraph();let all=try prepareGraph(),pins=all.filter {$0.identity.table == .evidencePin};XCTAssertEqual(pins.count,2)
        for pin in pins {try pin.validateDependencies(resolve:resolve)}
        let old=try XCTUnwrap(sources[sampleID]);var memory=try XCTUnwrap(store.get(sampleID));memory.endTimestamp=now.addingTimeInterval(4);memory.textObservation = .init(sessionID:memory.textObservation!.sessionID,samples:3,largestGapSeconds:2)
        let newer=try SyncPortableRecord(identity:old.identity,body:.source(.init(memory:memory,origin:origin,media:[]) {_,_ in throw OSwindError.invalid("No recap")}))
        let pin=try SyncPortableRecord(identity:fresh(.evidencePin),body:.evidencePin(.init(source:old.reference)))
        XCTAssertThrowsError(try pin.validateDependencies {_,_ in newer})
    }
    func testTypedRecapProjectsIntoAnotherOwnedStoreWithRewrittenVersionedSource()throws {
        try seedGraph();let all=try prepareGraph(),receiver=try MemoryStore(root:root.appendingPathComponent("receiver"));defer {try? receiver.close()}
        let original=try XCTUnwrap(sources[sourceID]);guard case .source(let originalBody)=original.body else {return XCTFail("No source")}
        let projected=try originalBody.projectedMemory(id:"receiver-local-original",paths:[:]) {_ in throw OSwindError.invalid("No recap")};try receiver.insert(projected)
        let recap=try XCTUnwrap(all.first {if case .source(let body)=$0.body {return body.recap != nil};return false});guard case .source(let recapBody)=recap.body else {return XCTFail("No recap")}
        let summary=try recapBody.projectedMemory(id:"receiver-local-recap",paths:[:]) {reference in
            XCTAssertEqual(reference,try original.reference);return (projected.id,projected.evidenceHash)
        }
        try receiver.insert(summary);let hits=try receiver.recapEvidence(summary.id);XCTAssertEqual(hits.map(\.id),[projected.id]);XCTAssertEqual(hits.first?.memory.text,"Alice owns Orion.")
        XCTAssertEqual(summary.recap?.sources.first?.revision,projected.evidenceHash)
        let old=try XCTUnwrap(store.get(recapID));XCTAssertNotEqual(summary.evidenceHash,old.evidenceHash,"Rewriting recap IDs requires a local/wire version binding")
    }
    func testSourcePayloadColumnDisagreementAndWrongLifetimeRefuse()throws {
        try seedGraph();_=try prepareGraph();let row=try XCTUnwrap(rows(.source).first {if case .text(let id)=$0.cells[0] {return id==Data(sourceID.utf8)};return false})
        for index in [1,2,3,4,5,6,7] {
            var cells=row.cells
            switch index {case 1:if case .real(let bits)=cells[index] {cells[index] = .real(Double(bitPattern:bits).nextUp.bitPattern)}else {cells[index] = .real(0)};case 7:cells[index] = .integer(2);default:cells[index] = .text(Data("wrong owned metadata".utf8))}
            XCTAssertThrowsError(try make(.source,SyncRowSnapshot(cells)),"column \(index)")
        }
        XCTAssertThrowsError(try exporter().record(identity:fresh(.source),row:row))
        var cells=row.cells;cells[0] = .integer(1);XCTAssertThrowsError(try make(.source,SyncRowSnapshot(cells)))
    }
    func testCitationPartialRangeFractionalOrdinalAndInvalidScoreRefuse()throws {
        try seedGraph();_=try prepareGraph();let row=try XCTUnwrap(rows(.conversationCitation).first)
        for (index,value) in [(2,SyncRowCell.real(Double(0).bitPattern)),(3,.real(Double.infinity.bitPattern)),(5,.null)] {
            var cells=row.cells;cells[index]=value;XCTAssertThrowsError(try make(.conversationCitation,SyncRowSnapshot(cells)))
        }
        var cells=row.cells;cells[2] = .integer(60);XCTAssertThrowsError(try make(.conversationCitation,SyncRowSnapshot(cells)))
    }
    func testPreviewIsRefusedBeforeAnySourceTransport()throws {
        let transcript=SpeechTranscript(text:"Owned speech",duration:1,segments:[.init(start:0,end:1,text:"Owned speech")],model:"owned-model")
        var memory=Memory(id:sourceID,timestamp:now,kind:.audio,text:transcript.text);memory.transcript=transcript;memory.searchPreview=MemorySearchPreview(memory:memory,transcript:transcript)
        XCTAssertThrowsError(try SyncSourceBody(memory:memory,origin:origin,media:[]) {_,_ in throw OSwindError.invalid("No recap")})
    }
    func testModelLocatorsAndAudioSessionPathsStayOffWire()throws {
        let text="Owned speech";var memory=Memory(id:sourceID,timestamp:now,kind:.audio,text:text);memory.transcript = .init(text:text,duration:1,segments:[.init(start:0,end:1,text:text)],model:"/Users/OWNED-FAKE-DEVICE/model");memory.audioSessionID="/Users/OWNED-FAKE-DEVICE/session"
        let body=try SyncSourceBody(memory:memory,origin:origin,media:[]) {_,_ in throw OSwindError.invalid("No recap")};let record=try SyncPortableRecord(identity:fresh(.source),body:.source(body))
        XCTAssertEqual(body.transcript?.model,"peer-unspecified");XCTAssertFalse(String(decoding:try record.encoded(),as:UTF8.self).contains("OWNED-FAKE-DEVICE"))
        let token=try XCTUnwrap(body.audioSession);XCTAssertEqual(token,try SyncSessionToken(origin:origin,localID:memory.audioSessionID!));XCTAssertNotEqual(token,try SyncSessionToken(origin:"00000000-0000-0000-0000-000000000199",localID:memory.audioSessionID!))
        let bad=try changed(record) {fields in var speech=fields["transcript"] as! [String:Any];speech["model"]="file:///Users/OWNED-FAKE-DEVICE/model";fields["transcript"]=speech};XCTAssertThrowsError(try bad.encoded())
    }
    func testTranscriptMustMatchOriginalTextBytesNotUnicodeEquivalentText()throws {
        var memory=Memory(id:sourceID,timestamp:now,kind:.audio,text:"é")
        memory.transcript = .init(text:"e\u{301}",duration:1,segments:[.init(start:0,end:1,text:"e\u{301}")],model:"owned")
        XCTAssertThrowsError(try SyncSourceBody(memory:memory,origin:origin,media:[]) {_,_ in throw OSwindError.invalid("No recap")})
    }
    func testSampledSourceAndRegionSemanticValidationRunsBeforeEncoding()throws {
        try seedGraph();_=try prepareGraph();let sampled=try XCTUnwrap(sources[sampleID])
        let bad=try changed(sampled) {fields in var span=fields["textObservation"] as! [String:Any];span["samples"]=1001;fields["textObservation"]=span};XCTAssertThrowsError(try bad.encoded())
        let wrong=try changed(sampled) {$0["kind"]="note"};XCTAssertThrowsError(try wrong.encoded())
        let note=try self.note(),region=try changed(note) {$0["regions"]=[["text":"owned","x": -0.1,"y":0,"width":0.1,"height":0.1]]};XCTAssertThrowsError(try region.encoded())
    }
    func testMentionRequiresExactAnchoredSourceVersionAndCompleteGrapheme()throws {
        let source=try note("👩🏽‍💻 é"),entity=try SyncPortableRecord(identity:fresh(.entity),body:.entity(.init(kind:.person,name:"Alice",detail:"",curated:true,created:now)))
        func mention(_ range:PassageRange,_ surface:String)throws->SyncPortableRecord {try .init(identity:fresh(.entityMention),body:.entityMention(.init(source:source.reference,entity:entity.identity,origin:.automatic,passage:range,surface:surface,method:"peer suggestion")))}
        let valid=try mention(.init(start:0,length:"👩🏽‍💻".utf16.count),"👩🏽‍💻");XCTAssertNoThrow(try valid.validateDependencies {id,_ in id==source.identity ? source:entity})
        let partial=try mention(.init(start:0,length:2),"👩");XCTAssertThrowsError(try partial.validateDependencies {id,_ in id==source.identity ? source:entity})
        let normalized=try mention(.init(start:"👩🏽‍💻 ".utf16.count,length:1),"e\u{301}");XCTAssertThrowsError(try normalized.validateDependencies {id,_ in id==source.identity ? source:entity})
    }
    func testAliasAndProjectRejectionMustMatchTheReferencedEntityKind()throws {
        let source=try note(),entity=try SyncPortableRecord(identity:fresh(.entity),body:.entity(.init(kind:.person,name:"Alice",detail:"",curated:true,created:now)))
        let alias=try SyncPortableRecord(identity:fresh(.entityAlias),body:.entityAlias(.init(entity:entity.identity,kind:.project,key:"alice",label:"Alice")));XCTAssertThrowsError(try alias.validateDependencies {_,_ in entity})
        let rejection=try SyncPortableRecord(identity:fresh(.projectRejection),body:.projectRejection(.init(source:source.reference,entity:entity.identity)));XCTAssertThrowsError(try rejection.validateDependencies {id,_ in id==source.identity ? source:entity})
        XCTAssertThrowsError(try SyncPortableRecord(identity:fresh(.entityAlias),body:.entityAlias(.init(entity:entity.identity,kind:.person,key:"ALICE",label:"Alice"))))
    }
    func testRecapCitationCannotSubstituteAnotherOwnerLinkAndRecapCannotCiteItself()throws {
        try seedGraph();let all=try prepareGraph(),citation=try XCTUnwrap(all.first {$0.identity.table == .recapCitation})
        let altered=try changed(citation) {fields in var link=fields["link"] as! [String:Any];link["score"]=0.25;fields["link"]=link};XCTAssertThrowsError(try altered.validateDependencies(resolve:resolve))
        let recap=try XCTUnwrap(all.first {if case .source(let v)=$0.body {return v.recap != nil};return false})
        let selfCiting=try changed(recap) {fields in var provenance=fields["recap"] as! [String:Any];var sources=provenance["sources"] as! [[String:Any]];var link=sources[0];var reference=link["source"] as! [String:Any];reference["identity"]=try! JSONSerialization.jsonObject(with:JSONEncoder().encode(recap.identity));link["source"]=reference;sources[0]=link;provenance["sources"]=sources;fields["recap"]=provenance};XCTAssertThrowsError(try selfCiting.encoded())
    }
    func testKnownHistoricalRecipeVersionCannotFallBackToCurrentDefinition()throws {
        let old=try SyncPortableRecord(identity:fresh(.routine),body:.routine(SyncRoutineBody(RoutineDefinition())))
        var definition=RoutineDefinition();definition.prompt="Different current definition";let current=try SyncPortableRecord(identity:old.identity,body:.routine(SyncRoutineBody(definition)))
        let run=try SyncPortableRecord(identity:fresh(.routineRun),body:.routineRun(.init(recipe:.init(routine:old.identity,editorOrigin:origin,ordinal:1,definition:old.reference.content),scheduledAt:now,started:now,finished:nil,trigger:.scheduled,status:.running,conversation:nil,message:nil,filter:SyncFilterBody(SearchFilter(),resolve:{_ in throw OSwindError.invalid("No entity")}))))
        XCTAssertThrowsError(try run.validateDependencies {_,_ in current});XCTAssertNoThrow(try run.validateDependencies {_,_ in old})
        guard case .routineRun(let body)=run.body else {return XCTFail("No run")};XCTAssertEqual(body.status,.running);XCTAssertEqual(body.projectedStatus,.interrupted)
    }
    func testMediaOrderingIsDeterministicAndProjectionRequiresExactAdmittedRoles()throws {
        let data=Data("owned".utf8),ref=try SyncContentReference(data:data),video=VisualRecording(duration:1,width:2,height:2,codec:"hevc",hardwareRequired:true,frames:[.init(time:0,text:"owned")])
        var memory=Memory(id:sourceID,timestamp:now,kind:.screen,text:video.text,imagePath:"media/poster",audioPath:"media/audio");memory.videoPath="media/video";memory.visualRecording=video
        let media=SyncMediaRole.allCases.map {SyncMediaManifest(role:$0,sha256:ref.sha256,bytes:ref.bytes,chunks:[ref])}
        let a=try SyncSourceBody(memory:memory,origin:origin,media:media) {_,_ in throw OSwindError.invalid("No recap")},b=try SyncSourceBody(memory:memory,origin:origin,media:Array(media.reversed())) {_,_ in throw OSwindError.invalid("No recap")}
        XCTAssertEqual(try SyncProtocolLimits.encode(a),try SyncProtocolLimits.encode(b))
        XCTAssertThrowsError(try a.projectedMemory(id:"receiver",paths:[.image:"media/poster"]) {_ in throw OSwindError.invalid("No recap")})
        XCTAssertNoThrow(try a.projectedMemory(id:"receiver",paths:[.image:"media/poster",.audio:"media/audio",.video:"media/video"]) {_ in throw OSwindError.invalid("No recap")})
    }
    func testProjectedAudioSessionRequiresItsExplicitBindingAndThenRoundTripsExactly()throws {
        var memory=Memory(id:sourceID,timestamp:now,kind:.audio,text:"Owned speech");memory.audioSessionID="owned-original-session";memory.transcript = .init(text:memory.text,duration:1,segments:[.init(start:0,end:1,text:memory.text)],model:"owned")
        let first=try SyncSourceBody(memory:memory,origin:origin,media:[]) {_,_ in throw OSwindError.invalid("No recap")}
        let projected=try first.projectedMemory(id:"receiver-source",paths:[:]) {_ in throw OSwindError.invalid("No recap")}
        let second=try SyncSourceBody(memory:projected,origin:origin,media:[],sessionBinding:first.audioSession) {_,_ in throw OSwindError.invalid("No recap")}
        XCTAssertEqual(try SyncProtocolLimits.encode(first),try SyncProtocolLimits.encode(second))
        try store.insert(projected)
        let originalID=try identity(.source,sourceID),original=try SyncPortableRecord(identity:originalID,body:.source(first))
        let roundTrip=SyncPortableExporter(references:.init(identity:{table,primary in
            XCTAssertEqual(table,.source);XCTAssertEqual(primary,[.text(Data(projected.id.utf8))]);return originalID
        },source:{_,_ in throw OSwindError.invalid("No recap")},media:{_ in []},recipe:{_,_ in throw OSwindError.invalid("No recipe")},session:{value in
            XCTAssertEqual(value.audioSessionID,first.audioSession?.localProjection);return first.audioSession
        }))
        let encoded=try roundTrip.record(identity:originalID,row:XCTUnwrap(rows(.source).first)).encoded();XCTAssertEqual(encoded,try original.encoded())
        let wrong=try SyncSessionToken(origin:origin,localID:"different local session")
        XCTAssertThrowsError(try SyncSourceBody(memory:projected,origin:origin,media:[],sessionBinding:wrong) {_,_ in throw OSwindError.invalid("No recap")})
        var absent=projected;absent.audioSessionID=nil
        XCTAssertThrowsError(try SyncSourceBody(memory:absent,origin:origin,media:[],sessionBinding:first.audioSession) {_,_ in throw OSwindError.invalid("No recap")})
    }
    func testRecapMetadataMustRemainAdmissibleBeforeLocalProjection()throws {
        try seedGraph();let all=try prepareGraph();let recap=try XCTUnwrap(all.first {if case .source(let body)=$0.body {return body.recap != nil};return false})
        let provider=try changed(recap) {fields in var provenance=fields["recap"] as! [String:Any];provenance["provider"]="owned\0provider";fields["recap"]=provenance};XCTAssertThrowsError(try provider.encoded())
        let match=try changed(recap) {fields in var provenance=fields["recap"] as! [String:Any];var sources=provenance["sources"] as! [[String:Any]];sources[0]["match"]=String(repeating:"x",count:129);provenance["sources"]=sources;fields["recap"]=provenance};XCTAssertThrowsError(try match.encoded())
    }
    func testUnsupportedVersionMismatchedKindAndNestedDevicePathRefuse()throws {
        let record=try note(),bytes=try record.encoded();let original=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        for (field,value) in [("version",2 as Any),("format","unknown" as Any)] {
            var packet=original;packet[field]=value;let data=try JSONSerialization.data(withJSONObject:packet,options:[.sortedKeys,.withoutEscapingSlashes]);let value=try JSONDecoder().decode(SyncPortableRecord.self,from:data);XCTAssertThrowsError(try value.encoded())
        }
        var packet=original,identity=packet["identity"] as! [String:Any];identity["table"]="chat_sessions";packet["identity"]=identity;let wrong=try JSONDecoder().decode(SyncPortableRecord.self,from:JSONSerialization.data(withJSONObject:packet));XCTAssertThrowsError(try wrong.encoded())
        packet=original;var body=packet["body"] as! [String:Any],source=body["source"] as! [String:Any],fields=source["_0"] as! [String:Any];fields["imagePath"]="/Users/OWNED-FAKE-DEVICE/image";source["_0"]=fields;body["source"]=source;packet["body"]=body
        XCTAssertThrowsError(try SyncPortableRecord.decode(JSONSerialization.data(withJSONObject:packet,options:[.sortedKeys,.withoutEscapingSlashes])))
    }
}
