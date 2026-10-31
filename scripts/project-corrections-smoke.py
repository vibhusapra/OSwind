#!/usr/bin/env python3
"""Owned project-ID corrections, legacy21 repair, read-only scopes and erasure.
Only authored fixtures in a newly created root; never opens normal history.
"""
import http.client as http_client
import argparse,contextlib,hashlib,json,pathlib,select,socket,sqlite3,subprocess,time,urllib.parse
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary',type=pathlib.Path);p.add_argument('--root',required=True,type=pathlib.Path);p.add_argument('--old-cli',type=pathlib.Path);a=p.parse_args()
binary=a.binary.resolve();root=a.root.resolve();root.mkdir(mode=0o700,parents=True,exist_ok=False);library=root/'library';old=a.old_cli.resolve() if a.old_cli else None
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
def cmd(*args,data=library,cli=binary,raw=False):
 r=subprocess.run([str(cli),'--data',str(data),*map(str,args)],capture_output=True,text=True,timeout=180);assert r.returncode==0,r.stderr
 return r.stdout.strip() if raw else json.loads(r.stdout)
def sql(query,data=library,args=()):
 with contextlib.closing(sqlite3.connect(data/'memory.sqlite')) as db:return list(db.execute(query,args))
def sourceIDs(id,data=library):return {v['id'] for v in cmd('entity','sources',id,data=data)}
legacy=None
if old:
 data=root/'legacy21';source=cmd('note','Apollo Launch legacy correction fixture',data=data,cli=old,raw=True);project=cmd('entity','create','project','Apollo Launch',data=data,cli=old)
 cmd('entity','index',data=data,cli=old);cmd('entity','unlink',project['id'],source,data=data,cli=old)
 cmd('entity','edit',project['id'],'--name','Atlas Release','--aliases','Apollo Launch,Atlas Release',data=data,cli=old);cmd('entity','index',data=data,cli=old)
 assert sql('PRAGMA user_version',data)[0][0]==21 and len(cmd('entity','sources',project['id'],data=data,cli=old))==1
 payloads=sql('SELECT id,hex(payload) FROM memories ORDER BY id',data);archive=root/'legacy21.oswindbackup';assert cmd('backup','create',archive,data=data,cli=old)['sourceSchema']==21
 # Upgrade repairs a wrongly re-added automatic edge without repeating NLP.
 assert sourceIDs(project['id'],data)==set() and cmd('entity','progress',data=data)['indexed']==1
 assert payloads==sql('SELECT id,hex(payload) FROM memories ORDER BY id',data)
 refused=subprocess.run([str(old),'--data',str(data),'stats'],capture_output=True,text=True,timeout=30);assert refused.returncode!=0 and 'newer OSwind' in refused.stderr
 restored=root/'legacy-restored';subprocess.run([str(binary),'backup','restore',str(archive),'--to',str(restored)],check=True,capture_output=True,timeout=180)
 assert sourceIDs(project['id'],restored)==set();cmd('entity','index',data=restored);assert sourceIDs(project['id'],restored)==set()
 legacy=dict(binarySHA256=sha(old),sourceSchema=21,priorWrongAutomaticLinks=1,upgradedAutomaticLinks=0,completedSourcesRetained=1,sourcePayloadsUnchanged=True,olderClientRefused=True,legacyQuietRestoreAndRescanPreservesRejection=True)
rows=[dict(id=id,timestamp='2026-10-24T12:00:00Z',kind='note',app='Owned correction fixture',bundleID='org.oswind.project-corrections',title=id,text=text,tags=[],favorite=False,regions=[]) for id,text in [('source-a','Apollo Launch has an authored source A.'),('source-b','Apollo Launch has an authored source B.'),('unrelated','An unrelated authored reading list.')]]
def ingest(values,name):
 path=root/name;path.write_text(json.dumps(values));assert cmd('import',path,'--json')['imported']==len(values)
ingest(rows,'sources.json');project=cmd('entity','create','project','Apollo Launch');cmd('entity','index');assert sourceIDs(project['id'])=={'source-a','source-b'}
cmd('entity','unlink',project['id'],'source-a');cmd('entity','edit',project['id'],'--name','Atlas Release','--aliases','Apollo Launch,Atlas Release');cmd('entity','index');assert sourceIDs(project['id'])=={'source-b'}
changed=dict(rows[0],favorite=True,tags=['owned']);ingest([changed],'metadata.json');cmd('entity','index');assert sourceIDs(project['id'])=={'source-b'}
target=cmd('entity','create','project','Final Project');cmd('entity','merge',project['id'],'--into',target['id']);cmd('entity','index');assert sourceIDs(target['id'])=={'source-b'}
cmd('entity','link',target['id'],'source-a');cmd('entity','edit',target['id'],'--aliases','Apollo Launch,Atlas Release,Final Project,UNUSED-CORRECTION-42');cmd('entity','index')
assert next(s for s in cmd('entity','sources',target['id']) if s['id']=='source-a')['origin']=='automatic'
cmd('entity','unlink',target['id'],'source-a');cmd('entity','delete',target['id']);replacement=cmd('entity','create','project','Final Project');assert replacement['id']!=target['id']
cmd('entity','edit',replacement['id'],'--aliases','Apollo Launch,Final Project');cmd('entity','index');assert sourceIDs(replacement['id'])=={'source-a','source-b'}
cmd('entity','unlink',replacement['id'],'source-a');cmd('entity','edit',replacement['id'],'--name','Release Beta','--aliases','Apollo Launch,Final Project,Release Beta');cmd('entity','index');assert sourceIDs(replacement['id'])=={'source-b'}
# Read-only transports and scoped evidence must not resurrect excluded sources.
process=subprocess.Popen([str(binary),'--data',str(library),'mcp'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
try:
 def rpc(id,method,params):
  process.stdin.write(json.dumps(dict(jsonrpc='2.0',id=id,method=method,params=params))+'\n');process.stdin.flush();assert select.select([process.stdout],[],[],30)[0]
  r=json.loads(process.stdout.readline());assert r['id']==id;return r['result']
 rpc(1,'initialize',{'protocolVersion':'2025-11-25'})
 result=rpc(2,'tools/call',{'name':'entity_sources','arguments':{'id':replacement['id']}});assert not result.get('isError');assert {s['id'] for s in json.loads(result['content'][0]['text'])}=={'source-b'}
finally:
 process.stdin.close()
 try:assert process.wait(timeout=15)==0
 except subprocess.TimeoutExpired:process.kill();process.wait(timeout=10);raise
with socket.socket() as probe:assert probe.connect_ex(('127.0.0.1',47831))!=0,'Owned test API port occupied'
server=subprocess.Popen([str(binary),'--data',str(library),'serve'],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,text=True)
try:
 def http(path):
  connection=http_client.HTTPConnection('127.0.0.1',47831,timeout=3)
  try:
   connection.request('GET',path,headers={'Host':'127.0.0.1:47831','Authorization':'Bearer '+(library/'api-token').read_text()});r=connection.getresponse();return r.status,json.loads(r.read())
  finally:connection.close()
 deadline=time.monotonic()+15
 while True:
  assert server.poll() is None
  try:
   if http('/health')[0]==200:break
  except (OSError,FileNotFoundError):pass
  assert time.monotonic()<deadline;time.sleep(.05)
 status,values=http('/v1/entity-sources?'+urllib.parse.urlencode({'id':replacement['id']}));assert status==200 and {s['id'] for s in values}=={'source-b'}
finally:
 server.terminate()
 try:server.wait(timeout=15)
 except subprocess.TimeoutExpired:server.kill();server.wait(timeout=10);raise
assert {s['memory']['id'] for s in cmd('search','--mode','keyword','--entity',replacement['id'],'Apollo')}=={'source-b'}
archive=root/'current.oswindbackup';assert cmd('backup','create',archive)['sourceSchema']==25
restored=root/'restored';subprocess.run([str(binary),'backup','restore',str(archive),'--to',str(restored)],check=True,capture_output=True,timeout=180)
assert not json.loads((restored/'settings.json').read_text())['entityAutomaticIndex'];assert cmd('entity','progress',data=restored)['indexed']==0
cmd('entity','index',data=restored);assert sourceIDs(replacement['id'],restored)=={'source-b'}
cmd('delete','source-a','--json');assert sql('SELECT COUNT(*) FROM entity_project_ignored')[0][0]==0
cmd('wipe','--confirm','DELETE-ALL','--json');assert cmd('entity','list')==[] and sql('SELECT COUNT(*) FROM entity_project_ignored')[0][0]==0
report=dict(format='OSwind stable project correction process qualification v1',passed=True,schema=25,binarySHA256=sha(binary),harnessSHA256=sha(pathlib.Path(__file__)),legacy21=legacy,checks=['rename and merge retain rejected project source','favorite/tags preserve exclusion','manual override restores automatic matching','deleting project erases its stable exclusions before name reuse','MCP/HTTP and scoped keyword retrieval omit rejected source','quiet25 backup resets completion and preserves correction after rescan','source deletion and full wipe erase stable exclusions'],scope='Three authored notes and actual CLI/HTTP/MCP/storage processes; optional exact older21 binary covers native format migration/refusal and legacy archive repair. No normal history, representative NLP accuracy, native UI, device, power or competitor claim.')
(root/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
