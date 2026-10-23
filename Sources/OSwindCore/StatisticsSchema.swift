import Foundation

/// Recomputable metadata, maintained in the source transaction for every writer.
/// Timestamp extrema use the existing timestamp index rather than a full scan.
enum StatisticsSchema {
    static let sql = """
    CREATE TABLE IF NOT EXISTS memory_statistics (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        total INTEGER NOT NULL CHECK(total>=0),
        screens INTEGER NOT NULL CHECK(screens>=0),
        audio INTEGER NOT NULL CHECK(audio>=0),
        embedded INTEGER NOT NULL CHECK(embedded>=0)
    );
    CREATE TABLE IF NOT EXISTS application_statistics (
        app TEXT PRIMARY KEY, count INTEGER NOT NULL CHECK(count>=0)
    );
    CREATE TRIGGER IF NOT EXISTS statistics_insert AFTER INSERT ON memories BEGIN
        UPDATE memory_statistics SET total=total+1,screens=screens+(new.kind='screen'),audio=audio+(new.kind='audio'),embedded=embedded+(new.embedding IS NOT NULL) WHERE singleton=1;
        INSERT INTO application_statistics(app,count) VALUES(new.app,1) ON CONFLICT(app) DO UPDATE SET count=count+1;
    END;
    CREATE TRIGGER IF NOT EXISTS statistics_delete AFTER DELETE ON memories BEGIN
        UPDATE memory_statistics SET total=total-1,screens=screens-(old.kind='screen'),audio=audio-(old.kind='audio'),embedded=embedded-(old.embedding IS NOT NULL) WHERE singleton=1;
        UPDATE application_statistics SET count=count-1 WHERE app=old.app;
        DELETE FROM application_statistics WHERE app=old.app AND count=0;
    END;
    CREATE TRIGGER IF NOT EXISTS statistics_update AFTER UPDATE OF app,kind,embedding ON memories
    WHEN old.app IS NOT new.app OR old.kind IS NOT new.kind OR (old.embedding IS NULL) != (new.embedding IS NULL)
    BEGIN
        UPDATE memory_statistics SET screens=screens+(new.kind='screen')-(old.kind='screen'),audio=audio+(new.kind='audio')-(old.kind='audio'),embedded=embedded+(new.embedding IS NOT NULL)-(old.embedding IS NOT NULL) WHERE singleton=1;
        UPDATE application_statistics SET count=count-1 WHERE app=old.app;
        DELETE FROM application_statistics WHERE app=old.app AND count=0;
        INSERT INTO application_statistics(app,count) VALUES(new.app,1) ON CONFLICT(app) DO UPDATE SET count=count+1;
    END;
    """
    static let backfill = """
    DELETE FROM memory_statistics;
    INSERT INTO memory_statistics(singleton,total,screens,audio,embedded)
        SELECT 1,COUNT(*),COALESCE(SUM(kind='screen'),0),COALESCE(SUM(kind='audio'),0),COALESCE(SUM(embedding IS NOT NULL),0) FROM memories;
    DELETE FROM application_statistics;
    INSERT INTO application_statistics(app,count) SELECT app,COUNT(*) FROM memories GROUP BY app;
    """
    static let selectiveFTSUpdate = """
    DROP TRIGGER IF EXISTS memory_update;
    CREATE TRIGGER memory_update AFTER UPDATE OF title,app,text ON memories
    WHEN old.title IS NOT new.title OR old.app IS NOT new.app OR old.text IS NOT new.text
    BEGIN
        DELETE FROM memory_fts WHERE id=old.id;
        INSERT INTO memory_fts(id,title,app,text) VALUES(new.id,new.title,new.app,new.text);
    END;
    """
}
