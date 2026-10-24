#!/usr/bin/env python3
"""Kill/retry an owned pre-tag archive clone during first-open installation."""
import argparse,contextlib,hashlib,json,pathlib,signal,sqlite3,subprocess,time
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary',type=pathlib.Path);p.add_argument('--fixture',required=True,type=pathlib.Path);p.add_argument('--root',required=True,type=pathlib.Path);a=p.parse_args()
binary=a.binary.resolve();fixture=a.fixture.resolve();root=a.root.resolve();marker=json.loads((fixture/'owned-activity-fixture.json').read_text())
assert marker['format']=='OSwind owned activity benchmark fixture v1' and marker['normalHistory'] is False and 10000<=marker['sources']<=2000000
source=fixture/'library/memory.sqlite';wal=source.with_name(source.name+'-wal');assert not wal.exists() or wal.stat().st_size==0
root.mkdir(mode=0o700,exist_ok=False);library=root/'library';library.mkdir(mode=0o700);database=library/'memory.sqlite'
subprocess.run(['cp','-c',str(source),str(database)],check=True)
def state(with_hash=False):
    with contextlib.closing(sqlite3.connect(database)) as db:
        result=dict(schema=db.execute('PRAGMA user_version').fetchone()[0],sources=db.execute('SELECT COUNT(*) FROM memories').fetchone()[0],tagTable=bool(db.execute("SELECT COUNT(*) FROM sqlite_master WHERE name='memory_tags'").fetchone()[0]),tagMarker=bool(db.execute("SELECT COUNT(*) FROM store_metadata WHERE key='tag_index_version'").fetchone()[0]))
        if with_hash:
            h=hashlib.sha256()
            for id,payload in db.execute('SELECT id,payload FROM memories ORDER BY id'):h.update(id.encode());h.update(payload)
            result['logicalSourceSHA256']=h.hexdigest()
        return result
before=state(with_hash=True);assert before['sources']==marker['sources'] and before['schema']==20 and not before['tagTable'] and not before['tagMarker']
prefix=[str(binary),'--data',str(library)];pending_wal=database.with_name(database.name+'-wal')
with (root/'interrupted.stdout').open('wb') as stdout,(root/'interrupted.stderr').open('wb') as stderr:
    process=subprocess.Popen(prefix+['stats','--json'],stdout=stdout,stderr=stderr)
    try:
        deadline=time.monotonic()+90
        while time.monotonic()<deadline:
            assert process.poll() is None,'Installation finished before the interruption point'
            if pending_wal.exists() and pending_wal.stat().st_size>=2*1024*1024:break
            time.sleep(.01)
        else:raise AssertionError('No owned migration WAL growth observed')
        wal_bytes=pending_wal.stat().st_size;process.send_signal(signal.SIGKILL);assert process.wait(timeout=10)==-signal.SIGKILL
    finally:
        if process.poll() is None:process.kill();process.wait(timeout=10)
interrupted=state();assert interrupted=={k:v for k,v in before.items() if k!='logicalSourceSHA256'}
started=time.monotonic();retry=subprocess.run(prefix+['stats','--json'],capture_output=True,check=True,timeout=180);retry_seconds=time.monotonic()-started
assert json.loads(retry.stdout)['count']==marker['sources'];after=state(with_hash=True)
assert after['schema']==21 and after['tagTable'] and after['tagMarker'] and after['logicalSourceSHA256']==before['logicalSourceSHA256']
with contextlib.closing(sqlite3.connect(database)) as db:
    oracle="SELECT DISTINCT m.id,t.value,m.timestamp,m.app,m.kind,m.favorite FROM memories m,json_each(CAST(m.payload AS TEXT),'$.tags') t WHERE t.type='text'";columns='memory_id,tag,timestamp,app,kind,favorite'
    assert db.execute(f'SELECT COUNT(*) FROM ({oracle} EXCEPT SELECT {columns} FROM memory_tags)').fetchone()[0]==0
    assert db.execute(f'SELECT COUNT(*) FROM (SELECT {columns} FROM memory_tags EXCEPT {oracle})').fetchone()[0]==0
report=dict(format='OSwind tag installation kill retry v1',binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),harnessSHA256=hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),scope='Marked owned APFS archive clone; actual SIGKILL after uncommitted WAL growth, SQLite recovery and successful first-open retry. Pre/post payload hashes warm caches; no UI, capture, power or competitor claim.',fixture=marker,observedMigrationWALBytes=wal_bytes,processExitCode=-signal.SIGKILL,uncommittedProjectionAbsentAfterRecovery=True,sourcePayloadsPreserved=True,logicalSourceSHA256=after['logicalSourceSHA256'],fullProjectionSQLJSONOraclePass=True,retryWallSeconds=retry_seconds,passed=True)
(root/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
