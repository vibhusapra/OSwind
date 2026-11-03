import Foundation

/// Parse capture intent before opening a library/vault or asking native APIs.
/// A missing target must never become an implicit current-window request.
struct CaptureCLIRequest:Sendable {
    let targetBundleID:String?
    let seconds:Double?

    static func parse(command:String,arguments:[String],invocation:[String])throws->Self? {
        guard ["capture","capture-text","capture-replay"].contains(command) else {return nil}
        for flag in ["--data","--vault"] {
            let indices=invocation.indices.filter {invocation[$0]==flag}
            guard indices.count<=1 else {throw CaptureRequestError.invalid("Use \(flag) only once")}
            if let index=indices.first {
                guard index+1<invocation.count,!invocation[index+1].isEmpty,!invocation[index+1].hasPrefix("--"),invocation[index+1].utf8.count<=16384,!invocation[index+1].utf8.contains(0) else {throw CaptureRequestError.invalid("Enter a directory after \(flag)")}
            }
        }
        var bundle:String?,duration:Double?,seen=Set<String>(),index=0
        let usage=command=="capture-replay" ? "Use capture-replay --seconds 1..120 [--app-bundle ID]":"Use \(command) [--app-bundle ID]"
        while index<arguments.count {
            let flag=arguments[index]
            guard flag=="--app-bundle" || (command=="capture-replay" && flag=="--seconds") else {throw CaptureRequestError.invalid(usage)}
            guard seen.insert(flag).inserted else {throw CaptureRequestError.invalid("Use \(flag) only once")}
            guard index+1<arguments.count,!arguments[index+1].isEmpty,!arguments[index+1].hasPrefix("--") else {throw CaptureRequestError.invalid("Enter a value after \(flag)")}
            let value=arguments[index+1]
            if flag=="--app-bundle" {
                let allowed=CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"._-"))
                guard value.utf8.count<=1024,!value.hasPrefix("-"),value.unicodeScalars.allSatisfy({allowed.contains($0)}) else {throw CaptureRequestError.invalid("Enter a valid app bundle identifier")}
                bundle=value
            }else {
                guard let number=Double(value),number.isFinite,number>=1,number<=120 else {throw CaptureRequestError.invalid("Replay requires --seconds from 1 to 120")}
                duration=number
            }
            index+=2
        }
        guard command != "capture-replay" || duration != nil else {throw CaptureRequestError.invalid(usage)}
        return Self(targetBundleID:bundle,seconds:duration)
    }
}

private enum CaptureRequestError:LocalizedError {
    case invalid(String)
    var errorDescription:String? {switch self {case .invalid(let message):return message}}
}
