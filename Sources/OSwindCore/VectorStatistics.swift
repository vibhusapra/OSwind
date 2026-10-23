import Foundation

/// Entity counts drive backend selection; parent counts describe coverage.
/// Maintaining both avoids an archive-sized COUNT on each keystroke.
enum VectorStatisticsSchema {
    static let sql = """
    CREATE TABLE IF NOT EXISTS vector_statistics(model TEXT PRIMARY KEY,entities INTEGER NOT NULL,parents INTEGER NOT NULL);
    CREATE TRIGGER IF NOT EXISTS vector_statistics_insert AFTER INSERT ON vector_keys BEGIN
        INSERT INTO vector_statistics(model,entities,parents) VALUES(new.model,1,new.ordinal=0)
        ON CONFLICT(model) DO UPDATE SET entities=entities+1,parents=parents+(new.ordinal=0);
    END;
    CREATE TRIGGER IF NOT EXISTS vector_statistics_delete AFTER DELETE ON vector_keys BEGIN
        UPDATE vector_statistics SET entities=entities-1,parents=parents-(old.ordinal=0) WHERE model=old.model;
        DELETE FROM vector_statistics WHERE model=old.model AND entities=0;
    END;
    """
    static let backfill = """
    DELETE FROM vector_statistics;
    INSERT INTO vector_statistics(model,entities,parents) SELECT model,COUNT(*),SUM(ordinal=0) FROM vector_keys GROUP BY model;
    """
}
