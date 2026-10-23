import XCTest
import Darwin
@testable import OSwindCore

private final class ModelHTTPFixture:URLProtocol,@unchecked Sendable {
    struct Response:@unchecked Sendable {
        var status=200
        var chunks:[Data]
        var length:Int?
        var pause:Double=0
        var redirect:URLRequest?
        var error:Error?
        var requested:(@Sendable (URLRequest)->Void)?
    }
    private static let lock=NSLock()
    private static var fixtures=[String:Response]()
    private let stateLock=NSLock();private var stopped=false
    static func register(_ value:Response,at explicit:URL?=nil) -> URL {
        let url=explicit ?? URL(string:"https://model-fixture.invalid/"+UUID().uuidString)!
        lock.lock();fixtures[url.absoluteString]=value;lock.unlock();return url
    }
    override class func canInit(with request:URLRequest) -> Bool {true}
    override class func canonicalRequest(for request:URLRequest) -> URLRequest {request}
    override func startLoading() {
        Self.lock.lock();let fixture=Self.fixtures[request.url!.absoluteString];Self.lock.unlock()
        guard let fixture else {client?.urlProtocol(self,didFailWithError:URLError(.resourceUnavailable));return}
        fixture.requested?(request)
        var headers=[String:String]();if let length=fixture.length {headers["Content-Length"]=String(length)}
        let response=HTTPURLResponse(url:request.url!,statusCode:fixture.status,httpVersion:"HTTP/1.1",headerFields:headers)!
        if let redirect=fixture.redirect {client?.urlProtocol(self,wasRedirectedTo:redirect,redirectResponse:response);return}
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        send(fixture,index:0)
    }
    private func send(_ fixture:Response,index:Int) {
        stateLock.lock();let stopped=stopped;stateLock.unlock();guard !stopped else{return}
        if index<fixture.chunks.count {
            client?.urlProtocol(self,didLoad:fixture.chunks[index])
            DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+fixture.pause) { [weak self] in self?.send(fixture,index:index+1) }
        } else if let error=fixture.error {client?.urlProtocol(self,didFailWithError:error)}
        else {client?.urlProtocolDidFinishLoading(self)}
    }
    override func stopLoading() {stateLock.lock();stopped=true;stateLock.unlock()}
}
final class NativeModelHTTPTests:XCTestCase {
    private final class Capture:@unchecked Sendable {
        let lock=NSLock();var values=[Int64]();var requests=[URLRequest]()
        func add(_ value:Int64){lock.lock();values.append(value);lock.unlock()}
        func request(_ value:URLRequest){lock.lock();requests.append(value);lock.unlock()}
        func snapshot()->([Int64],[URLRequest]){lock.lock();defer{lock.unlock()};return(values,requests)}
    }
    var root:URL!,file:URL!,descriptor:Int32 = -1
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try Paths.ensure(root);file=root.appendingPathComponent("model.bin")
        descriptor=open(file.path,O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC,0o600);XCTAssertGreaterThanOrEqual(descriptor,0)
    }
    override func tearDownWithError() throws {if descriptor>=0 {close(descriptor)};try? FileManager.default.removeItem(at:root)}
    func transport() -> NativeHTTPTransport {let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ModelHTTPFixture.self];return NativeHTTPTransport(configuration:config)}
    func testStreamedBytesProgressAndNoApplicationCredentials() async throws {
        let capture=Capture(),chunks=[Data(repeating:1,count:16000),Data(repeating:2,count:9000)]
        let url=ModelHTTPFixture.register(.init(chunks:chunks,length:25000,requested:{capture.request($0)}))
        try await transport().download(url,to:descriptor,expectedBytes:25000,progress:{capture.add($0)})
        XCTAssertEqual(try Data(contentsOf:file),chunks.reduce(Data(),+));XCTAssertNotEqual(fcntl(descriptor,F_GETFD),-1)
        let (values,requests)=capture.snapshot();XCTAssertEqual(values.last,25000);XCTAssertEqual(values,values.sorted());XCTAssertEqual(requests.count,1)
        XCTAssertEqual(requests[0].httpMethod,"GET");XCTAssertNil(requests[0].httpBody);XCTAssertNil(requests[0].value(forHTTPHeaderField:"Authorization"));XCTAssertNil(requests[0].value(forHTTPHeaderField:"Cookie"))
    }
    func testOversizedHeaderAndBodyAreRefused() async throws {
        for length in [nil,20] as [Int?] {
            let url=ModelHTTPFixture.register(.init(chunks:[Data(repeating:1,count:20)],length:length))
            do {try await transport().download(url,to:descriptor,expectedBytes:10,progress:{_ in});XCTFail("Oversized download accepted")}catch{XCTAssertTrue(error.localizedDescription.contains("pinned size"))}
        }
        XCTAssertTrue(try Data(contentsOf:file).isEmpty)
    }
    func testTruncationStatusAndNetworkFailureReturnErrors() async throws {
        let truncated=ModelHTTPFixture.register(.init(chunks:[Data("short".utf8)],length:5))
        do {try await transport().download(truncated,to:descriptor,expectedBytes:10,progress:{_ in});XCTFail("Truncated model accepted")}catch{XCTAssertTrue(error.localizedDescription.contains("expected size"))}
        let denied=ModelHTTPFixture.register(.init(status:403,chunks:[]))
        do {try await transport().download(denied,to:descriptor,expectedBytes:10,progress:{_ in});XCTFail("403 accepted")}catch{XCTAssertTrue(error.localizedDescription.contains("403"))}
        let failed=ModelHTTPFixture.register(.init(chunks:[],error:URLError(.notConnectedToInternet)))
        do {try await transport().download(failed,to:descriptor,expectedBytes:10,progress:{_ in});XCTFail("Network failure accepted")}catch{}
    }
    func testCancellationFinishesWritesBeforeReturning() async throws {
        let first=expectation(description:"first streamed bytes"),capture=Capture(),url=ModelHTTPFixture.register(.init(chunks:Array(repeating:Data(repeating:1,count:4096),count:50),pause:0.05))
        let transfer=transport(),descriptor=descriptor
        let task=Task {try await transfer.download(url,to:descriptor,expectedBytes:204800) { value in capture.add(value);if value==4096 {first.fulfill()} }}
        await fulfillment(of:[first],timeout:5);task.cancel()
        do {try await task.value;XCTFail("Cancellation ignored")}catch is CancellationError{}catch{throw error}
        let bytes=try Data(contentsOf:file);XCTAssertLessThan(bytes.count,204800)
        try await Task.sleep(nanoseconds:100_000_000);XCTAssertEqual(try Data(contentsOf:file),bytes)
        XCTAssertNotEqual(fcntl(descriptor,F_GETFD),-1)
    }
    func testHTTPAndCredentialURLsAreRefusedBeforeRequest() async throws {
        let capture=Capture(),url=ModelHTTPFixture.register(.init(chunks:[],requested:{capture.request($0)}))
        for value in ["http://model-fixture.invalid/test","https://user:synthetic@model-fixture.invalid/test"] {
            let probe=ModelHTTPFixture.register(.init(chunks:[],length:0,requested:{capture.request($0)}),at:URL(string:value)!)
            do {try await transport().download(probe,to:descriptor,expectedBytes:0,progress:{_ in});XCTFail("Unsafe URL accepted")}catch{}
        }
        _ = url;XCTAssertTrue(capture.snapshot().1.isEmpty)
    }
    func testWriteFailureIsReportedWithoutOwningTheCallersDescriptor() async throws {
        close(descriptor);descriptor=open(file.path,O_RDONLY|O_CLOEXEC)
        let url=ModelHTTPFixture.register(.init(chunks:[Data("body".utf8)],length:4))
        do {try await transport().download(url,to:descriptor,expectedBytes:4,progress:{_ in});XCTFail("Read-only write accepted")}catch{XCTAssertTrue(error.localizedDescription.contains("write"))}
        XCTAssertNotEqual(fcntl(descriptor,F_GETFD),-1)
    }
    func testHTTPSRedirectStripsCredentialsAndCookies() async throws {
        let capture=Capture(),target=ModelHTTPFixture.register(.init(chunks:[Data("ok".utf8)],length:2,requested:{capture.request($0)}))
        var redirected=URLRequest(url:target);redirected.setValue("Bearer synthetic-fixture",forHTTPHeaderField:"Authorization");redirected.setValue("fixture=synthetic",forHTTPHeaderField:"Cookie")
        let source=ModelHTTPFixture.register(.init(status:302,chunks:[],redirect:redirected))
        try await transport().download(source,to:descriptor,expectedBytes:2,progress:{_ in})
        let requests=capture.snapshot().1;XCTAssertEqual(requests.count,1);XCTAssertNil(requests[0].value(forHTTPHeaderField:"Authorization"));XCTAssertNil(requests[0].value(forHTTPHeaderField:"Cookie"))
        XCTAssertEqual(try Data(contentsOf:file),Data("ok".utf8))
    }
    func testRedirectDowngradeDoesNotIssueAnHTTPRequest() async throws {
        let capture=Capture(),target=ModelHTTPFixture.register(.init(chunks:[],requested:{capture.request($0)}))
        var components=URLComponents(url:target,resolvingAgainstBaseURL:false)!;components.scheme="http"
        let source=ModelHTTPFixture.register(.init(status:302,chunks:[],redirect:URLRequest(url:components.url!)))
        do {try await transport().download(source,to:descriptor,expectedBytes:0,progress:{_ in});XCTFail("HTTP downgrade accepted")}catch{}
        XCTAssertTrue(capture.snapshot().1.isEmpty)
    }
}
