#!/usr/bin/env python3
"""Owned schema25 canonical-capture process checks, optionally with actual old24.

The hidden capture flag is changed only in the fresh authored fixture. This is
not a public enrollment workflow, device sync or normal-history inspection.
"""
import argparse,concurrent.futures,hashlib,json,pathlib,sqlite3,struct,subprocess,time
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary',type=pathlib.Path);p.add_argument('--root',required=True,type=pathlib.Path);p.add_argument('--old-cli',type=pathlib.Path);a=p.parse_args()
binary=a.binary.resolve();base=a.root.resolve();base.mkdir(mode=0o700,exist_ok=False);library=base/'library'
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
report=dict(format='OSwind canonical capture process qualification',version=1,state='running',cliSHA256=sha(binary),harnessSHA256=sha(pathlib.Path(__file__)),checks=[],operations=[])
def save():
 f=base/'report.tmp';f.write_text(json.dumps(report,indent=2)+'\n');f.replace(base/'report.json')
def invoke(*args,data=library,cli=binary,input=None):return subprocess.run([str(cli),'--data',str(data),*map(str,args)],input=input,capture_output=True,text=True,timeout=90)
def record(result,name):
 report['operations'].append(dict(command=name,returncode=result.returncode,stdoutSHA256=hashlib.sha256(result.stdout.encode()).hexdigest(),stderrSHA256=hashlib.sha256(result.stderr.encode()).hexdigest()));save()
def run(*args,data=library,cli=binary,input=None,ok=True):
 r=invoke(*args,data=data,cli=cli,input=input);record(r,str(args[0]));assert (r.returncode==0)==ok,(str(args[0]),r.stdout,r.stderr);return r
batch=dict(format='OSwind collector batch',version=1,collectorID='org.oswind.capture-fixture',records=[dict(key='owned-late-record',timestamp='2026-10-30T12:00:00Z',app='Owned capture fixture',bundleID='org.oswind.capture-fixture',title='Owned source',text='OwnedLateWriterCanary5j82')]);wire=json.dumps(batch)+'\n'
def snapshot():
 with sqlite3.connect(library/'memory.sqlite') as db:return db.execute('SELECT id,hex(payload) FROM memories ORDER BY id').fetchall()
def activate():
 with sqlite3.connect(library/'memory.sqlite') as db:db.execute('UPDATE personal_sync_capture SET enabled=1 WHERE singleton=1')
try:
 if a.old_cli:
  old=a.old_cli.resolve();run('note','Owned original schema24 source',cli=old)
  with sqlite3.connect(library/'memory.sqlite') as db:assert db.execute('PRAGMA user_version').fetchone()==(24,)
  before=snapshot();child=subprocess.Popen([str(old),'--data',str(library),'collect','--stdin'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  try:
   # This lock is acquired by collect after MemoryStore construction, so the
   # old process has actually opened24 before the current client upgrades it.
   target='n'+str(library/'.media-admission.lock');deadline=time.monotonic()+20;ready=False
   while child.poll() is None and time.monotonic()<deadline:
    listing=subprocess.run(['/usr/sbin/lsof','-a','-p',str(child.pid),'-Fn'],capture_output=True,text=True,timeout=5)
    if target in listing.stdout.splitlines():ready=True;break
    time.sleep(.05)
   assert ready,'Owned old24 collector did not reach its post-open media lease'
   run('stats');assert snapshot()==before
   output,error=child.communicate(wire,timeout=30);assert child.returncode!=0
   (base/'old-initialized-writer.stdout').write_text(output);(base/'old-initialized-writer.stderr').write_text(error)
   assert snapshot()==before
   report['oldClient']=dict(binarySHA256=sha(old),sourceSchema=24,alreadyInitializedLeaseObserved=True,lateWriteRefused=True,sourcePayloadsPreserved=True,returncode=child.returncode,stderrSHA256=hashlib.sha256(error.encode()).hexdigest())
   report['checks'].append('actual initialized schema24 writer refuses after schema25 migration without changing original source payloads')
  finally:
   if child.poll() is None:
    child.terminate()
    try:child.communicate(timeout=5)
    except subprocess.TimeoutExpired:child.kill();child.communicate(timeout=5)
  run('note','Owned unsupported old24 write',cli=old,ok=False);assert snapshot()==before
 else:run('note','Owned initial schema25 source')
 with sqlite3.connect(library/'memory.sqlite') as db:
  assert db.execute('PRAGMA user_version').fetchone()==(25,)
  assert db.execute('SELECT enabled FROM personal_sync_capture').fetchone()==(0,)
  assert db.execute('SELECT COUNT(*) FROM personal_sync_changes').fetchone()==(0,)
 report['checks'].append('new/migrated schema25 stays capture-disabled with no implicit backlog')
 activate();collected=run('collect','--stdin',input=wire);assert json.loads(collected.stdout)['imported']==1
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:results=list(executor.map(lambda n:invoke('note','Owned parallel source '+str(n)),[1,2]))
 for result in results:record(result,'parallel-note');assert result.returncode==0,result.stderr
 with sqlite3.connect(library/'memory.sqlite') as db:
  changes=db.execute('SELECT seq,table_name,before_key,after_key,after_row,superseded FROM personal_sync_changes ORDER BY seq').fetchall();assert [r[0] for r in changes]==[1,2,3] and all(r[1]=='memories' and r[2] is None and len(r[3])==32 and r[4] and r[5]==0 for r in changes)
  assert db.execute('SELECT COUNT(*) FROM memories').fetchone()==(4,)
  try:db.execute("INSERT INTO chat_sessions VALUES('unregistered','refuse',1,1)");raise AssertionError('Raw unregistered writer unexpectedly succeeded')
  except sqlite3.OperationalError as e:assert 'oswind_sync_' in str(e)
 report['checks'].append('actual current collector and two concurrent note processes prepare active capture; raw unregistered writer refuses')
 identifier=results[0].stdout.strip();run('delete',identifier,'--json')
 with sqlite3.connect(library/'memory.sqlite') as db:
  assert db.execute('SELECT COUNT(*) FROM memories').fetchone()==(3,)
  live=db.execute('SELECT after_row FROM personal_sync_changes WHERE after_row IS NOT NULL').fetchall();assert len(live)==2 and all(b'Owned parallel source 1' not in r[0] for r in live)
  assert db.execute('SELECT COUNT(*) FROM personal_sync_changes WHERE before_key IS NOT NULL AND after_key IS NULL').fetchone()==(1,)
  assert db.execute('SELECT used_bytes FROM personal_sync_capture').fetchone()[0]==db.execute('SELECT SUM(128+COALESCE(length(before_key),0)+COALESCE(length(after_key),0)+COALESCE(length(after_row),0)) FROM personal_sync_changes').fetchone()[0]
 report['checks'].append('public single-delete purges the queued original body and preserves opaque deletion metadata/accounting')
 archive=base/'owned.oswindbackup';restored=base/'restored';info=json.loads(run('backup','create',archive).stdout);assert info['sourceSchema']==25
 if a.old_cli:run('backup','inspect',archive,cli=a.old_cli.resolve(),ok=False)
 run('backup','restore',archive,'--to',restored)
 with sqlite3.connect(restored/'memory.sqlite') as db:assert db.execute('SELECT enabled FROM personal_sync_capture').fetchone()==(0,) and db.execute('SELECT COUNT(*) FROM personal_sync_changes').fetchone()==(0,) and db.execute('SELECT COUNT(*) FROM memories').fetchone()==(3,)
 report['checks'].append('schema25 backup restores complete current notes without reactivating capture or replaying pending changes; optional old24 inspector refuses')
 report.update(state='completed',scope='Authored fresh notes only, normal local CLI/collector/backup processes. No public pairing, complete typed peer adapters, transport, desktop capture, credentials, normal history, physical power or product ranking acceptance.');save();print(json.dumps(dict(state=report['state'],checks=len(report['checks']),old24=a.old_cli is not None)))
except BaseException as e:report.update(state='failed',errorType=type(e).__name__,error=str(e)[:1500]);save();raise
