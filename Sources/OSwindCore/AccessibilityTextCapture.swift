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
    private func boundedTextObservation(_ id:String,db:RoutineDatabase)throws->Memory? {
        let row=try db.statement("SELECT CASE WHEN length(payload)<=262144 THEN payload END FROM memories WHERE id=?")
        defer {sqlite3_finalize(row)};db.bind(row,1,id)
        let result=sqlite3_step(row);if result==SQLITE_DONE {return nil};guard result==SQLITE_ROW else {throw db.error()}
        let count=Int(sqlite3_column_bytes(row,0));guard count>0,count<=262144,let bytes=sqlite3_column_blob(row,0) else {return nil}
        return try JSONDecoder().decode(Memory.self,from:Data(bytes:bytes,count:count))
    }
    func accessibilityObservationCanContinue(_ cursor:TextObservationCursor)throws->Bool {
        try withRoutineDatabase {db in
            do {guard try !db.textObservationPinned(cursor.id),let current=try boundedTextObservation(cursor.id,db:db) else {return false};return try cursor.matches(current)}
            catch is CancellationError {throw CancellationError()}
            catch {return false}
        }
    }
    /// Update only sampled metadata, preserving current curation and every
    /// embedding/vector/FTS identity. A raced revision discards this observation.
    func extendAccessibilityObservation(_ cursor:TextObservationCursor,at date:Date,reservation:AccessibilityCaptureReservation)throws->Memory {
        try Task.checkCancellation();try requireMediaRootIdentity()
        return try reservation.activity.withActive(for:mediaRootIdentity) {
            try withRoutineDatabase {db in
                try db.execute("BEGIN IMMEDIATE")
                do {
                    guard try !db.textObservationPinned(cursor.id) else {throw SnapshotCaptureDeferral(reason:"Source pinned for evidence · next observation starts a new span")}
                    guard var memory=try boundedTextObservation(cursor.id,db:db),try cursor.matches(memory) else {throw SnapshotCaptureDeferral(reason:"Text source changed · next observation starts a new span")}
                    let gap=date.timeIntervalSince(cursor.last)
                    memory.endTimestamp=date
                    memory.textObservation=TextObservationSpan(sessionID:cursor.span.sessionID,samples:cursor.span.samples+1,largestGapSeconds:max(cursor.span.largestGapSeconds,gap))
                    try memory.textObservation?.validated(for:memory)
                    let data=try JSONEncoder().encode(memory);guard data.count<=262144 else {throw OSwindError.invalid("Sampled text payload exceeds 256 KiB")}
                    let row=try db.statement("UPDATE memories SET payload=? WHERE id=?");defer {sqlite3_finalize(row)}
                    _ = data.withUnsafeBytes {sqlite3_bind_blob(row,1,$0.baseAddress,Int32(data.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self))}
                    db.bind(row,2,memory.id);try db.done(row)
                    try Task.checkCancellation();try requireMediaRootIdentity()
                    try reservation.snapshot.withCurrent(root:root,policy:reservation.snapshot.settings.privacy) {try db.execute("COMMIT")}
                    return memory
                } catch {try? db.execute("ROLLBACK");throw error}
            }
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
