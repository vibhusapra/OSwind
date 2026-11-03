#!/usr/bin/env python3
"""Explicit opt-in, persistent native capture of one generated fixture.

Requires an independently frozen XCTest bundle/provenance and compiled owned
fixture. Existing permission only. Manual capture cadence; no automatic
foreground/idle/thermal, power, battery or whole-product acceptance claim.
"""
from pathlib import Path
import argparse,datetime,hashlib,json,os,plistlib,shutil,subprocess,time,uuid
p=argparse.ArgumentParser();p.add_argument('--bundle',type=Path,required=True);p.add_argument('--provenance',type=Path,required=True);p.add_argument('--fixture',type=Path,required=True);p.add_argument('--seconds',type=float,required=True);p.add_argument('--interval',type=float,default=20);p.add_argument('--output-parent',type=Path,required=True);a=p.parse_args()
assert 5<=a.seconds<=86400 and 1<=a.interval<=60
parent=a.output_parent.resolve();assert parent.is_dir();nonce=str(uuid.uuid4()).upper();root=parent/('owned-soak-'+nonce);root.mkdir(mode=0o700,exist_ok=False)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
bundle=a.bundle.resolve();assert bundle.name=='OSwindPackageTests.xctest';bundleFiles={str(p.relative_to(bundle)):sha(p) for p in bundle.rglob('*') if p.is_file()};assert 'Contents/MacOS/OSwindPackageTests' in bundleFiles
provenance=a.provenance.resolve();proof=json.loads(provenance.read_text());assert Path(proof['bundle']).resolve()==bundle and proof['files']==bundleFiles
fixtureSource=a.fixture.resolve();assert fixtureSource.is_file();app=root/'Fixture.app';macos=app/'Contents/MacOS';macos.mkdir(parents=True);fixture=macos/'ChangingCaptureFixture';shutil.copy2(fixtureSource,fixture);identifier='com.oswind.fixture.soak.'+nonce.lower()
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':identifier,'CFBundleName':'OSwind Generated Capture Baseline','CFBundleExecutable':'ChangingCaptureFixture','CFBundlePackageType':'APPL','NSHighResolutionCapable':True}))
r=subprocess.run(['codesign','--force','--deep','--sign','-',str(app)],capture_output=True,text=True);assert r.returncode==0,r.stderr
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],capture_output=True,check=True)
def atomic(path,value):
 t=path.with_suffix(path.suffix+'.tmp');t.write_text(json.dumps(value,indent=2)+'\n');os.replace(t,path)
manifest={'format':'OSwind persistent targeted native capture run v1','nonce':nonce,'startedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'requestedSeconds':a.seconds,'intervalSeconds':a.interval,'bundle':str(bundle),'bundleFiles':bundleFiles,'workerProvenanceSHA256':sha(provenance),'workerProvenance':proof,'fixtureBinarySHA256':sha(fixture),'runnerSHA256':sha(Path(__file__)),'fixtureBundle':identifier,'root':str(root),'host':{'macOS':subprocess.check_output(['sw_vers','-productVersion'],text=True).strip(),'chip':subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip()},'scope':'Actual persistent production controller/store requests only one generated native window. Explicit manual-request cadence, not GUI automatic foreground/idle/thermal scheduling. Resource rows are process CPU/RSS, not watts, battery or app energy. Gaps/refusals retained; no keep-awake/permission/settings changes.'};atomic(root/'run-manifest.json',manifest)
fixtureLog=(root/'fixture.log').open('xb');fixtureProcess=subprocess.Popen([str(fixture),str(root/'fixture-ready.json')],stdout=fixtureLog,stderr=subprocess.STDOUT);worker=None
print(json.dumps({'root':str(root),'fixturePID':fixtureProcess.pid,'requestedSeconds':a.seconds}),flush=True)
try:
 deadline=time.monotonic()+20
 while not (root/'fixture-ready.json').exists() and fixtureProcess.poll() is None and time.monotonic()<deadline:time.sleep(.05)
 assert (root/'fixture-ready.json').exists(),'Owned fixture failed readiness';ready=json.loads((root/'fixture-ready.json').read_text());assert ready['pid']==fixtureProcess.pid and ready['bundle']==identifier and ready['executable']==str(fixture) and ready['stableSCObservations']>=3 and ready['windowID']>0
 configuration={'nonce':nonce,'root':str(root),'bundle':identifier,'fixturePID':fixtureProcess.pid,'fixtureExecutable':str(fixture),'seconds':a.seconds,'interval':a.interval};atomic(root/'configuration.json',configuration)
 env={k:v for k,v in os.environ.items() if not k.startswith('OSWIND_TEST_')};env['OSWIND_TEST_TARGETED_SOAK_CONFIGURATION']=str(root/'configuration.json')
 cmd=['xcrun','xctest','-XCTest','OSwindCoreTests.NativeTargetedCaptureSoakTests/testOwnedPersistentTargetedCapture',str(bundle)]
 with (root/'worker.log').open('xb') as log:
  worker=subprocess.Popen(cmd,env=env,stdout=log,stderr=subprocess.STDOUT);start=time.monotonic();wall=time.time();atomic(root/'process-handle.json',{'controllerPID':os.getpid(),'workerLauncherPID':worker.pid,'fixturePID':fixtureProcess.pid,'command':cmd,'startedMonotonic':start,'startedWall':wall,'configurationSHA256':sha(root/'configuration.json')});reported=False
  with (root/'resources.jsonl').open('x') as resources:
   while worker.poll() is None:
    if fixtureProcess.poll() is not None:raise RuntimeError('Owned fixture exited; stopping this run without foreground fallback')
    statusPath=root/'status.json';status=json.loads(statusPath.read_text()) if statusPath.exists() else None
    targetPID=int(status['pid']) if status and isinstance(status.get('pid'),int) else worker.pid
    r=subprocess.run(['ps','-p',str(targetPID)+','+str(fixtureProcess.pid),'-o','pid=,rss=,time=,pcpu=,comm='],capture_output=True,text=True,timeout=5)
    resources.write(json.dumps({'wall':time.time(),'monotonic':time.monotonic(),'processRows':r.stdout.splitlines(),'psExit':r.returncode})+'\n');resources.flush()
    atomic(root/'controller-heartbeat.json',{'state':'running','controllerPID':os.getpid(),'workerLauncherPID':worker.pid,'elapsedWall':time.time()-wall,'elapsedMonotonic':time.monotonic()-start,'status':status})
    if status and status.get('sourceCount',0)>0 and not reported:print(json.dumps({'root':str(root),'state':'first-real-source-admitted','workerPID':status['pid'],'sourceCount':status['sourceCount']}),flush=True);reported=True
    if time.monotonic()-start>max(a.seconds+300,a.seconds*1.2):raise TimeoutError('Controller deadline exceeded; original run will fail, never restart silently')
    time.sleep(2)
  code=worker.returncode
 status=json.loads((root/'status.json').read_text()) if (root/'status.json').exists() else None
 assert all(sha(bundle/p)==h for p,h in bundleFiles.items()) and sha(fixture)==manifest['fixtureBinarySHA256']
 prerequisites=json.loads((root/'prerequisites.json').read_text()) if (root/'prerequisites.json').exists() else None
 final={'state':'completed' if code==0 and status and status.get('coverageQualified') else 'refusedBeforeCapture' if prerequisites and prerequisites.get('ready') is False else 'failed','prerequisites':prerequisites,'libraryCreated':(root/'memory.sqlite').exists(),'workerExit':code,'status':status,'root':str(root),'workerLogSHA256':sha(root/'worker.log'),'attemptsSHA256':sha(root/'attempts.jsonl') if (root/'attempts.jsonl').exists() else None,'resourcesSHA256':sha(root/'resources.jsonl'),'allFrozenBundleFilesUnchanged':True,'scope':manifest['scope']};atomic(root/'controller-final.json',final);print(json.dumps(final),flush=True)
 if final['state']!='completed':raise SystemExit(1)
except BaseException as error:
 if worker and worker.poll() is None:
  # Stop file asks the producer to drain itself. Escalation is owned-child-only.
  (root/'stop-requested').write_text(type(error).__name__+'\n')
  try:worker.wait(timeout=90)
  except subprocess.TimeoutExpired:worker.terminate();worker.wait(timeout=10)
 atomic(root/'controller-error.json',{'type':type(error).__name__,'error':str(error),'workerExit':worker.returncode if worker else None,'scope':'Original run failed; no silent restart or coverage claim'});raise
finally:
 if fixtureProcess.poll() is None:
  fixtureProcess.terminate()
  try:fixtureProcess.wait(timeout=10)
  except subprocess.TimeoutExpired:fixtureProcess.kill();fixtureProcess.wait()
 fixtureLog.close();atomic(root/'fixture-exit.json',{'pid':fixtureProcess.pid,'exit':fixtureProcess.returncode,'ownedSourceReaped':True})
