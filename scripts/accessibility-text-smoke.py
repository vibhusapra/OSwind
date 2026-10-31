#!/usr/bin/env python3
"""Owned text-mode protocol, scope, legacy-client and portability contracts.

An absent app is deliberate: this never captures a real desktop. Positive text
admission uses a separately labeled authored interchange fixture, not native AX.
"""
import argparse,hashlib,json,pathlib,subprocess,uuid
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary',type=pathlib.Path);p.add_argument('--root',required=True,type=pathlib.Path);p.add_argument('--old-cli',type=pathlib.Path);a=p.parse_args()
binary=a.binary.resolve();base=a.root.resolve();base.mkdir(mode=0o700,exist_ok=False);library=base/'library';sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
report=dict(format='OSwind standalone AX text process contracts',version=1,state='running',cliSHA256=sha(binary),harnessSHA256=sha(pathlib.Path(__file__)),checks=[],operations=[])
def save():(base/'report.json').write_text(json.dumps(report,indent=2)+'\n')
def run(*args,data=library,cli=binary,ok=True):
 r=subprocess.run([str(cli),'--data',str(data),*map(str,args)],capture_output=True,text=True,timeout=90)
 report['operations'].append(dict(command=str(args[0]),returncode=r.returncode,stdoutSHA256=hashlib.sha256(r.stdout.encode()).hexdigest(),stderrSHA256=hashlib.sha256(r.stderr.encode()).hexdigest()));save()
 assert (r.returncode==0)==ok,(args,r.stdout,r.stderr)
 return r
def value(*args,**kwargs):return json.loads(run(*args,**kwargs).stdout)
def config(**changes):
 d=dict(visualCaptureMode='accessibility',captureOnLaunch=False,apiEnabled=False,automaticMaintenance=False,audioEnabled=False,systemAudioEnabled=False,allDisplays=False);d.update(changes)
 f=library/'settings.json';f.write_text(json.dumps(d));f.chmod(0o600)
def count():return value('stats','--json')['count']
def media_empty(root):
 return all(not any(p.is_symlink() or not p.is_dir() for p in (root/d).rglob('*')) for d in ['images','audio','video'])
try:
 seed=run('note','Owned text-mode protocol seed').stdout.strip();config()
 doctor=value('doctor');assert doctor['desktopCaptureMode']=='accessibility' and doctor['screenRecordingRequiredForDesktop'] is False and doctor['desktopPermissionReady']==doctor['accessibility']
 report['doctor']={k:doctor[k] for k in ['desktopCaptureMode','screenRecordingRequiredForDesktop','desktopPermissionReady','accessibility','screenRecording','screenLocked']}
 target='org.oswind.absent-text-'+uuid.uuid4().hex
 refusal=run('capture-text','--app-bundle',target,ok=False)
 if doctor['screenLocked']:
  assert 'Locked' in refusal.stderr;report['nativeRefusalBoundary']='Locked-session gate before target lookup'
 elif not doctor['accessibility']:
  assert 'Accessibility permission required' in refusal.stderr;report['nativeRefusalBoundary']='Accessibility permission gate before target lookup'
 else:
  assert 'Application context unavailable' in refusal.stderr;report['nativeRefusalBoundary']='Explicit absent target; no other app selected'
 assert count()==1 and media_empty(library);report['checks'].append('mode-specific permission report and zero-source native refusal at the observed boundary')
 replay=run('capture-replay','--seconds','1','--app-bundle',target,ok=False);assert 'Text-only mode cannot capture replay' in replay.stderr;assert count()==1
 report['checks'].append('explicit replay cannot widen a saved text-only mode to pixels')
 for change,phrase in [(dict(allDisplays=True),'focused-window'),(dict(snapshotRegions=dict(focusedWindowCrop=dict(x=.5,y=0,width=.5,height=1))),'crop')]:
  config(**change);r=run('capture-text','--app-bundle',target,ok=False);assert phrase in r.stderr and count()==1
 report['checks'].append('saved display and crop constraints refuse before context/device admission')
 config(visualCaptureMode='snapshots');r=run('capture-text','--app-bundle',target,ok=False);assert 'Select and save Text only' in r.stderr
 config(visualCaptureMode='future-unknown-mode');r=run('capture-text','--app-bundle',target,ok=False);assert 'Select and save Text only' in r.stderr
 assert 'Invalid capture area' in run('capture','--app-bundle',target).stdout
 report['checks'].append('wrong or unknown modes cannot fall through to text or pixel capture')
 config();source=value('get',seed);source.update(id='owned-accessibility-interchange',kind='screen',app='Owned fixture',bundleID='org.oswind.owned',title='Owned accessible source',text='Owned accessible archive marker',display='accessibility-window',regions=[])
 f=base/'authored-interchange.json';f.write_text(json.dumps([source]));assert value('import',f,'--json')['imported']==1
 memory=value('get',source['id']);assert memory['text']==source['text'] and memory['display']=='accessibility-window' and not memory['regions']
 assert all(memory.get(k) is None for k in ['imagePath','videoPath','audioPath','visualRecording','transcript'])
 assert value('privacy-status',source['id'])['state']=='notRecorded'
 report['checks'].append('separate authored interchange source retains text-only shape and cannot imply a learned PII check')
 archive=base/'text.oswindbackup';assert value('backup','create',archive)['sourceSchema']==25
 restored=base/'restored';run('backup','restore',archive,'--to',restored)
 quiet=json.loads((restored/'settings.json').read_text());assert quiet['visualCaptureMode']=='accessibility' and not quiet['captureOnLaunch'] and not quiet['apiEnabled']
 assert value('get',source['id'],data=restored)['text']==source['text'] and media_empty(restored)
 report['checks'].append('quiet full backup preserves text mode and source; no startup services or media introduced')
 if a.old_cli:
  old=a.old_cli.resolve();report['olderCLI_SHA256']=sha(old);before=sha(library/'settings.json')
  refusal=run('stats','--json',cli=old,ok=False);assert 'newer OSwind version' in refusal.stderr
  assert sha(library/'settings.json')==before
  run('backup','inspect',archive,cli=old,ok=False)
  report['checks'].append('preceding signed23 client refuses schema25 library and backup without modifying saved settings')
 exported=base/'text.json';run('export',exported);again=base/'json-copy';assert value('import',exported,'--json',data=again)['imported']==2
 assert value('get',source['id'],data=again)['display']=='accessibility-window' and media_empty(again)
 run('delete',source['id']);assert count()==1 and media_empty(library)
 report['checks'].append('plain JSON portability and independent source deletion preserve media-free source semantics')
 report.update(state='completed',actualNativeTextCaptureClaimed=False,interchangeFixtureIsNativeCapture=False,mediaFiles=0,emptyMediaDirectoryScaffoldingAllowed=True,scope='Owned CLI/settings/refusal/portability checks with one absent UUID target and two authored sources. Capture succeeds only in the separate controlled core tests; this process probe does not establish live signed-GUI/TCC, native app AX coverage, physical energy or competitor ranking.')
 save();print(json.dumps(report,indent=2))
except BaseException as error:report.update(state='failed',failure=str(error));save();raise
