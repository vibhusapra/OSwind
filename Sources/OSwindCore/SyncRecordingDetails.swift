import Foundation

/// User-authored metadata, distinct from captured speech or calendar authority.
/// Calendar references remain dormant data on another library/device.
struct SyncRecordingDetails:Codable,Equatable,Sendable {
    let version:Int
    let scope:SyncRecordingScope
    let calendar:RecordingCalendarLink?
    init(_ value:RecordingDetails,session:((String)throws->SyncSessionToken?)?,source:((String,String)throws->SyncVersionReference)?)throws {
        version=value.version;scope=try .init(value.scope,session:session,source:source);calendar=value.calendar
        try validate()
    }
    func validate()throws {
        guard version==1 else {throw OSwindError.invalid("Unsupported portable recording-details version")}
        try scope.validate()
    }
    func projected(resolve:(SyncVersionReference)throws->(id:String,evidenceHash:String))throws->RecordingDetails {
        try validate()
        return try .init(scope:scope.projected {ref in
            let source=try resolve(ref)
            return try RecordingScope(sourceID:source.id,revision:source.evidenceHash)
        },calendar:calendar)
    }
}
