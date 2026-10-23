import Foundation
import Darwin

/// The caller owns the private descriptor and closes it only after this returns.
/// Implementations must finish all descriptor writes before returning, including
/// cancellation. No response body is accumulated into a model-sized Data value.
protocol NativeModelTransport:Sendable {
    func download(_ url:URL,to descriptor:Int32,expectedBytes:Int64,progress:@escaping @Sendable (Int64)->Void) async throws
}
struct NativeHTTPTransport:NativeModelTransport,@unchecked Sendable {
    var configuration:URLSessionConfiguration = .ephemeral
    func download(_ url:URL,to descriptor:Int32,expectedBytes:Int64,progress:@escaping @Sendable (Int64)->Void) async throws {
        guard let copy=configuration.copy() as? URLSessionConfiguration else { throw OSwindError.network("Cannot prepare model download") }
        try await NativeHTTPDownload(url:url,descriptor:descriptor,expected:expectedBytes,configuration:copy,progress:progress).run()
    }
}
private final class NativeHTTPDownload:NSObject,URLSessionDataDelegate,@unchecked Sendable {
    let url:URL,descriptor:Int32,expected:Int64,configuration:URLSessionConfiguration,progress:@Sendable (Int64)->Void
    private let lock=NSLock()
    private var continuation:CheckedContinuation<Void,Error>?
    private var session:URLSession?
    private var task:URLSessionDataTask?
    private var cancelled=false,finished=false
    private var failure:Error?
    // Accessed only by the serial delegate queue (or before the task starts).
    private var received:Int64=0
    init(url:URL,descriptor:Int32,expected:Int64,configuration:URLSessionConfiguration,progress:@escaping @Sendable (Int64)->Void) { self.url=url;self.descriptor=descriptor;self.expected=expected;self.configuration=configuration;self.progress=progress }
    func run() async throws {
        guard url.scheme=="https",url.host != nil,url.user==nil,url.password==nil,expected>=0 else { throw OSwindError.invalid("Model downloads require a public HTTPS URL") }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                configuration.urlCache=nil;configuration.urlCredentialStorage=nil;configuration.httpCookieStorage=nil;configuration.httpShouldSetCookies=false
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest=45;configuration.timeoutIntervalForResource=1800;configuration.waitsForConnectivity=false
                let queue=OperationQueue();queue.maxConcurrentOperationCount=1;queue.qualityOfService = .utility
                let session=URLSession(configuration:configuration,delegate:self,delegateQueue:queue)
                var request=URLRequest(url:url);request.httpMethod="GET";request.setValue("OSwind-model-setup/0.1",forHTTPHeaderField:"User-Agent")
                let task=session.dataTask(with:request)
                lock.lock();self.continuation=continuation;self.session=session;self.task=task;let cancel=cancelled;lock.unlock()
                if cancel { finish(CancellationError()) } else { task.resume() }
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() { lock.lock();cancelled=true;let task=task;lock.unlock();task?.cancel() }
    private func shouldWrite() -> Bool { lock.lock();defer{lock.unlock()};return !cancelled && !finished && failure==nil }
    private func fail(_ error:Error) { lock.lock();if failure==nil { failure=error };let task=task;lock.unlock();task?.cancel() }
    private func finish(_ error:Error?) {
        lock.lock();guard !finished else { lock.unlock();return };finished=true
        let result:Error? = cancelled ? CancellationError() : (failure ?? error ?? (received==expected ? nil:OSwindError.network("Model download ended before the expected size")))
        let continuation=continuation,session=session;self.continuation=nil;self.session=nil;self.task=nil;lock.unlock()
        session?.invalidateAndCancel()
        if let result { continuation?.resume(throwing:result) } else { continuation?.resume() }
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping (URLSession.ResponseDisposition)->Void) {
        guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else { fail(OSwindError.network("Model server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"));completionHandler(.cancel);return }
        if response.expectedContentLength>expected && (http.value(forHTTPHeaderField:"Content-Encoding")==nil || http.value(forHTTPHeaderField:"Content-Encoding")=="identity") { fail(OSwindError.invalid("Model download exceeds its pinned size"));completionHandler(.cancel);return }
        completionHandler(.allow)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
        guard shouldWrite() else { return }
        guard Int64(data.count)<=expected-received else { fail(OSwindError.invalid("Model download exceeds its pinned size"));return }
        do {
            try data.withUnsafeBytes { bytes in
                var offset=0
                while offset<bytes.count {
                    guard shouldWrite() else { throw CancellationError() }
                    let count=Darwin.write(descriptor,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                    if count<0 && errno==EINTR { continue }
                    guard count>0 else { throw OSwindError.unavailable("Cannot write the model download; check available disk space") };offset += count
                }
            }
            received += Int64(data.count);progress(received)
        } catch { fail(error) }
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) { finish(error) }
    func urlSession(_ session:URLSession,didBecomeInvalidWithError error:Error?) { if let error { finish(error) } }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) {
        guard let url=request.url,url.scheme=="https",url.user==nil,url.password==nil else { fail(OSwindError.network("Refused an insecure model download redirect"));completionHandler(nil);return }
        var clean=request;clean.setValue(nil,forHTTPHeaderField:"Authorization");clean.setValue(nil,forHTTPHeaderField:"Cookie");completionHandler(clean)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping (URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod==NSURLAuthenticationMethodServerTrust ? .performDefaultHandling:.cancelAuthenticationChallenge,nil)
    }
}
