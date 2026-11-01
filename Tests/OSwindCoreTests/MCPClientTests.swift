import XCTest
import Darwin
@testable import OSwindCore

final class MCPClientTests:XCTestCase {
    private var root:URL!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-mcp-fixture-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)}
    override func tearDownWithError()throws {if let root {try? FileManager.default.removeItem(at:root)}}
    private func command(_ mode:String)throws->MCPServerCommand {
        let script=root.appendingPathComponent("server.py");try Self.fixture.write(to:script,atomically:true,encoding:.utf8)
        return .init(executable:"/usr/bin/python3",arguments:[script.path,mode,root.path])
    }
    private func events()throws->[[String:Any]] {
        let p=root.appendingPathComponent("events.jsonl");guard FileManager.default.fileExists(atPath:p.path) else {return []}
        return try String(contentsOf:p).split(separator:"\n").map {try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
    }
    private func assertRefuses(_ mode:String) async throws {
        let before=try events().filter {$0["method"] as? String=="tools/call"}.count,c=try command(mode)
        do {_ = try await MCPClient.discover(c);XCTFail("Accepted "+mode)}catch is CancellationError {XCTFail("Unexpected cancellation")}catch {}
        XCTAssertEqual(try events().filter {$0["method"] as? String=="tools/call"}.count,before)
    }
    func testModernDiscoveryAndExplicitCallCarryRequestMetadataAndProvenance() async throws {
        let c=try command("modern"),review=try await MCPClient.discover(c)
        XCTAssertEqual(review.protocolVersion,"2026-07-28");XCTAssertEqual(review.tools.map(\.name),["echo"])
        let output=try await MCPClient.call(c,review:review,tool:"echo",argumentsJSON:Data(#"{"text":"owned café"}"#.utf8))
        XCTAssertEqual(output.text,"owned café");XCTAssertFalse(output.isError);XCTAssertEqual(output.commandFingerprint,review.commandFingerprint);XCTAssertEqual(output.toolFingerprint,review.tools[0].fingerprint)
        let requests=try events().filter {$0["method"] != nil};XCTAssertFalse(requests.contains {$0["method"] as? String=="initialize"})
        XCTAssertEqual(requests.filter {$0["method"] as? String=="tools/call"}.count,1)
        for e in requests {let params=e["params"] as? [String:Any],meta=params?["_meta"] as? [String:Any];XCTAssertEqual(meta?["io.modelcontextprotocol/protocolVersion"] as? String,"2026-07-28");XCTAssertNotNil(meta?["io.modelcontextprotocol/clientCapabilities"])}
    }
    func testLegacyUnknownPreinitializeErrorFallsBackWithoutSpecificCodeAssumption() async throws {
        let c=try command("legacy-error"),r=try await MCPClient.discover(c);XCTAssertEqual(r.protocolVersion,"2025-11-25")
        let out=try await MCPClient.call(c,review:r,tool:"echo",argumentsJSON:Data("{}".utf8));XCTAssertEqual(out.text,"empty")
        XCTAssertEqual(try events().filter {$0["method"] as? String=="notifications/initialized"}.count,2)
    }
    func testSilentLegacyProbeTimeoutFallsBack() async throws {
        let r=try await MCPClient.discover(command("legacy-silent"));XCTAssertEqual(r.protocolVersion,"2025-11-25")
    }
    func testLateProbeReplyIsDiscardedWithoutAdmittingWrongResponseID() async throws {
        let r=try await MCPClient.discover(command("late-probe"));XCTAssertEqual(r.protocolVersion,"2025-11-25")
    }
    func testModernUnsupportedVersionNeverFallsBackToInitialize() async throws {
        try await assertRefuses("modern-unsupported");XCTAssertFalse(try events().contains {$0["method"] as? String=="initialize"})
    }
    func testWrongResponseIDAndAmbiguousEnvelopeRefuse() async throws {try await assertRefuses("wrong-id");try await assertRefuses("both-result-error")}
    func testDuplicateJSONKeysAndInvalidUTF8Refuse() async throws {try await assertRefuses("duplicate-key");try await assertRefuses("bad-utf8")}
    func testUnexpectedServerRequestCannotAuthorizeSamplingOrRoots() async throws {try await assertRefuses("server-request")}
    func testFrameAndStderrFloodsAreBounded() async throws {try await assertRefuses("large-frame");try await assertRefuses("stderr-flood")}
    func testNotificationFloodIsBounded() async throws {try await assertRefuses("notification-flood")}
    func testPaginationAndDuplicateToolNamesRefuseWithoutReturningTruncatedList() async throws {
        try await assertRefuses("cursor-cycle");try await assertRefuses("duplicate-tool")
    }
    func testToolSchemaChangeRequiresNewReviewBeforeAnyCall() async throws {
        let c=try command("schema-change"),r=try await MCPClient.discover(c)
        try Data("changed".utf8).write(to:root.appendingPathComponent("changed"))
        do {_ = try await MCPClient.call(c,review:r,tool:"echo",argumentsJSON:Data("{}".utf8));XCTFail("Accepted changed tool")}catch {}
        XCTAssertFalse(try events().contains {$0["method"] as? String=="tools/call"})
    }
    func testExecutableChangeRefusesBeforeLaunchingNewBytes() async throws {
        var c=try command("modern");let wrapper=root.appendingPathComponent("owned-executable")
        try "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".write(to:wrapper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path);c.executable=wrapper.path
        let r=try await MCPClient.discover(c),before=try events().count
        try ("#!/bin/sh\ntouch "+root.appendingPathComponent("changed-launched").path+"\nexit 99\n").write(to:wrapper,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path);XCTAssertTrue(FileManager.default.isExecutableFile(atPath:wrapper.path))
        do {_ = try await MCPClient.call(c,review:r,tool:"echo",argumentsJSON:Data("{}".utf8));XCTFail("Launched changed executable")}catch {}
        XCTAssertEqual(try events().count,before);XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("changed-launched").path))
    }
    func testUnreviewedToolAndMalformedArgumentsDoNotLaunch() async throws {
        let c=try command("modern"),r=try await MCPClient.discover(c),before=try events().count
        do {_ = try await MCPClient.call(c,review:r,tool:"unknown",argumentsJSON:Data("{}".utf8));XCTFail()}catch {}
        do {_ = try await MCPClient.call(c,review:r,tool:"echo",argumentsJSON:Data(#"{"x":1,"x":2}"#.utf8));XCTFail()}catch {}
        XCTAssertEqual(try events().count,before)
    }
    func testMinimalEnvironmentUsesOnlyExplicitFixtureCredentialAndOwnedHome() async throws {
        var c=try command("environment");c.credentialNames=["OSWIND_TEST_CREDENTIAL"]
        let r=try await MCPClient.discover(c,credentials:["OSWIND_TEST_CREDENTIAL":"owned-secret"])
        let e=try events().first {$0["environment"] != nil}!,env=e["environment"] as! [String:String]
        // Apple's /usr/bin/python3 shim adds SDK search variables; these are
        // not inherited application secrets. The parent probe is planted by
        // the qualification command, never read from a real credential.
        XCTAssertNil(env["OSWIND_TEST_PARENT_SECRET"]);XCTAssertEqual(env["OSWIND_TEST_CREDENTIAL"],"owned-secret");XCTAssertNotEqual(env["HOME"],FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertTrue(Set(env.keys).isSubset(of:["PATH","HOME","TMPDIR","LANG","OSWIND_TEST_CREDENTIAL","LC_CTYPE","CPATH","LIBRARY_PATH","MANPATH","SDKROOT","__CF_USER_TEXT_ENCODING"]),"Observed environment keys: "+env.keys.sorted().joined(separator:","))
        XCTAssertFalse(String(decoding:try JSONEncoder().encode(r),as:UTF8.self).contains("owned-secret"))
        do {_ = try await MCPClient.discover(c,credentials:["UNRELATED":"owned-secret"]);XCTFail()}catch {}
    }
    func testCancelledCallTerminatesAndReapsOwnedChildWithoutReplay() async throws {
        let c=try command("block-call"),r=try await MCPClient.discover(c)
        let task=Task {try await MCPClient.call(c,review:r,tool:"echo",argumentsJSON:Data("{}".utf8))}
        let deadline=ContinuousClock.now.advanced(by:.seconds(8));var pid:Int32?
        while ContinuousClock.now<deadline {if let event=try events().first(where:{$0["method"] as? String=="tools/call"}),let value=event["pid"] as? Int32 {pid=value;break};try await Task.sleep(for:.milliseconds(20))}
        XCTAssertNotNil(pid);task.cancel()
        do {_ = try await task.value;XCTFail("Cancellation returned a result")}catch is CancellationError {}catch {XCTFail("Unexpected error: \(error)")}
        if let pid {XCTAssertEqual(kill(pid,0),-1);XCTAssertEqual(errno,ESRCH)}
        XCTAssertEqual(try events().filter {$0["method"] as? String=="tools/call"}.count,1)
    }
    func testInputRequiredAndProtocolErrorsNeverReplayCall() async throws {
        for mode in ["input-required","call-error","exit-call"] {
            let c=try command(mode),r=try await MCPClient.discover(c),before=try events().filter {$0["method"] as? String=="tools/call"}.count
            do {_ = try await MCPClient.call(c,review:r,tool:"echo",argumentsJSON:Data("{}".utf8));XCTFail(mode)}catch {}
            XCTAssertEqual(try events().filter {$0["method"] as? String=="tools/call"}.count,before+1)
        }
        let c=try command("tool-error-result"),r=try await MCPClient.discover(c)
        let result=try await MCPClient.call(c,review:r,tool:"echo",argumentsJSON:Data("{}".utf8))
        XCTAssertTrue(result.isError);XCTAssertEqual(result.text,"empty")
    }
    func testFragmentedUTF8FramesRemainExactAndPartialEOFRefuses() async throws {
        let c=try command("split-utf8"),r=try await MCPClient.discover(c)
        let out=try await MCPClient.call(c,review:r,tool:"echo",argumentsJSON:Data(#"{"text":"café 🔎"}"#.utf8));XCTAssertEqual(out.text,"café 🔎")
        try await assertRefuses("partial-eof")
    }
    func testFinitePaginationReturnsEveryToolWithoutFetchingIcons() async throws {
        let r=try await MCPClient.discover(command("two-pages"));XCTAssertEqual(r.tools.map(\.name),["echo","other"])
        XCTAssertEqual(try events().filter {$0["method"] as? String=="tools/list"}.count,2)
    }
    func testForgedReviewDisplayMetadataRefusesBeforeLaunching() async throws {
        let c=try command("modern"),r=try await MCPClient.discover(c),before=try events().count
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(r)) as! [String:Any]
        var tools=object["tools"] as! [[String:Any]];tools[0]["description"]="Forged safe description";object["tools"]=tools
        let forged=try JSONDecoder().decode(MCPToolReview.self,from:JSONSerialization.data(withJSONObject:object))
        do {_ = try await MCPClient.call(c,review:forged,tool:"echo",argumentsJSON:Data("{}".utf8));XCTFail("Accepted mismatched review text")}catch {}
        XCTAssertEqual(try events().count,before)
    }
    func testCallTimeoutDoesNotReplayAndReapsOwnedChild() async throws {
        let c=try command("timeout-call"),r=try await MCPClient.discover(c)
        do {_ = try await MCPClient.call(c,review:r,tool:"echo",argumentsJSON:Data("{}".utf8));XCTFail("Timeout returned success")}catch {XCTAssertFalse(error is CancellationError)}
        let calls=try events().filter {$0["method"] as? String=="tools/call"};XCTAssertEqual(calls.count,1)
        if let pid=calls.first?["pid"] as? Int32 {XCTAssertEqual(kill(pid,0),-1);XCTAssertEqual(errno,ESRCH)}else {XCTFail("Missing owned PID")}
    }
    func testArbitraryLegacyErrorCodeFallsBackButModernHeaderErrorDoesNot() async throws {
        let r=try await MCPClient.discover(command("legacy-arbitrary-error"));XCTAssertEqual(r.protocolVersion,"2025-11-25")
        let before=try events().filter {$0["method"] as? String=="initialize"}.count
        try await assertRefuses("modern-header-error");XCTAssertEqual(try events().filter {$0["method"] as? String=="initialize"}.count,before)
        try await assertRefuses("fractional-error-code");XCTAssertEqual(try events().filter {$0["method"] as? String=="initialize"}.count,before)
    }
    func testPublicReviewJSONRoundTripsThroughCLIISOEncoding() async throws {
        let r=try await MCPClient.discover(command("modern"))
        let object=try Integration.json(r),data=try JSONSerialization.data(withJSONObject:object)
        XCTAssertEqual(try MCPToolReview.decodeReview(data),r)
        XCTAssertEqual(try MCPToolReview.decodeReview(JSONEncoder().encode(r)),r)
    }
    func testReviewCatalogIsReadableAndRoundTripsOrRefusesBeforePublication() async throws {
        let small=try command("small-catalog"),review=try await MCPClient.discover(small)
        let object=try Integration.json(review) as! [String:Any],tools=object["tools"] as! [[String:Any]]
        XCTAssertEqual(tools.count,16)
        XCTAssertTrue((tools[0]["definitionJSON"] as? String)?.hasPrefix("{")==true,"A reviewer must see literal tool/schema JSON, not an opaque blob")
        XCTAssertEqual(try MCPToolReview.decodeReview(JSONEncoder().encode(review)),review)
        let output=try await MCPClient.call(small,review:review,tool:review.tools[0].name,argumentsJSON:Data("{}".utf8));XCTAssertEqual(output.text,"empty")
        let before=try events().count,large=try command("large-catalog")
        do {_ = try await MCPClient.discover(large);XCTFail("Accepted a catalog beyond the aggregate review bound")}
        catch {XCTAssertTrue(error.localizedDescription.contains("aggregate review"),"Wrong refusal: "+error.localizedDescription)}
        XCTAssertEqual(try events().dropFirst(before).filter {$0["method"] as? String=="tools/list"}.count,8)
    }
    func testUnsupportedReviewProtocolRefusesBeforeAnyProcessLaunch() async throws {
        let c=try command("modern"),review=try await MCPClient.discover(c),before=try events().count
        var object=try Integration.json(review) as! [String:Any];object["protocolVersion"]="2099-01-01"
        let forged=try JSONDecoder().decode(MCPToolReview.self,from:JSONSerialization.data(withJSONObject:object))
        do {_ = try await MCPClient.call(c,review:forged,tool:"echo",argumentsJSON:Data("{}".utf8));XCTFail("Accepted unsupported reviewed protocol")}catch {}
        XCTAssertEqual(try events().count,before)
    }
    func testCancellationSendsMatchingProtocolNotificationBeforeGracefulExit() async throws {
        let c=try command("cancel-notification"),review=try await MCPClient.discover(c)
        let task=Task {try await MCPClient.call(c,review:review,tool:"echo",argumentsJSON:Data("{}".utf8))}
        let end=ContinuousClock.now.advanced(by:.seconds(8));var request:[String:Any]?
        while ContinuousClock.now<end {if let found=try events().first(where:{$0["method"] as? String=="tools/call"}) {request=found;break};try await Task.sleep(for:.milliseconds(20))}
        XCTAssertNotNil(request);task.cancel()
        do {_ = try await task.value;XCTFail("Cancelled call produced a result")}catch is CancellationError {}catch {XCTFail("Unexpected cancellation error")}
        let notes=try events().filter {$0["method"] as? String=="notifications/cancelled"};XCTAssertEqual(notes.count,1)
        let params=notes.first?["params"] as? [String:Any];XCTAssertEqual(params?["requestId"] as? String,request?["id"] as? String)
    }
    private static let fixture = #"""
import os,sys,json,time,signal
mode,root=sys.argv[1:]
def log(v):
 v['pid']=os.getpid()
 with open(root+'/events.jsonl','a') as f:f.write(json.dumps(v)+'\n')
def send(v):
 if mode=='split-utf8':
  for byte in (json.dumps(v,ensure_ascii=False)+'\n').encode('utf-8'):sys.stdout.buffer.write(bytes([byte]));sys.stdout.buffer.flush();time.sleep(.0002)
 else:sys.stdout.write(json.dumps(v,ensure_ascii=False)+'\n');sys.stdout.flush()
if mode=='environment':log({'environment':{k:(v if k in ['HOME','TMPDIR','PATH','LANG','OSWIND_TEST_CREDENTIAL'] else '<present>')for k,v in os.environ.items()}})
for line in sys.stdin:
 q=json.loads(line);log(q);method=q['method'];i=q.get('id')
 if i is None:
  if mode=='cancel-notification' and method=='notifications/cancelled':sys.exit(0)
  continue
 if method=='server/discover':
  if mode=='legacy-silent':continue
  if mode in ['legacy-arbitrary-error','modern-header-error','fractional-error-code']:send({'jsonrpc':'2.0','id':i,'error':{'code':{'legacy-arbitrary-error':-32023,'modern-header-error':-32020,'fractional-error-code':-32602.5}[mode],'message':'owned refusal'}});continue
  if mode=='legacy-error':send({'jsonrpc':'2.0','id':i,'error':{'code':-32602,'message':'initialize first'}});continue
  if mode=='modern-unsupported':send({'jsonrpc':'2.0','id':i,'error':{'code':-32022,'message':'unsupported','data':{'supported':['2025-11-25'],'requested':'2026-07-28'}}});continue
  if mode=='partial-eof':sys.stdout.write('{\"jsonrpc\":');sys.stdout.flush();sys.exit(0)
  if mode=='wrong-id':send({'jsonrpc':'2.0','id':'wrong','result':{}});continue
  if mode=='both-result-error':send({'jsonrpc':'2.0','id':i,'result':{},'error':{'code':-1,'message':'bad'}});continue
  if mode=='duplicate-key':sys.stdout.write('{"jsonrpc":"2.0","id":'+json.dumps(i)+',"id":"other","result":{}}\n');sys.stdout.flush();continue
  if mode=='bad-utf8':sys.stdout.buffer.write(b'{"jsonrpc":"2.0","id":"\xff"}\n');sys.stdout.flush();continue
  if mode=='server-request':send({'jsonrpc':'2.0','id':'server','method':'sampling/createMessage','params':{}});continue
  if mode=='large-frame':sys.stdout.write('x'*270000+'\n');sys.stdout.flush();continue
  if mode=='stderr-flood':sys.stderr.write('x'*280000);sys.stderr.flush();continue
  if mode=='notification-flood':
   for n in range(65):send({'jsonrpc':'2.0','method':'notifications/message','params':{}})
  if mode=='late-probe':time.sleep(2.2)
  send({'jsonrpc':'2.0','id':i,'result':{'resultType':'complete','supportedVersions':['2026-07-28'],'capabilities':{'tools':{}}}})
 elif method=='initialize':send({'jsonrpc':'2.0','id':i,'result':{'protocolVersion':'2025-11-25','capabilities':{'tools':{}},'serverInfo':{'name':'owned','version':'1'}}})
 elif method=='tools/list':
  desc='changed' if os.path.exists(root+'/changed') else 'owned fixture'
  tool={'name':'echo','description':desc,'inputSchema':{'type':'object','properties':{'text':{'type':'string'}}},'annotations':{'readOnlyHint':True}}
  result={'resultType':'complete','tools':[tool]}
  if mode=='cursor-cycle':result['tools']=[];result['nextCursor']='repeat'
  if mode=='duplicate-tool':result['tools']=[tool,tool]
  if mode in ['small-catalog','large-catalog']:
   page=int(q.get('params',{}).get('cursor','0'));total=16 if mode=='small-catalog' else 128
   result['tools']=[{'name':'owned_'+str(n),'description':'x'*(4000 if total==16 else 8000),'inputSchema':{'type':'object'}}for n in range(page*16,(page+1)*16)]
   if (page+1)*16<total:result['nextCursor']=str(page+1)
  if mode=='two-pages':
   tool['icons']=[{'src':'https://never-fetch.invalid/icon.svg'}]
   if q.get('params',{}).get('cursor')=='second':tool['name']='other'
   else:result['nextCursor']='second'
  send({'jsonrpc':'2.0','id':i,'result':result})
 elif method=='tools/call':
  if mode=='cancel-notification':continue
  if mode in ['block-call','timeout-call']:
   signal.signal(signal.SIGTERM,signal.SIG_IGN)
   while True:time.sleep(0.1)
  if mode=='exit-call':sys.exit(17)
  if mode=='call-error':send({'jsonrpc':'2.0','id':i,'error':{'code':-32603,'message':'owned fixture error'}});continue
  if mode=='input-required':send({'jsonrpc':'2.0','id':i,'result':{'resultType':'input_required','inputRequests':{}}});continue
  send({'jsonrpc':'2.0','id':i,'result':{'resultType':'complete','content':[{'type':'text','text':q.get('params',{}).get('arguments',{}).get('text','empty')}],'isError':(mode=='tool-error-result')}})
"""#
}
