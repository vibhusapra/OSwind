import Foundation

/// Session tokens retain the source origin's namespace. Single-source scopes
/// carry an exact evidence version; missing originals never become all sources.
struct SyncRecordingScope:Codable,Equatable,Sendable {
    let selector:RecordingScope.Selector
    let session:SyncSessionToken?
    let source:SyncVersionReference?
    init(_ value:RecordingScope,session resolveSession:((String)throws->SyncSessionToken?)?,source resolveSource:((String,String)throws->SyncVersionReference)?)throws {
        switch value.selector {
        case .unavailable:selector = .unavailable;session=nil;source=nil
        case .session:
            if let bound=value.session {selector = .session;session=bound;source=nil}
            else {guard let resolveSession else {throw OSwindError.unavailable("Recording session resolver is required")};session=try resolveSession(value.id!);selector=session==nil ? .unavailable:.session;source=nil}
        case .source:
            guard let resolveSource else {throw OSwindError.unavailable("Recording source resolver is required")}
            selector = .source;session=nil;source=try resolveSource(value.id!,value.revision!)
        }
        try validate()
    }
    func validate()throws {
        switch selector {
        case .session:guard let session,source==nil else {throw OSwindError.invalid("Invalid portable recording session")};try session.validate()
        case .source:guard let source,session==nil else {throw OSwindError.invalid("Invalid portable recording source")};try source.validate(.source)
        case .unavailable:guard source==nil,session==nil else {throw OSwindError.invalid("Unavailable recording selects evidence")}
        }
    }
    func projected(source resolve:(SyncVersionReference)throws->RecordingScope)throws->RecordingScope {
        try validate()
        switch selector {
        case .session:return try .init(session:session!)
        case .source:return try resolve(source!)
        case .unavailable:return .unavailable
        }
    }
}
