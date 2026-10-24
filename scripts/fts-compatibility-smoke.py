#!/usr/bin/env python3
"""Exercise actual legacy schema-13 writers against the migrated disposable FTS cache."""
import argparse,hashlib,json,pathlib,sqlite3,subprocess,tempfile
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary');p.add_argument('legacy_binary');p.add_argument('--output');o=p.parse_args();binary=pathlib.Path(o.binary).resolve();legacy=pathlib.Path(o.legacy_binary).resolve();pins={str(b):hashlib.sha256(b.read_bytes()).hexdigest() for b in [binary,legacy]}
with tempfile.TemporaryDirectory(prefix='oswind-fts-legacy-') as temporary:
    root=pathlib.Path(temporary);library=root/'library'
    def cli(runner,*args):
        result=subprocess.run([str(runner),'--data',str(library),*map(str,args)],capture_output=True,text=True,check=True,timeout=90)
        return json.loads(result.stdout) if result.stdout.lstrip().startswith(('{','[')) else result.stdout.strip()
    # Seed with the older release first, then open/migrate through the new reader.
    source=cli(legacy,'note','legacy seed phrase');snapshot=cli(legacy,'get',source)
    cli(binary,'stats')
    with sqlite3.connect(library/'memory.sqlite') as db:identity=db.execute("SELECT value FROM store_metadata WHERE key='identity'").fetchone()[0]
    old=cli(legacy,'note','old writer insertion')
    snapshot['text']='updated exact phrase';snapshot['title']='Updated owned fixture';input_path=root/'input.json';input_path.write_text(json.dumps([snapshot]));cli(legacy,'import',input_path)
    assert {x['memory']['id'] for x in cli(binary,'search','--mode','keyword','"updated exact phrase"')}=={source}
    cli(legacy,'delete',old)
    # Explicit compaction and a source-table rowid renumber do not change stable FTS keys.
    with sqlite3.connect(library/'memory.sqlite') as db:
        db.execute('PRAGMA foreign_keys=ON');db.execute('UPDATE memories SET rowid=rowid+10000');db.commit();db.execute('VACUUM')
        assert db.execute("SELECT value FROM store_metadata WHERE key='identity'").fetchone()[0]==identity
        assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok' and not db.execute('PRAGMA foreign_key_check').fetchall()
        assert db.execute('SELECT COUNT(*) FROM memories m LEFT JOIN memory_fts_keys k ON k.memory_id=m.id LEFT JOIN memory_fts f ON f.rowid=k.key WHERE f.id IS NOT m.id OR f.text IS NOT m.text').fetchone()[0]==0
        assert db.execute('SELECT COUNT(*) FROM memory_fts_keys').fetchone()[0]==1
    cli(legacy,'delete',source);assert cli(binary,'stats')['count']==0
    with sqlite3.connect(library/'memory.sqlite') as db:assert db.execute('SELECT COUNT(*) FROM memory_fts').fetchone()[0]==0 and db.execute('SELECT COUNT(*) FROM memory_fts_keys').fetchone()[0]==0
assert all(hashlib.sha256(pathlib.Path(b).read_bytes()).hexdigest()==s for b,s in pins.items())
report=dict(format='OSwind actual legacy FTS-writer compatibility v1',binary_sha256=pins[str(binary)],legacy_binary_sha256=pins[str(legacy)],legacy_seed_then_new_migration=True,legacy_insert_upsert_delete=True,exact_phrase_retrieval=True,source_rowid_renumber_and_vacuum=True,source_identity_preserved=True,sqlite_integrity_pass=True,limits=['Owned fixture and this pinned legacy executable only; not arbitrary/future writer compatibility'])
if o.output:pathlib.Path(o.output).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
