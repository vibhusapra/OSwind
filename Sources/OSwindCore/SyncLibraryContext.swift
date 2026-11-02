import Foundation

/// Transport work must belong to the still-active native capture generation,
/// even when it handles only opaque headers and never reads a typed body.
/// The controller must additionally cancel and join workers before acknowledging
/// stop or replacement; this guard does not make configuration changes atomic
/// with a later provider write.
enum SyncLibraryContext {
    static func requireActive(_ db:RoutineDatabase,cache:SyncVersionStore)throws {
        guard db.handle==cache.database.handle,
              try SyncChangeCapture.scope(db,requireActive:true)==cache.catalog.scope else {
            throw OSwindError.invalid("The sync worker belongs to another library generation")
        }
        _=try cache.journal.cursor(for:cache.journal.replica)
    }
}
