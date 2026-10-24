#!/usr/bin/env python3
"""Owned source-linked entity indexing, explicit scopes, erasure and portability.

Project-alias matching has an independent deterministic oracle. Native NLP names
are observed, not scored as verified identities or a representative benchmark.
"""
import argparse,contextlib,hashlib,json,pathlib,select,sqlite3,subprocess,time

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('binary',type=pathlib.Path);p.add_argument('--root',required=True,type=pathlib.Path)
p.add_argument('--old-cli',required=True,type=pathlib.Path);a=p.parse_args()
binary=a.binary.resolve();old=a.old_cli.resolve();root=a.root.resolve();root.mkdir(mode=0o700,exist_ok=False)
library=root/'library'
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def cmd(*args,data=library,cli=binary):
    result=subprocess.run([str(cli),'--data',str(data),*map(str,args)],capture_output=True,text=True,timeout=180)
    assert result.returncode==0,result.stderr
    return json.loads(result.stdout) if result.stdout.strip() else None
def run(*args):subprocess.run([str(binary),*map(str,args)],check=True,capture_output=True,timeout=180)
def members(data=library):
    with contextlib.closing(sqlite3.connect(data/'memory.sqlite')) as db:
        return {r[0] for r in db.execute('SELECT DISTINCT memory_id FROM entity_mentions WHERE entity_id=?',(project['id'],))}
rows=[];expected=set()
for i in range(1000):
    id=f'owned-{i:04d}'
    if i%3==0:text='Maya Chen reviewed Apollo Launch. Next: accessibility review.';expected.add(id)
    elif i%3==1:text='Work on ALPHA42 with the platform team.';expected.add(id)
    else:text='Apollonian launcher notes. This is unrelated synthetic work.'
    rows.append(dict(id=id,timestamp='2026-10-24T12:00:00Z',kind='note',app='Owned entity fixture',title='Synthetic source '+str(i),text=text,tags=[],favorite=False,regions=[]))
input_file=root/'sources.json';input_file.write_text(json.dumps(rows));assert cmd('import',input_file)['imported']==1000
project=cmd('entity','create','project','Apollo Launch','--notes','Explicit synthetic project definition')
cmd('entity','edit',project['id'],'--aliases','Apollo Launch,ALPHA42')
first=time.monotonic();progress=cmd('entity','index');first=time.monotonic()-first
assert progress==dict(eligible=1000,indexed=1000,limited=0);assert members()==expected
resume=time.monotonic();assert cmd('entity','index')==progress;resume=time.monotonic()-resume
hits=cmd('search','--mode','keyword','--entity',project['id'],'--limit','100','--literal')
assert len(hits)==100 and {h['memory']['id'] for h in hits}<=expected
assert cmd('search','--mode','keyword','--entity','missing','--literal')==[]
assert len(cmd('entity','sources',project['id']))==100
# Exact UTF-16 source spans are checked against the actual stored source text.
with contextlib.closing(sqlite3.connect(library/'memory.sqlite')) as db:
    assert db.execute('PRAGMA user_version').fetchone()[0]==21
    count=0
    for text,start,length,surface in db.execute("SELECT m.text,e.start,e.length,e.surface FROM entity_mentions e JOIN memories m ON m.id=e.memory_id WHERE e.origin='automatic'"):
        assert text.encode('utf-16-le')[2*start:2*(start+length)].decode('utf-16-le')==surface;count+=1
    observed=[dict(kind=k,name=n,sources=c) for k,n,c in db.execute("SELECT e.kind,e.name,COUNT(DISTINCT m.memory_id) FROM memory_entities e LEFT JOIN entity_mentions m ON m.entity_id=e.id GROUP BY e.id ORDER BY e.kind,e.name")]
refusal=subprocess.run([str(old),'--data',str(library),'stats'],capture_output=True,text=True,timeout=30)
assert refusal.returncode!=0 and 'newer OSwind' in refusal.stderr
# Rejected automatic link stays rejected when project-rule changes require a rescan.
rejected=sorted(expected)[0];cmd('entity','unlink',project['id'],rejected)
cmd('entity','edit',project['id'],'--notes','Rebuild after deliberate rule revision')
cmd('entity','index');assert members()==expected-{rejected}
# Live MCP exposes the same membership and rejects unknown write parameters.
process=subprocess.Popen([str(binary),'--data',str(library),'mcp'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
try:
    def rpc(id,method,params):
        process.stdin.write(json.dumps(dict(jsonrpc='2.0',id=id,method=method,params=params))+'\n');process.stdin.flush()
        assert select.select([process.stdout],[],[],30)[0],"MCP response timeout";result=json.loads(process.stdout.readline());assert result['id']==id;return result['result']
    rpc(1,'initialize',{'protocolVersion':'2025-11-25'})
    listing=rpc(2,'tools/call',{'name':'memory_entities','arguments':{'kind':'project'}})
    assert not listing.get('isError');assert json.loads(listing['content'][0]['text'])[0]['id']==project['id']
    sources=rpc(3,'tools/call',{'name':'entity_sources','arguments':{'id':project['id']}})
    assert len(json.loads(sources['content'][0]['text']))==100
    denied=rpc(4,'tools/call',{'name':'memory_entities','arguments':{'write':True}});assert denied['isError']
finally:
    process.stdin.close()
    try:assert process.wait(timeout=15)==0
    except subprocess.TimeoutExpired:process.kill();process.wait(timeout=10);raise
archive=root/'archive.oswindbackup';restored=root/'restored'
run('--data',library,'backup','create',archive);run('backup','restore',archive,'--to',restored)
assert members(restored)==expected-{rejected}
restored_project=next(r for r in cmd('entity','list',data=restored) if r['id']==project['id'])
assert restored_project['detail']=='Rebuild after deliberate rule revision' and set(restored_project['aliases'])=={'Apollo Launch','ALPHA42'}
assert not json.loads((restored/'settings.json').read_text())['entityAutomaticIndex']
assert cmd('entity','progress',data=restored)['indexed']==0
assert cmd('entity','index',data=restored)['indexed']==1000;assert members(restored)==expected-{rejected}
cmd('delete',sorted(expected)[1]);assert sorted(expected)[1] not in members()
cmd('wipe','--confirm','DELETE-ALL');assert cmd('entity','list')==[]
report=dict(format='OSwind source-linked entity memory qualification v1',binarySHA256=sha(binary),olderSchema20BinarySHA256=sha(old),harnessSHA256=sha(pathlib.Path(__file__)),schema=21,passed=True,sources=1000,projectOracleSources=len(expected),projectPrecision=1.0,projectRecall=1.0,automaticSpansVerified=count,firstIndexWallSeconds=first,resumeWallSeconds=resume,observedNLPAndProjectGroups=observed,checks=['exact project alias oracle','UTF16 source anchors','scoped keyword retrieval','schema20 client refusal','correction survives rule-rescan','read-only MCP membership and validation','quiet backup restore retains definitions, aliases and links','restored completion reset','source erasure','full wipe erases curated definitions'],scope='Synthetic local project-alias fixture and observed Apple NLP outputs. Wall times include CLI startup, SQLite and native NLP with uncontrolled caches; no native NLP precision/recall, real desktop identity, power, latest 24h capture or competitor claim.')
(root/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
