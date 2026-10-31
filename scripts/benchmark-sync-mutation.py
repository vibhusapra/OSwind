#!/usr/bin/env python3
"""Run fresh authored paired sync metadata measurements, without rebuilding."""
import argparse,datetime,hashlib,importlib.util,json,os,pathlib,shutil,subprocess,tempfile,time
parser=argparse.ArgumentParser(description="Three alternating paired rounds on staged owned sync metadata fixtures.")
parser.add_argument('root',type=pathlib.Path);a=parser.parse_args();repo=pathlib.Path(__file__).resolve().parents[1];os.chdir(repo);base=a.root.absolute()
assert base.resolve()==base and base.is_dir() and not base.is_symlink()
assert (base/'owned-fixture').read_bytes()==b'OSwind authored sync mutation profiles v1' 
p=repo/'scripts/review-sync-mutation-common.py';spec=importlib.util.spec_from_file_location('paired_guard',p);g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g)
profiles={name:g.profile(base/name) for name in ['baseline','candidate']}
a=json.loads((base/'baseline/inputs.json').read_text());b=json.loads((base/'candidate/inputs.json').read_text());assert set(a)==set(b)
diff=[name for name in a if a[name]!=b[name]]
assert set(diff)=={'Sources/OSwindCore/SyncDerivedRetirement.swift','Sources/OSwindCore/PersonalSyncJournal.swift','Sources/OSwindCore/SyncIdentityCatalog.swift','Sources/OSwindCore/MemoryStore.swift'},diff
assert g.sha(base/'baseline/dependencies.json')==g.sha(base/'candidate/dependencies.json')
runs=base/'runs';assert not runs.exists();runs.mkdir(mode=0o700)
frozen={}
for directory in ['Sources','Tests','Vendor','scripts','models','ThirdParty','assets','sdk','.github']:
 for path in (repo/directory).rglob('*'):
  if path.is_file() and '__pycache__' not in path.parts and not path.name.endswith(('.sqlite-wal','.sqlite-shm')):frozen[str(path.relative_to(repo))]=g.sha(path)
for path in [repo/'Package.swift',repo/'Package.resolved']:frozen[str(path.relative_to(repo))]=g.sha(path)
(base/'measurement-inputs.json').write_text(json.dumps(frozen,indent=2)+'\n')
report=dict(state='running',driverPID=os.getpid(),startedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),trials=3,profiles=profiles,onlyCompiledInputDifferences=diff,measurementInputsSHA256=g.sha(base/'measurement-inputs.json'),stages=[],idleSleepInhibited=True,scope='Warm authored metadata component. Three alternating samples per size/profile/workload. No media/model/transport/cold-cache/physical-power/ranking result; caches and background remain uncontrolled.')
def save(): (base/'measurement.json').write_text(json.dumps(report,indent=2)+'\n')
def verify():
 for name,h in frozen.items():assert g.sha(repo/name)==h,name
 for name in profiles:g.profile(base/name)
verify();save();host=pathlib.Path(subprocess.check_output(['xcrun','--find','xctest'],text=True).strip());assert host.is_file();report['host']=dict(path=str(host),sha256=g.sha(host));report['os']=subprocess.check_output(['sw_vers'],text=True);report['swift']=subprocess.check_output(['swift','--version'],text=True);save()
sleep_guard=subprocess.Popen(['/usr/bin/caffeinate','-i','-w',str(os.getpid())])
try:
 for trial in range(3):
  order=['baseline','candidate'] if trial%2==0 else ['candidate','baseline']
  for name in order:
   folder=runs/('trial%d-%s'%(trial,name));folder.mkdir(mode=0o700);shutil.copy2(base/name/'inputs.json',folder/'inputs.json')
   for kind,case,variable,logname in [('projection','testOwnedIncomingRunProjectionAtBoundedScale','OSWIND_TEST_SYNC_RUN_SCALE_OUTPUT','source-projection-regression.log'),('fanout','testOwnedSyncMutationFanoutAtBoundedScale','OSWIND_TEST_SYNC_MUTATION_FANOUT_OUTPUT','fanout.log')]:
    verify();output=folder/kind;env=dict(PATH='/usr/bin:/bin',LANG='en_US.UTF-8',TMPDIR=tempfile.gettempdir()+'/');env[variable]=str(output)
    args=[str(host),'-XCTest','OSwindCoreTests.SyncIncomingSourceTests/'+case,str(base/name/'payload/OSwindPackageTests.xctest')]
    log=folder/logname;start=time.monotonic()
    child=None
    with log.open('wb') as stream:
     child=subprocess.Popen(args,env=env,stdout=stream,stderr=subprocess.STDOUT);report.update(active=dict(trial=trial,profile=name,kind=kind,pid=child.pid));save();print('RUN',trial,name,kind,'pid',child.pid,flush=True)
     try:status=child.wait(timeout=1800)
     except BaseException:
      child.terminate()
      try:child.wait(timeout=10)
      except BaseException:child.kill();child.wait()
      raise
    stage=dict(trial=trial,profile=name,kind=kind,returncode=status,wallSeconds=time.monotonic()-start,logName=logname,logSHA256=g.sha(log));report['stages'].append(stage);save();verify();assert status==0,stage
    receipt=dict(state='completed',returncode=0,profile=name,logName=logname,logSHA256=stage['logSHA256'],sourceInputsSHA256=profiles[name]['sourceInputsSHA256'],executableSHA256=profiles[name]['executableSHA256'],reportSHA256=g.sha(output/'report.json'))
    (output/'run.json').write_text(json.dumps(receipt,indent=2)+'\n')
    reviewer=repo/'scripts'/('review-sync-mutation-projection.py' if kind=='projection' else 'review-sync-mutation-fanout.py');result=subprocess.run(['python3',str(reviewer),str(output),str(base/name)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    (folder/(kind+'-review.json' if result.returncode==0 else kind+'-review.stdout')).write_text(result.stdout);(folder/(kind+'-review.stderr')).write_text(result.stderr);assert result.returncode==0,result.stderr
    stage['reviewSHA256']=g.sha(folder/(kind+'-review.json'));save();print('PASS',trial,name,kind,'wall',round(stage['wallSeconds'],3),flush=True)
 verify();report.update(state='passed',finishedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),allInputAndPayloadHashesUnchanged=True);report.pop('active',None);save();print('ALL PAIRED STAGES PASSED',flush=True)
except BaseException as error:
 report.update(state='failed',error=str(error),finishedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat());save();raise
finally:
 if sleep_guard.poll() is None:sleep_guard.terminate();sleep_guard.wait(timeout=10)
