import XCTest
@testable import OSwindCore

private final class MeetingRequestProtocol:URLProtocol,@unchecked Sendable {
    private static let lock=NSLock()
    private static var handlers=[String:(URLRequest)throws->Data]()
    static func install(_ id:String,_ handler:@escaping (URLRequest)throws->Data) {lock.lock();defer {lock.unlock()};handlers[id]=handler}
    static func remove(_ id:String) {lock.lock();defer {lock.unlock()};handlers.removeValue(forKey:id)}
    override class func canInit(with request:URLRequest)->Bool {request.url?.host?.hasPrefix("owned-meeting-")==true && request.url?.host?.hasSuffix(".invalid")==true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        do {
            Self.lock.lock();let handler=(request.url?.host).flatMap {Self.handlers[$0]};Self.lock.unlock()
            guard let handler,let url=request.url else {throw URLError(.unsupportedURL)}
            let data=try handler(request),response=HTTPURLResponse(url:url,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
        }catch {client?.urlProtocol(self,didFailWithError:error)}
    }
    override func stopLoading() {}
}
private final class MeetingRequestCapture:@unchecked Sendable {
    private let lock=NSLock();private var requests=[Data]()
    func append(_ data:Data) {lock.lock();defer {lock.unlock()};requests.append(data)}
    func all()->[Data] {lock.lock();defer {lock.unlock()};return requests}
}
final class MeetingRequestTests:XCTestCase {
    func testCompatibleAdapterReceivesOnlySanitizedPermittedMeetingContext()async throws {
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("owned-meeting-request-"+UUID().uuidString);defer {try? fm.removeItem(at:root)}
        let store=try MemoryStore(root:root);defer {try? store.close()}
        let secret="sk-"+String(repeating:"B",count:32),allowed=Memory(id:"allowed",kind:.note,title:"Orion launch",text:"Mira owns the Orion launch. "+secret),blocked=Memory(id:"blocked",kind:.note,bundleID:"org.oswind.private",title:"Orion private",text:"DoNotSendPrivateContext")
        try store.insert(allowed);try store.insert(blocked)
        _=try store.saveRecap(.init(text:"DoNotSendDerivedContext [1]",sources:[.init(memory:blocked,score:1,match:"owned")],provider:"evidence",duration:0))
        var policy=PrivacyPolicy();policy.excludedApps.append(blocked.bundleID)
        let host="owned-meeting-"+UUID().uuidString.lowercased()+".invalid",capture=MeetingRequestCapture()
        MeetingRequestProtocol.install(host) {request in
            XCTAssertEqual(request.httpMethod,"POST");XCTAssertEqual(request.url?.path,"/v1/chat/completions");XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer owned-test-credential")
            var data=request.httpBody ?? Data()
            if data.isEmpty,let stream=request.httpBodyStream {
                stream.open();defer {stream.close()};var buffer=[UInt8](repeating:0,count:4096)
                while stream.hasBytesAvailable {let count=stream.read(&buffer,maxLength:buffer.count);guard count>=0 else {throw URLError(.cannotDecodeRawData)};if count==0 {break};data.append(contentsOf:buffer.prefix(count));guard data.count<=256*1024 else {throw URLError(.dataLengthExceedsMaximum)}}
            }
            capture.append(data)
            return try JSONSerialization.data(withJSONObject:["choices":[["finish_reason":"stop","message":["content":"Mira owns the launch [1]."]]]])
        };defer {MeetingRequestProtocol.remove(host)}
        let network=URLSessionConfiguration.ephemeral;network.protocolClasses=[MeetingRequestProtocol.self];let session=URLSession(configuration:network);defer {session.invalidateAndCancel()}
        var ai=AIConfiguration();ai.provider = .compatible;ai.model="owned-fixture";ai.endpoint="https://"+host+"/v1";ai.allowRemote=true
        let result=try await AnswerEngine(store:store,embedder:LocalEmbedder(),session:session).answer("Prepare the Orion meeting brief",configuration:ai,summarize:true,key:"owned-test-credential",interpretQuery:false,evidencePolicy:policy)
        XCTAssertEqual(result.sources.map(\.id),[allowed.id]);XCTAssertEqual(result.provider,"compatible")
        let body=try XCTUnwrap(capture.all().only),text=String(decoding:body,as:UTF8.self),json=try XCTUnwrap(JSONSerialization.jsonObject(with:body) as? [String:Any])
        XCTAssertFalse(text.contains(secret));XCTAssertFalse(text.contains("DoNotSendPrivateContext"));XCTAssertFalse(text.contains("DoNotSendDerivedContext"));XCTAssertTrue(text.contains("[REDACTED]"));XCTAssertTrue(text.contains("Mira owns"));XCTAssertEqual(json["store"] as? Bool,false)
    }
}
private extension Array {var only:Element? {count==1 ? first:nil}}
