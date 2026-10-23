import Foundation

public enum SpeakerLabel {
    public static func key(_ label: String) -> String {
        label.trimmingCharacters(in:.whitespacesAndNewlines).folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX"))
    }
    static func words(_ text:String) -> [String] {
        Array(key(text).split(whereSeparator:{!$0.isLetter && !$0.isNumber}).prefix(24).map(String.init))
    }
    // Person labels such as Will must not disappear as question stopwords.
    static func ftsQuery(_ query:String) -> String { words(query).map { "\"\($0)\"*" }.joined(separator:" OR ") }
}

/// Derived metadata, rebuilt from validated transcript payloads during migration
/// and restore. Raw transcript text and its semantic passage offsets stay intact.
enum SpeakerSearchSchema {
    static let sql = """
    CREATE TABLE IF NOT EXISTS audio_speakers (
        memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
        label TEXT NOT NULL, label_key TEXT NOT NULL,
        PRIMARY KEY(memory_id,label)
    );
    CREATE INDEX IF NOT EXISTS audio_speaker_label ON audio_speakers(label_key,memory_id);
    CREATE VIRTUAL TABLE IF NOT EXISTS speaker_fts USING fts5(memory_id UNINDEXED,label,tokenize='unicode61 remove_diacritics 2');
    CREATE TRIGGER IF NOT EXISTS speaker_search_insert AFTER INSERT ON audio_speakers BEGIN
        INSERT INTO speaker_fts(memory_id,label) VALUES(new.memory_id,new.label);
    END;
    CREATE TRIGGER IF NOT EXISTS speaker_search_delete AFTER DELETE ON audio_speakers BEGIN
        DELETE FROM speaker_fts WHERE memory_id=old.memory_id AND label=old.label;
    END;
    """
}
