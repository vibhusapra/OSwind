#!/usr/bin/env python3
"""Owned separate-process media reservation and backup-erasure contracts.

Always creates a fresh fixture root. No real capture, account or existing library
is opened. The sparse backup fixture is 2 GiB of owned zero bytes.
"""
from pathlib import Path
import argparse,base64,contextlib,fcntl,hashlib,json,os,select,signal,sqlite3,subprocess,sys,time,uuid
from owned_sqlite_fixture import register_inactive_sync_fixture
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary')
parser.add_argument('--root',required=True)
parser.add_argument('--output')
parser.add_argument('--expected-sha256')
args=parser.parse_args()
base=Path(args.root).resolve();assert not base.exists(),'Use a fresh owned fixture root'
reportPath=Path(args.output).resolve() if args.output else base/'report.json'
assert not reportPath.exists(),'Do not overwrite an existing report'
cli=Path(args.binary).resolve();assert cli.is_file() and os.access(cli,os.X_OK)
digest=hashlib.sha256(cli.read_bytes()).hexdigest()
if args.expected_sha256:assert digest==args.expected_sha256,'Runner digest differs'
base.mkdir(mode=0o700);(base/'tmp').mkdir(mode=0o700)
env={'PATH':os.environ['PATH'],'HOME':os.environ['HOME'],'LANG':'en_US.UTF-8','TMPDIR':str(base/'tmp')+'/'}
report={'format':'OSwind packaged media admission and backup fence probe','state':'running','version':1,'CLI_SHA256':digest,'checks':[],'limits':['Owned valid PNG plus synthetic sparse media bytes only; no capture/microphone/native input or personal data.','SIGSTOP/SIGCONT target only the newly launched owned backup process after its Copying media progress event; this is controlled process concurrency, not storage-power-loss testing.']}
def save():reportPath.write_text(json.dumps(report,indent=2)+'\n')
def call(root,*args):
 r=subprocess.run([str(cli),'--data',str(root),*map(str,args)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=60)
 assert r.returncode==0,(args,r.returncode,r.stderr[-2000:]);return r.stdout.decode()
@contextlib.contextmanager
def db(root):
 c=sqlite3.connect(root/'memory.sqlite');register_inactive_sync_fixture(c)
 try:
  with c:yield c
 finally:c.close()
def generation(root):
 with db(root) as c:return c.execute("SELECT value FROM store_metadata WHERE key='backup-erasure-generation-v1'").fetchone()[0]
def seed(root,path,data=None,sparse=None):
 id=call(root,'note','Owned packaged admission fixture').strip();uuid.UUID(id)
 target=root/path
 if sparse is not None:
  with target.open('wb') as f:f.truncate(sparse)
 else:target.write_bytes(data)
 with db(root) as c:
  payload=json.loads(c.execute('SELECT payload FROM memories WHERE id=?',(id,)).fetchone()[0]);payload['imagePath']=path;c.execute('UPDATE memories SET payload=? WHERE id=?',(json.dumps(payload).encode(),id))
  count=c.execute("SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'oswind_backup_erasure_%'").fetchone()[0];assert count==8
 return id,target
save()
try:
 root=base/'held-writer';pixels=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aM3sAAAAASUVORK5CYII=');id,file=seed(root,'images/owned.png',data=pixels)
 cache=root/'indexes/owned';cache.parent.mkdir(exist_ok=True);cache.write_bytes(b'owned disposable cache');before=generation(root)
 with (root/'.media-admission.lock').open('a+b') as lock:
  os.chmod(root/'.media-admission.lock',0o600);fcntl.flock(lock,fcntl.LOCK_SH)
  result=json.loads(call(root,'delete',id,'--json'));assert result['sources']==1 and result['removedMedia']==0 and result['pendingMedia']==1 and not result['searchCacheRemoved'] and result['warnings'],result
  assert file.read_bytes()==pixels and cache.read_bytes()==b'owned disposable cache';assert generation(root)!=before
  pending=json.loads(call(root,'erase','retry-media'));assert pending['pendingMedia']==1 and pending['removedMedia']==0 and not pending['searchCacheRemoved'],pending
  fcntl.flock(lock,fcntl.LOCK_UN)
 done=json.loads(call(root,'erase','retry-media'));assert done['pendingMedia']==0 and done['removedMedia'] in [0,1] and done['searchCacheRemoved'] and not done['warnings'];assert not file.exists() and not cache.exists()
 report['checks'].append({'name':'packaged delete/reopen/retry under external shared writer','state':'passed','logicalSources':1,'pendingWhileReserved':1,'fileAndCachePreserved':True,'generationAdvanced':True,'nonblockingRetryReportsPending':True,'explicitRetryRemovedMedia':done['removedMedia'],'cleanupMayRunDuringOpen':True,'afterReleasePending':0});save()
 root=base/'backup-race';id,file=seed(root,'images/owned-sparse',sparse=2*1024**3);destination=base/'must-not-publish.oswindbackup';before=generation(root)
 child=subprocess.Popen([str(cli),'--data',str(root),'backup','create',str(destination)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE);progress=bytearray();paused=False
 try:
  deadline=time.monotonic()+30
  while b'Copying media' not in progress and time.monotonic()<deadline:
   assert child.poll() is None,('Backup finished before controlled copy window',child.returncode,bytes(progress)[-2000:])
   if select.select([child.stderr],[],[],.1)[0]:
    block=os.read(child.stderr.fileno(),65536);assert block,'Backup progress ended before copy';progress.extend(block);assert len(progress)<1024*1024
  assert b'Copying media' in progress,'Missing copy progress gate'
  os.kill(child.pid,signal.SIGSTOP);waited,status=os.waitpid(child.pid,os.WUNTRACED);assert waited==child.pid and os.WIFSTOPPED(status) and os.WSTOPSIG(status)==signal.SIGSTOP;paused=True
  # A direct cross-process lock witness confirms the paused backup holds the
  # reservation whose physical-file protection exposed the publication bug.
  with (root/'.media-admission.lock').open('r+b') as witness:
   try:fcntl.flock(witness,fcntl.LOCK_EX|fcntl.LOCK_NB)
   except BlockingIOError:pass
   else:raise AssertionError('Backup did not hold its expected shared reservation')
  result=json.loads(call(root,'delete',id,'--json'));assert result['sources']==1 and result['pendingMedia']==1 and result['removedMedia']==0,result
  assert file.exists() and generation(root)!=before
  os.kill(child.pid,signal.SIGCONT);paused=False;stdout,stderr=child.communicate(timeout=120);stderr=bytes(progress)+stderr
  (base/'backup.stdout').write_bytes(stdout);(base/'backup.stderr').write_bytes(stderr)
  assert child.returncode!=0 and b'erased during backup' in stderr.lower(),(child.returncode,stderr[-2000:])
  assert not destination.exists(),'Erased source backup was published'
  assert file.exists(),'Backup reservation should defer physical cleanup until explicit retry'
  done=json.loads(call(root,'erase','retry-media'));assert done['pendingMedia']==0 and not file.exists()
  report['checks'].append({'name':'packaged backup cannot publish after concurrent source erasure','state':'passed','copyProgressObserved':True,'SIGSTOPWitness':True,'sharedReservationObserved':True,'erasureCommittedWhileBackupPaused':True,'mediaPreservedUntilRelease':True,'backupRefusedErasedGeneration':True,'destinationAbsent':True,'explicitCleanupFinished':True,'backupStderrSHA256':hashlib.sha256(stderr).hexdigest()});save()
 finally:
  if child.poll() is None:
   if paused:os.kill(child.pid,signal.SIGCONT)
   child.kill();child.wait()
  child.stdout.close();child.stderr.close()
 assert hashlib.sha256(cli.read_bytes()).hexdigest()==digest
 report['state']='passed';save();print(json.dumps(report,indent=2))
except BaseException as e:report.update(state='failed',error=str(e));save();raise
