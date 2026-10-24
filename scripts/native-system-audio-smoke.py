#!/usr/bin/env python3
"""Opt-in ScreenCaptureKit PCM/isolation probe. Plays soft generated tones only.
Uses existing permission; never requests/grants access or changes system volume.
Raw captured samples stay in memory. Only owned fixture processes are stopped.
"""
import argparse,hashlib,json,math,os,pathlib,plistlib,struct,subprocess,time,uuid,wave
p=argparse.ArgumentParser();p.add_argument('--root',type=pathlib.Path,required=True);p.add_argument('--cli',type=pathlib.Path,required=True);p.add_argument('--sanitize-thread',action='store_true');a=p.parse_args()
project=pathlib.Path(__file__).resolve().parents[1];root=a.root.resolve();root.mkdir(mode=0o700,parents=True,exist_ok=False)
cli=a.cli.resolve();doctor=json.loads(subprocess.check_output([str(cli),'--data',str(root/'doctor-library'),'doctor'],text=True));assert not doctor['screenLocked'] and doctor['screenRecording'],'Requires unlocked Mac and existing capture access'
env=os.environ.copy();env.update(OSWIND_TEST_NATIVE_SYSTEM_AUDIO='1',OSWIND_AUDIO_PROBE_ROOT=str(root));processes=[];sources=[]
try:
 executable=root/'AudioSource';subprocess.run(['swiftc',str(project/'Tests/Fixtures/AudioSourceFixture.swift'),'-o',str(executable)],check=True,capture_output=True)
 for name,frequency in [('A',440),('B',997)]:
  audio=root/(name+'.wav')
  with wave.open(str(audio),'wb') as file:
   file.setnchannels(1);file.setsampwidth(2);file.setframerate(48000);file.writeframes(b''.join(struct.pack('<h',int(0.08*32767*math.sin(2*math.pi*frequency*i/48000))) for i in range(48000)))
  bundle='com.oswind.fixture.audio.'+uuid.uuid4().hex;app=root/(name+'.app');macos=app/'Contents/MacOS';macos.mkdir(parents=True);__import__('shutil').copy2(executable,macos/'AudioSource')
  (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':bundle,'CFBundleExecutable':'AudioSource','CFBundleName':'OSwind Owned Audio '+name,'CFBundlePackageType':'APPL'}));subprocess.run(['codesign','--force','--deep','--sign','-',str(app)],check=True,capture_output=True)
  log=(root/(name+'.log')).open('wb');ready=root/(name+'.ready.json');process=subprocess.Popen(['/usr/bin/open','-n','-g','-W','-a',str(app),'--args',str(audio),str(root/(name+'.play')),str(ready)],stdout=log,stderr=log);log.close();processes.append(process)
  deadline=time.monotonic()+10
  while not ready.exists() and process.poll() is None and time.monotonic()<deadline:time.sleep(0.05)
  assert ready.exists(),'Owned source did not register';identity=json.loads(ready.read_text());assert identity['bundle']==bundle;sources.append((identity['pid'],str(macos/'AudioSource')));env['OSWIND_AUDIO_SOURCE_'+name+'_BUNDLE']=bundle;env['OSWIND_AUDIO_SOURCE_'+name+'_PID']=str(identity['pid'])
 time.sleep(0.5);assert all(p.poll() is None for p in processes),'Owned source failed'
 testArgs=['swift','test']+(['--sanitize=thread'] if a.sanitize_thread else [])+['--filter','NativeSystemAudioTests']
 with (root/'test.log').open('w') as log:r=subprocess.run(testArgs,cwd=project,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=600)
 assert r.returncode==0,'Native probe failed; inspect retained test.log'
 report=json.loads((root/'observations.json').read_text());assert len(report['observations'])==2 and all(o['passed'] for o in report['observations'])
 report.update(threadSanitizer=a.sanitize_thread,sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=project,text=True).strip(),productionIngressSHA256=hashlib.sha256((project/'Sources/OSwindCore/AudioIngress.swift').read_bytes()).hexdigest(),harnessSHA256=hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),os=doctor['os'],gpu=doctor['gpu'],testLogSHA256=hashlib.sha256((root/'test.log').read_bytes()).hexdigest(),testSourceSHA256=hashlib.sha256((project/'Tests/OSwindCoreTests/NativeSystemAudioTests.swift').read_bytes()).hexdigest(),fixtureSourceSHA256=hashlib.sha256((project/'Tests/Fixtures/AudioSourceFixture.swift').read_bytes()).hexdigest(),fixtureLaunch='LaunchServices open -n; actual PID and bundle bound from private atomic readiness file',permissionChanges=False,rawCapturedAudioPersisted=False,systemVolumeChanged=False)
 (root/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
finally:
 for name in ['A','B']:(root/(name+'.play')).unlink(missing_ok=True)
 for pid,path in sources:
  check=subprocess.run(['ps','-p',str(pid),'-o','comm='],capture_output=True,text=True)
  if check.returncode==0 and check.stdout.strip()==path:
   try:os.kill(pid,__import__('signal').SIGTERM)
   except ProcessLookupError:pass
 for process in processes:
  if process.poll() is None:
   process.terminate()
   try:process.wait(timeout=5)
   except subprocess.TimeoutExpired:process.kill();process.wait()
