"""Independent reader of owned Screenpipe staging/Parquet transcription data.

No vendor module/source is loaded. The benchmark accepts only unchanged rows in
the observed pinned format; it refuses overlays, stale generations and paths.
"""
import hashlib
import json
import os
import pathlib
import sqlite3
import stat


def text_rows(index, directory, use_parquet=False):
    db = sqlite3.connect('file:'+str(index.resolve())+'?mode=ro', uri=True)
    try:
        db.execute('PRAGMA writable_schema=ON')
        rows = db.execute('SELECT id,transcription,_archive_file,_archive_mask,_archive_generation,_archive_digest FROM audio_transcriptions ORDER BY id').fetchall()
        archived = {row[2] for row in rows if row[2] is not None}
        if archived and not use_parquet:
            raise ValueError('Independent Parquet payload audit required; staging-only oracle cannot qualify this run')
        files = {row[0]: row[1:] for row in db.execute('SELECT id,table_name,path,checksum,state,rows FROM _bulk_files')} if archived else {}
    finally:
        db.close()
    result = {row[0]: row[1] for row in rows if row[2] is None}
    manifest = []
    if archived:
        import pyarrow
        import pyarrow.parquet as parquet
        if pyarrow.__version__ != '21.0.0':
            raise ValueError('Parquet oracle requires pinned pyarrow 21.0.0')
        for file_id in sorted(archived):
            if file_id not in files:
                raise ValueError('Missing indexed payload file')
            table_name, relative, checksum, state, declared_rows = files[file_id]
            if table_name != 'audio_transcriptions' or state != 'published':
                raise ValueError('Unsupported or unpublished payload state')
            parts = pathlib.PurePosixPath(relative).parts
            if not parts or pathlib.PurePosixPath(relative).is_absolute() or any(part in ['..', '.'] for part in parts):
                raise ValueError('Invalid payload path')
            path = directory.resolve()
            for part in parts:
                path = path/part
                if path.is_symlink():
                    raise ValueError('Payload symlink refused')
            expected = {row[0]: row for row in rows if row[2] == file_id}
            if not 0 < declared_rows <= len(rows) or len(expected) != declared_rows:
                raise ValueError('Payload row count differs from its index membership')
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(descriptor, 'rb') as stream:
                stamp = os.fstat(stream.fileno())
                if not stat.S_ISREG(stamp.st_mode):
                    raise ValueError('Payload must be a regular file')
                if stamp.st_size > 64*1024*1024:
                    raise ValueError('Payload exceeds benchmark byte bound')
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
                if digest != checksum:
                    raise ValueError('Payload SHA256 mismatch')
                stream.seek(0)
                reader = parquet.ParquetFile(stream)
                if (reader.schema_arrow.names != ['id', 'generation', 'transcription'] or
                        reader.schema_arrow.types != [pyarrow.int64(), pyarrow.int64(), pyarrow.string()] or
                        reader.metadata.num_rows != declared_rows):
                    raise ValueError('Unexpected Parquet schema or row count')
                inflated = sum(reader.metadata.row_group(i).total_byte_size for i in range(reader.metadata.num_row_groups))
                if inflated > 64*1024*1024:
                    raise ValueError('Decoded payload exceeds benchmark bound')
                decoded = reader.read().to_pylist()
                after = os.fstat(stream.fileno())
                if (stamp.st_dev, stamp.st_ino, stamp.st_size, stamp.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
                    raise ValueError('Payload changed during independent read')
            seen = set()
            for item in decoded:
                identifier, generation, text = item['id'], item['generation'], item['transcription']
                if identifier in seen or identifier not in expected or not isinstance(text, str):
                    raise ValueError('Duplicate, unknown or invalid payload row')
                row = expected[identifier]
                if row[3] != 0 or generation != row[4] or hashlib.sha256(text.encode()).digest() != row[5]:
                    raise ValueError('Payload overlay, generation or text digest mismatch')
                seen.add(identifier)
                result[identifier] = text
            if seen != set(expected):
                raise ValueError('Payload omitted indexed row identities')
            manifest.append(dict(fileID=file_id, sha256=digest, bytes=stamp.st_size, rows=declared_rows))
    logical = sorted(result.items())
    if len(logical) != len(rows) or any(not isinstance(text, str) for identifier, text in logical):
        raise ValueError('Incomplete logical transcription set')
    digest = hashlib.sha256(json.dumps(logical, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()
    return logical, dict(archivedRows=sum(row[2] is not None for row in rows), inlineRows=sum(row[2] is None for row in rows),
                         payloadFiles=manifest, sourceIdentitySHA256=digest)
