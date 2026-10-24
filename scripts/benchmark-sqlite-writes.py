#!/usr/bin/env python3
"""Owned SQLite component writes, excluding capture, inference and JSON encoding.

Uses the supplied OSwind CLI to create isolated libraries, then exercises their
actual triggers/indexes through SQLite. Not an end-to-end ingestion benchmark.
"""
import argparse,contextlib,hashlib,json,pathlib,sqlite3,statistics,subprocess,time
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary',type=pathlib.Path);p.add_argument('--root',required=True,type=pathlib.Path);p.add_argument('--records',type=int,default=2000);p.add_argument('--repetitions',type=int,default=3);a=p.parse_args()
assert 100<=a.records<=10000 and 1<=a.repetitions<=10
binary=a.binary.resolve();root=a.root.resolve();root.mkdir(mode=0o700,exist_ok=False);results={}
for case,text_bytes,tags in [('untagged1k',1024,[]),('tagged1k',1024,['release','shared']),('tagged64k',65536,['release','shared'])]:
    trials=[];text=('Owned synthetic SQLite source. '*((text_bytes+31)//32))[:text_bytes]
    for repetition in range(a.repetitions):
        library=root/(case+'-'+str(repetition));prefix=[str(binary),'--data',str(library)]
        boot=time.monotonic();subprocess.run(prefix+['stats','--json'],capture_output=True,check=True,timeout=120);boot_ms=(time.monotonic()-boot)*1000
        inserts=[];updates=[];edits=[];identifiers=[]
        for i in range(a.records):
            id='owned-write-'+str(i);stamp=1710072000+i
            source=dict(id=id,timestamp=stamp-978307200,kind='note',app='Owned',bundleID='org.oswind.owned',title='Owned',text=text,favorite=False,tags=tags,regions=[])
            payload=json.dumps(source,separators=(',',':')).encode();inserts.append((id,stamp,'note','Owned','Owned',text,0,payload))
            source['favorite']=True;updates.append((1,json.dumps(source,separators=(',',':')).encode(),id))
            source['tags']=['review','shared'];edits.append((json.dumps(source,separators=(',',':')).encode(),id));identifiers.append((id,))
        with contextlib.closing(sqlite3.connect(library/'memory.sqlite')) as db:
            db.execute('PRAGMA foreign_keys=ON');db.execute('PRAGMA secure_delete=ON');db.execute('PRAGMA synchronous=NORMAL');db.execute('PRAGMA busy_timeout=5000')
            indexed=bool(db.execute("SELECT COUNT(*) FROM sqlite_master WHERE name='memory_tags'").fetchone()[0])
            phases={}
            def measure(name,sql,rows):
                start=time.monotonic();db.execute('BEGIN IMMEDIATE');db.executemany(sql,rows);db.commit();elapsed=(time.monotonic()-start)*1000
                phases[name]=dict(wallMS=elapsed,operations=len(rows),operationsPerSecond=len(rows)/(elapsed/1000))
            measure('insert','INSERT INTO memories(id,timestamp,kind,app,title,text,favorite,payload) VALUES(?,?,?,?,?,?,?,?)',inserts)
            measure('favoriteAndPayloadUpdate','UPDATE memories SET favorite=?,payload=? WHERE id=?',updates)
            measure('tagAndPayloadUpdate','UPDATE memories SET payload=? WHERE id=?',edits)
            measure('deleteHalf','DELETE FROM memories WHERE id=?',identifiers[:a.records//2])
            remaining=a.records-a.records//2;assert db.execute('SELECT COUNT(*) FROM memories').fetchone()[0]==remaining
            assert db.execute("SELECT COUNT(*) FROM memories WHERE favorite=1 AND json_extract(CAST(payload AS TEXT),'$.favorite')=1").fetchone()[0]==remaining
            if indexed:
                oracle="SELECT DISTINCT m.id,t.value,m.timestamp,m.app,m.kind,m.favorite FROM memories m,json_each(CAST(m.payload AS TEXT),'$.tags') t WHERE t.type='text'"
                columns='memory_id,tag,timestamp,app,kind,favorite'
                assert db.execute(f'SELECT COUNT(*) FROM ({oracle} EXCEPT SELECT {columns} FROM memory_tags)').fetchone()[0]==0
                assert db.execute(f'SELECT COUNT(*) FROM (SELECT {columns} FROM memory_tags EXCEPT {oracle})').fetchone()[0]==0
            db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        assert json.loads(subprocess.run(prefix+['stats','--json'],capture_output=True,check=True,timeout=120).stdout)['count']==remaining
        trials.append(dict(repetition=repetition,libraryCreateWallMS=boot_ms,tagIndexPresent=indexed,databaseBytes=(library/'memory.sqlite').stat().st_size,phases=phases,finalSourceCount=remaining,independentSQLConsistencyPass=True))
        print(json.dumps({'case':case,'repetition':repetition,'phasesMS':{k:round(v['wallMS'],2) for k,v in phases.items()}}),flush=True)
    results[case]=dict(textBytes=text_bytes,initialTags=len(tags),trials=trials,medianPhaseMS={name:statistics.median(t['phases'][name]['wallMS'] for t in trials) for name in trials[0]['phases']})
report=dict(format='OSwind SQLite component writes v1',binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),harnessSHA256=hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),records=a.records,repetitions=a.repetitions,scope='Owned SQLite writes through actual installed schema/triggers. Excludes JSON encoding, application admission, capture and models; not end-to-end ingestion or competitor evidence. Uncontrolled caches and host activity. Counts/payload flags and optional tag projection checked independently.',cases=results)
(root/'report.json').write_text(json.dumps(report,indent=2)+'\n')
