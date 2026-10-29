#!/usr/bin/env python3
"""Owned schema24 tag projection, schema20 refusal, JSON and quiet backup portability."""
import argparse,contextlib,hashlib,json,pathlib,sqlite3,subprocess
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary',type=pathlib.Path);p.add_argument('--root',required=True,type=pathlib.Path);p.add_argument('--old-cli',type=pathlib.Path);a=p.parse_args()
binary=a.binary.resolve();older=a.old_cli.resolve() if a.old_cli else binary;root=a.root.resolve();root.mkdir(mode=0o700,exist_ok=False);library=root/'library';input_file=root/'sources.json'
def run(cli,*args):
    r=subprocess.run([str(cli),*map(str,args)],capture_output=True,text=True,timeout=120);assert r.returncode==0,r.stderr;return r.stdout
def command(*args,cli=binary,data=library):return json.loads(run(cli,'--data',data,*args))
def source(id,tags,**extra):return dict(id=id,timestamp='2024-03-10T12:00:00Z',kind='note',app='Owned fixture',bundleID='org.oswind.owned',title='Owned',text='TagIndexOwnedSource',favorite=True,tags=tags,regions=[])|extra
def write(rows,cli):
    input_file.write_text(json.dumps(rows));assert command('import',input_file,'--json',cli=cli)['imported']==len(rows)
def calendar(tag,**kwargs):return command('activity','--month','2024-03','--tag',tag,**kwargs)['totalSources']
def aligned(data=library):
    with contextlib.closing(sqlite3.connect(data/'memory.sqlite')) as db:
        columns='memory_id,tag,timestamp,app,kind,favorite';oracle="SELECT DISTINCT m.id,t.value,m.timestamp,m.app,m.kind,m.favorite FROM memories m,json_each(CAST(m.payload AS TEXT),'$.tags') t WHERE t.type='text'"
        assert db.execute(f'SELECT COUNT(*) FROM (SELECT {columns} FROM memory_tags EXCEPT {oracle})').fetchone()[0]==0
        assert db.execute(f'SELECT COUNT(*) FROM ({oracle} EXCEPT SELECT {columns} FROM memory_tags)').fetchone()[0]==0
        assert db.execute('PRAGMA user_version').fetchone()[0]==23
rows=[source('first',['release','release','Review']),source('second',['release'])];write(rows,older)
with contextlib.closing(sqlite3.connect(library/'memory.sqlite')) as db:
    assert db.execute('PRAGMA user_version').fetchone()[0]==(20 if a.old_cli else 23)
    if a.old_cli:assert db.execute("SELECT COUNT(*) FROM sqlite_master WHERE name='memory_tags'").fetchone()[0]==0
    else:
        db.executescript("DROP TRIGGER tag_index_insert; DROP TRIGGER tag_index_update; DROP TRIGGER tag_index_delete; DROP TABLE memory_tags; DELETE FROM store_metadata WHERE key='tag_index_version'; DROP INDEX memories_activity_time")
    before=db.execute('SELECT id,payload FROM memories ORDER BY id').fetchall()
assert calendar('release')==2 and calendar('Review')==1 and calendar('review')==0;aligned()
with contextlib.closing(sqlite3.connect(library/'memory.sqlite')) as db:assert db.execute('SELECT id,payload FROM memories ORDER BY id').fetchall()==before
if a.old_cli:
    refused=subprocess.run([str(older),'--data',str(library),'stats'],capture_output=True,text=True,timeout=30)
    assert refused.returncode!=0 and 'newer OSwind' in refused.stderr
write([source('first',['revised'],timestamp='2024-03-11T12:00:00Z',kind='screen',app='Owned changed'),source('third',['revised','release'])],binary)
assert calendar('release')==2 and calendar('revised')==2 and calendar('Review')==0;aligned()
for tag,expected in [('release',{'second','third'}),('revised',{'first','third'}),('Review',set())]:
    for cli in [binary]:
        result=command('search','--mode','keyword','--literal','--tag',tag,'TagIndexOwnedSource',cli=cli)
        assert {hit['memory']['id'] for hit in result}==expected
archive=root/'Owned.oswindbackup';restored=root/'restored';run(binary,'--data',library,'backup','create',archive);run(binary,'backup','restore',archive,'--to',restored)
assert calendar('revised',data=restored)==2;aligned(restored)
quiet=json.loads((restored/'settings.json').read_text());assert not quiet['captureOnLaunch'] and not quiet['apiEnabled']
export=root/'export.json';run(binary,'--data',library,'export',export);json_library=root/'from-json';assert command('import',export,'--json',data=json_library)['imported']==3
assert calendar('release',data=json_library)==2;aligned(json_library)
report=dict(format='OSwind transactionally indexed tags v2',scope='Owned synthetic source/tag mutations, schema20 upgrade and refusal, exact search and quiet portability. No capture, normal history or credentials.',binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),olderBinarySHA256=hashlib.sha256(older.read_bytes()).hexdigest(),actualOlderSchema20Client=a.old_cli is not None,harnessSHA256=hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),schema=24,passed=True,checks=['schema20 to24 upgrade preserves exact source payloads' if a.old_cli else 'missing derived tag projection repairs without changing source payloads','duplicate tags count once; case stays exact','schema20 client refuses schema24; current writes maintain projection' if a.old_cli else 'current writes maintain projection; older client not supplied','current indexed searches agree with explicit source/tag membership','source metadata and tag rows match independent SQL JSON oracle','quiet backup restore rebuilds counts','JSON round trip rebuilds counts'])
(root/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
