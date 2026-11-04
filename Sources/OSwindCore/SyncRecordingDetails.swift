import Foundation

/// Unavailability is an observed projection outcome, never a catch-all for
/// policy, identity, integrity or cancellation errors.
enum SyncRecordingSourceResolution:Equatable {
    case available(SyncVersionReference),unavailable
}

/// User-authored metadata, distinct from captured speech or calendar authority.
/// Calendar references remain dormant data on another library/device.
struct SyncRecordingDetails:Codable,Equatable,Sendable {
    let version:Int
    let scope:SyncRecordingScope
    let calendar:RecordingCalendarLink?
    init(_ value:RecordingDetails,session:((String)throws->SyncSessionToken?)?,source:((String,String)throws->SyncRecordingSourceResolution)?)throws {
        version=value.version;calendar=value.calendar
        if value.scope.selector == .source {
            guard let source else {throw OSwindError.unavailable("Recording source resolver is required")}
            switch try source(value.scope.id!,value.scope.revision!) {
            case .available(let reference):scope=try .init(source:reference)
            case .unavailable:scope=try .init(source:nil)
            }
        }else {scope=try .init(value.scope,session:session,source:nil)}
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
