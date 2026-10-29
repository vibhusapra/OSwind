import Foundation
import CryptoKit
import CSQLite

/// Keep input/lifecycle activity and the exact saved policy through the entire
/// text observation, preparation and admission. Acquisition runs off the UI.
final class AccessibilityCaptureReservation:@unchecked Sendable {
    let activity:MediaAdmissionLease
    let snapshot:LibrarySettingsSnapshot
    init(store:MemoryStore,configuration:AppSettings) throws {
        let activity=try store.mediaWriteLease(),snapshot:LibrarySettingsSnapshot
        do {
            snapshot=try LibrarySettingsSnapshot.capture(root:store.root)
            let saved=snapshot.settings
            guard saved.visualCaptureMode == .accessibility,saved.privacy==configuration.privacy,
                  saved.allDisplays==configuration.allDisplays,saved.snapshotRegions==configuration.snapshotRegions,
                  saved.profile==configuration.profile else {throw OSwindError.unavailable("Save the current text-only capture settings before capturing")}
            try AccessibilityCaptureRecord.validateScope(saved)
            try Task.checkCancellation()
        } catch {activity.release();throw error}
        self.activity=activity;self.snapshot=snapshot
    }
    func release(){snapshot.release();activity.release()}
    deinit {release()}
}

enum AccessibilityCaptureRecord {
    static let display="accessibility-window"
    static func validateScope(_ settings:AppSettings) throws {
        guard settings.snapshotRegions.valid else {throw OSwindError.invalid("Invalid capture area · choose a new area in Settings")}
        guard !settings.allDisplays else {throw OSwindError.invalid("Text-only mode requires focused-window capture · turn off display capture")}
        guard settings.snapshotRegions.focusedWindowCrop==nil else {throw OSwindError.invalid("Text-only mode cannot apply a screen crop · clear the crop explicitly in Settings")}
    }
    static func make(_ context:WindowContext,at date:Date,policy:PrivacyPolicy) throws -> Memory {
        guard context.pid>0,!context.secure,
              context.accessibilityText.count<=16000,context.accessibilityText.utf8.count<=65536,
              context.app.utf8.count<=512,context.bundle.utf8.count<=512,context.title.utf8.count<=16384,
              (context.url?.utf8.count ?? 0)<=8192 else {throw OSwindError.invalid("Accessible context is protected or exceeds the text-only capture bounds")}
        guard !context.accessibilityText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw SnapshotCaptureDeferral(reason:"No accessible window text · nothing saved")}
        guard policy.exclusion(app:context.bundle,title:context.title,url:context.url,isBrowser:context.browser)==nil else {throw SnapshotCaptureDeferral(reason:"Excluded context · text not saved")}
        let app=policy.sanitize(context.app).text,title=policy.sanitize(context.title).text,url=policy.sanitize(context.url ?? "").text,text=policy.sanitize(context.accessibilityText).text
        return Memory(timestamp:date,kind:.screen,app:app,bundleID:context.bundle,title:title,url:url.isEmpty ? nil:url,text:text,display:display,regions:[])
    }
    static func digest(_ memory:Memory) throws -> Data {
        try Task.checkCancellation()
        return Data(SHA256.hash(data:try JSONEncoder().encode(["ax-text-v1",memory.app,memory.bundleID,memory.title,memory.url ?? "",memory.text])))
    }
}

extension MemoryStore {
    /// Indexed lookup; avoid decoding a potentially large replacement payload
    /// on the capture hot path. Oversized rows simply do not suppress a capture.
    func accessibilityCaptureStillExists(id:String,matching memory:Memory) throws -> Bool {
        try withRoutineDatabase {db in
            let row=try db.statement("SELECT CASE WHEN length(payload)<=262144 THEN kind='screen' AND app=? AND title=? AND COALESCE(url,'')=? AND text=? AND json_extract(CAST(payload AS TEXT),'$.bundleID')=? ELSE 0 END FROM memories WHERE id=?")
            defer {sqlite3_finalize(row)}
            for (index,value) in [memory.app,memory.title,memory.url ?? "",memory.text,memory.bundleID,id].enumerated() {db.bind(row,Int32(index+1),value)}
            let result=sqlite3_step(row);if result==SQLITE_DONE {return false};guard result==SQLITE_ROW else {throw db.error()}
            return sqlite3_column_int(row,0)==1
        }
    }
    /// Only the final small source transaction is inside the publication gate.
    /// The shared activity reservation orders this operation before close/wipe.
    func insertAccessibilityCapture(_ memory:Memory,reservation:AccessibilityCaptureReservation) throws {
        let saved=reservation.snapshot.settings
        try AccessibilityCaptureRecord.validateScope(saved)
        guard saved.visualCaptureMode == .accessibility,memory.kind == .screen,memory.display==AccessibilityCaptureRecord.display,
              memory.imagePath==nil,memory.audioPath==nil,memory.videoPath==nil,memory.visualRecording==nil,
              memory.transcript==nil,memory.regions.isEmpty else {throw OSwindError.invalid("Text-only capture cannot admit pixels, audio or video")}
        try Task.checkCancellation();try requireMediaRootIdentity()
        try reservation.activity.withActive(for:mediaRootIdentity) {
            try withRoutineDatabase {db in
                try db.execute("BEGIN IMMEDIATE")
                do {
                    try insert(memory);try Task.checkCancellation();try requireMediaRootIdentity()
                    try reservation.snapshot.withCurrent(root:root,policy:saved.privacy) {try db.execute("COMMIT")}
                } catch {try? db.execute("ROLLBACK");throw error}
            }
        }
    }
}
