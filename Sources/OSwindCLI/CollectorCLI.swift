import Foundation
import Darwin
import OSwindCore

/// No plaintext staging file or payload argv. A complete bounded input is read
/// before the atomic importer starts; cancellation/deadline also covers idle pipes.
func collectorStandardInput() async throws -> Data {
    guard isatty(STDIN_FILENO)==0 else {throw OSwindError.invalid("Use collect --stdin with a pipe")}
    let original=fcntl(STDIN_FILENO,F_GETFL)
    guard original>=0,fcntl(STDIN_FILENO,F_SETFL,original|O_NONBLOCK)==0 else {throw OSwindError.unavailable("Cannot prepare collector input")}
    defer {_ = fcntl(STDIN_FILENO,F_SETFL,original)}
    let deadline=ContinuousClock.now.advanced(by:.seconds(30));var data=Data(),buffer=[UInt8](repeating:0,count:65536)
    while true {
        try Task.checkCancellation();guard ContinuousClock.now<deadline else {throw OSwindError.unavailable("Collector input timed out before admission")}
        let count=Darwin.read(STDIN_FILENO,&buffer,buffer.count)
        if count==0 {return data}
        if count<0 {
            if errno==EINTR {continue}
            guard errno==EAGAIN || errno==EWOULDBLOCK else {throw OSwindError.unavailable("Cannot read collector input")}
            try await Task.sleep(for:.milliseconds(20));continue
        }
        guard data.count<=TextCollector.maximumBatchBytes-count else {throw OSwindError.invalid("Collector batch exceeds 16 MiB")}
        data.append(contentsOf:buffer.prefix(count))
    }
}
