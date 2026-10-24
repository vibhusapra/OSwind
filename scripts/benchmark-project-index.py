#!/usr/bin/env python3
"""Paired owned project extraction and quiet-restore scaling observations.

Short identical authored bodies, fixed IDs/timestamps, sequential fresh CLI calls.
No cold-cache control, natural NLP gold, capture, energy or competitor claim.
"""
import argparse,contextlib,hashlib,json,pathlib,resource,sqlite3,subprocess,time
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary',type=pathlib.Path);p.add_argument('--baseline-cli',required=True,type=pathlib.Path);p.add_argument('--root',required=True,type=pathlib.Path);p.add_argument('--sizes',default='1000,5000,20000');p.add_argument('--repetitions',type=int,default=3);p.add_argument('--timeout',type=float,default=300);a=p.parse_args()
sizes=[int(s) for s in a.sizes.split(',')];assert sizes and all(1<=n<=1000000 for n in sizes) and 1<=a.repetitions<=10 and 1<=a.timeout<=1800
root=a.root.resolve();root.mkdir(mode=0o700,parents=True,exist_ok=False);results=[]
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
def measure(cli,library,args,timeout=180):
 before=resource.getrusage(resource.RUSAGE_CHILDREN);start=time.monotonic();timedOut=False
 try:r=subprocess.run([str(cli),'--data',str(library),*map(str,args)],capture_output=True,text=True,timeout=timeout);code=r.returncode;output=r.stdout;error=r.stderr
 except subprocess.TimeoutExpired:timedOut=True;code=None;output='';error='Owned child exceeded timeout and was killed/reaped by subprocess.run'
 elapsed=time.monotonic()-start;after=resource.getrusage(resource.RUSAGE_CHILDREN)
 return dict(wallSeconds=elapsed,userCPUSeconds=after.ru_utime-before.ru_utime,systemCPUSeconds=after.ru_stime-before.ru_stime,exitCode=code,timedOut=timedOut),output,error
def invoke(cli,library,*args):
 r,out,error=measure(cli,library,args);assert r['exitCode']==0,error;return json.loads(out)
def verify(library,project,n):
 with contextlib.closing(sqlite3.connect(library/'memory.sqlite')) as db:
  assert db.execute('SELECT COUNT(*) FROM memories').fetchone()[0]==n
  assert db.execute("SELECT COUNT(*) FROM entity_mentions WHERE entity_id=? AND origin='automatic'",(project,)).fetchone()[0]==n
  assert db.execute("SELECT COUNT(*) FROM entity_mentions WHERE entity_id=? AND (start<>0 OR length<>13 OR surface<>'Apollo Launch')",(project,)).fetchone()[0]==0
  return hashlib.sha256(json.dumps(list(db.execute("SELECT memory_id,origin,revision,start,length,surface,method FROM entity_mentions WHERE entity_id=? ORDER BY memory_id",(project,))),separators=(',',':')).encode()).hexdigest()
for n in sizes:
 values=[dict(id=f'owned-{i:08d}',timestamp='2026-10-24T12:00:00Z',kind='note',app='Owned project index fixture',bundleID='org.oswind.project-index',title=f'Authored source {i}',text='Apollo Launch has an authored index fixture.',tags=[],favorite=False,regions=[]) for i in range(n)]
 inputFile=root/f'input-{n}.json';inputFile.write_text(json.dumps(values));inputSHA=sha(inputFile);del values
 for repetition in range(a.repetitions):
  for label,cli in [('baseline',a.baseline_cli.resolve()),('candidate',a.binary.resolve())]:
   folder=root/f'{n}-{repetition}-{label}';folder.mkdir(mode=0o700);library=folder/'library'
   assert invoke(cli,library,'import',inputFile,'--json')['imported']==n
   project=invoke(cli,library,'entity','create','project','Apollo Launch')['id']
   trial=dict(label=label,sources=n,repetition=repetition,binarySHA256=sha(cli),syntheticInputSHA256=inputSHA)
   index,out,error=measure(cli,library,['entity','index'],a.timeout);trial['firstIndex']=index
   (folder/'index.stderr').write_text(error);trial['indexStderrSHA256']=sha(folder/'index.stderr')
   if index['exitCode']==0:
    progress=json.loads(out);assert progress==dict(eligible=n,indexed=n,limited=0);anchors=verify(library,project,n)
    resume,out,error=measure(cli,library,['entity','index'],a.timeout);trial['resume']=resume;assert resume['exitCode']==0,error;assert json.loads(out)==progress
    archive=folder/'archive.oswindbackup';invoke(cli,library,'backup','create',archive);restored=folder/'restored'
    restore,out,error=measure(cli,library,['backup','restore',archive,'--to',restored],a.timeout);trial['restore']=restore
    (folder/'restore.stderr').write_text(error);trial['restoreStderrSHA256']=sha(folder/'restore.stderr')
    if restore['exitCode']==0:
     assert verify(restored,project,n)==anchors
     assert invoke(cli,restored,'entity','progress')['indexed']==0 and not json.loads((restored/'settings.json').read_text())['entityAutomaticIndex']
    else:assert label=='baseline' and restore['timedOut'],error
    trial['automaticAnchorsSHA256']=anchors
    if label=='candidate':
     baseline=next(v for v in results if v['label']=='baseline' and v['sources']==n and v['repetition']==repetition)
     if 'automaticAnchorsSHA256' in baseline:assert anchors==baseline['automaticAnchorsSHA256']
   elif label=='candidate':raise AssertionError('Candidate index failed: '+error)
   else:assert index['timedOut'],error
   results.append(trial)
   report=dict(format='OSwind paired project-index/restore observations v1',baselineBinarySHA256=sha(a.baseline_cli.resolve()),candidateBinarySHA256=sha(a.binary.resolve()),harnessSHA256=sha(pathlib.Path(__file__)),sizes=sizes,repetitions=a.repetitions,timeoutSeconds=a.timeout,results=results,scope='Owned repeated short text with exact authored project membership/span oracle; fresh CLI calls include startup, SQLite and native NLP for indexing, plus separate quiet restore and no-op resume. Sequential baseline then candidate trials, caches and host activity uncontrolled. CPU is child user/system delta; shared daemons and system energy excluded. Timeouts are retained censored baseline observations, not successful completions. No natural NLP accuracy, capture, physical power or competitor ranking.')
   (root/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(dict(label=label,sources=n,repetition=repetition,indexWall=index['wallSeconds'],indexTimedOut=index['timedOut'],restoreWall=trial.get('restore',{}).get('wallSeconds'))),flush=True)
