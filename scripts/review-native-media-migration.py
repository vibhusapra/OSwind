#!/usr/bin/env python3
"""Review owned migration SIGKILL snapshots without opening the product store."""
from pathlib import Path
import argparse,contextlib,hashlib,json,sqlite3,datetime

p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
root=a.root.resolve();out=a.output.absolute()
assert root.is_dir() and out.parent.is_dir()
assert out.resolve().parent!=root and not out.is_symlink()
assert not out.exists(),'Keep completed reviews frozen'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
proofs=[]
for folder in sorted(root.iterdir()):
    expected=json.loads((folder/'expected.json').read_text());phase=expected['phase']
    assert (folder/'ready').read_text()==phase
    files={p.name:sha(p) for p in folder.glob('memory.sqlite*') if p.is_file()}
    assert 'memory.sqlite-wal' in files
    if phase=='afterCommit':assert (folder/'memory.sqlite-wal').stat().st_size>0
    with contextlib.closing(sqlite3.connect((folder/'memory.sqlite').as_uri()+'?mode=ro',uri=True)) as c:
        c.execute('PRAGMA query_only=ON')
        c.create_function('oswind_media_admission_writer_v1',0,lambda:1)
        version=c.execute('PRAGMA user_version').fetchone()[0]
        kind=c.execute("SELECT type FROM sqlite_master WHERE name='erasure_assets'").fetchone()[0]
        paths=c.execute('SELECT path FROM erasure_assets').fetchall()
        assert version==(33 if phase=='afterCommit' else 32)
        assert kind==('view' if phase=='afterCommit' else 'table')
        assert paths==[('images/owned-pending.png',)]
        assert c.execute('SELECT count(*) FROM memories').fetchone()==(1,)
        assert c.execute('PRAGMA integrity_check').fetchall()==[('ok',)]
        assert c.execute('PRAGMA foreign_key_check').fetchall()==[]
        identity=c.execute("SELECT value FROM store_metadata WHERE key='identity'").fetchone()[0]
        assert identity==expected['before']['identity']
        assert c.execute("SELECT count(*) FROM store_metadata WHERE key='recap_cache_dirty' AND value='1'").fetchone()[0]==(0 if version==33 else 1)
        assert c.execute("SELECT count(*) FROM store_metadata WHERE key='recap_cache_dirty_v33' AND value='1'").fetchone()[0]==(1 if version==33 else 0)
    after={p.name:sha(p) for p in folder.glob('memory.sqlite*') if p.is_file()}
    assert {k:v for k,v in files.items() if not k.endswith('-shm')}=={k:v for k,v in after.items() if not k.endswith('-shm')}
    image=folder/'images/owned-pending.png'
    assert sha(image)=='0254bbb96343f9806745d47d11df8af03364d722e342b380abbfe1b02353d74f'
    proofs.append(dict(phase=phase,nativeSchema=version,queueType=kind,queued=1,sources=1,identityPreserved=True,integrity=True,foreignKeys=True,mainAndWALUnchanged=True,files=files,PNG_SHA256=sha(image),parentExpectedSHA256=sha(folder/'expected.json'),childLogSHA256=sha(folder/'child.log')))
assert {p['phase'] for p in proofs}=={'afterCommit','beforeCommit','mediaQueueCopied'} and len(proofs)==3
result=dict(state='passed',reviewerSHA256=sha(Path(__file__)),recordedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),proofs=proofs,scope='Independent Python read-only SQLite review of owned roots retained after actual migration-child SIGKILL, before product reopen. WAL participates; no immutable bypass. SHM read marks may change. No storage power-loss or native UI claim.')
out.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'state':'passed','proofs':len(proofs),'schemas':[p['nativeSchema'] for p in proofs]}))
