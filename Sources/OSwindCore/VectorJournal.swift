import Foundation

/// A durable mutation log gives each (memory, model) a never-reused native key.
/// Native indexes are disposable caches; SQLite remains the source of truth.
enum VectorJournalSchema {
    static let sql = """
    CREATE TABLE IF NOT EXISTS store_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    INSERT OR IGNORE INTO store_metadata(key,value) VALUES('identity',lower(hex(randomblob(16))));
    CREATE TABLE IF NOT EXISTS vector_keys (
        key INTEGER PRIMARY KEY AUTOINCREMENT,
        memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
        model TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0,
        UNIQUE(memory_id,model)
    );
    CREATE INDEX IF NOT EXISTS vector_keys_model ON vector_keys(model,key);
    CREATE INDEX IF NOT EXISTS vector_keys_revision ON vector_keys(model,revision);
    CREATE TABLE IF NOT EXISTS vector_changes (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, vector_key INTEGER NOT NULL, model TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS vector_changes_model ON vector_changes(model,seq);
    CREATE TRIGGER IF NOT EXISTS vector_key_deleted AFTER DELETE ON vector_keys BEGIN
        INSERT INTO vector_changes(vector_key,model) VALUES(old.key,old.model);
    END;
    CREATE TRIGGER IF NOT EXISTS vector_legacy_insert AFTER INSERT ON memories
    WHEN new.embedding IS NOT NULL AND new.embedding_model IS NOT NULL BEGIN
        INSERT INTO vector_keys(memory_id,model) VALUES(new.id,new.embedding_model) ON CONFLICT(memory_id,model) DO NOTHING;
        INSERT INTO vector_changes(vector_key,model) SELECT key,model FROM vector_keys WHERE memory_id=new.id AND model=new.embedding_model;
        UPDATE vector_keys SET revision=(SELECT MAX(seq) FROM vector_changes) WHERE memory_id=new.id AND model=new.embedding_model;
    END;
    CREATE TRIGGER IF NOT EXISTS vector_legacy_update AFTER UPDATE OF embedding,embedding_model ON memories BEGIN
        DELETE FROM vector_keys WHERE memory_id=old.id AND model=old.embedding_model
            AND (new.embedding IS NULL OR new.embedding_model IS NOT old.embedding_model)
            AND NOT EXISTS(SELECT 1 FROM semantic_vectors WHERE memory_id=old.id AND model=old.embedding_model);
        INSERT INTO vector_keys(memory_id,model)
            SELECT new.id,new.embedding_model WHERE new.embedding IS NOT NULL AND new.embedding_model IS NOT NULL ON CONFLICT(memory_id,model) DO NOTHING;
        INSERT INTO vector_changes(vector_key,model) SELECT key,model FROM vector_keys WHERE memory_id=new.id AND model=new.embedding_model AND new.embedding IS NOT NULL;
        UPDATE vector_keys SET revision=(SELECT MAX(seq) FROM vector_changes) WHERE memory_id=new.id AND model=new.embedding_model AND new.embedding IS NOT NULL;
    END;
    CREATE TRIGGER IF NOT EXISTS vector_extra_insert AFTER INSERT ON semantic_vectors BEGIN
        INSERT INTO vector_keys(memory_id,model) VALUES(new.memory_id,new.model) ON CONFLICT(memory_id,model) DO NOTHING;
        INSERT INTO vector_changes(vector_key,model) SELECT key,model FROM vector_keys WHERE memory_id=new.memory_id AND model=new.model;
        UPDATE vector_keys SET revision=(SELECT MAX(seq) FROM vector_changes) WHERE memory_id=new.memory_id AND model=new.model;
    END;
    CREATE TRIGGER IF NOT EXISTS vector_extra_update AFTER UPDATE ON semantic_vectors BEGIN
        INSERT INTO vector_keys(memory_id,model) VALUES(new.memory_id,new.model) ON CONFLICT(memory_id,model) DO NOTHING;
        INSERT INTO vector_changes(vector_key,model) SELECT key,model FROM vector_keys WHERE memory_id=new.memory_id AND model=new.model;
        UPDATE vector_keys SET revision=(SELECT MAX(seq) FROM vector_changes) WHERE memory_id=new.memory_id AND model=new.model;
    END;
    CREATE TRIGGER IF NOT EXISTS vector_extra_delete AFTER DELETE ON semantic_vectors BEGIN
        DELETE FROM vector_keys WHERE memory_id=old.memory_id AND model=old.model
            AND NOT EXISTS(SELECT 1 FROM memories WHERE id=old.memory_id AND embedding_model=old.model AND embedding IS NOT NULL);
        INSERT INTO vector_changes(vector_key,model) SELECT key,model FROM vector_keys WHERE memory_id=old.memory_id AND model=old.model;
        UPDATE vector_keys SET revision=(SELECT MAX(seq) FROM vector_changes) WHERE memory_id=old.memory_id AND model=old.model;
    END;
    """
    static let backfill = """
    INSERT OR IGNORE INTO vector_keys(memory_id,model)
        SELECT id,embedding_model FROM memories WHERE embedding IS NOT NULL AND embedding_model IS NOT NULL;
    INSERT OR IGNORE INTO vector_keys(memory_id,model) SELECT memory_id,model FROM semantic_vectors;
    """
}
