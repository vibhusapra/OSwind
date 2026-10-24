#!/usr/bin/env python3
"""Owned encrypted-library process checks. Retain private fixtures; never use a normal library."""
import argparse,hashlib,json,os,pathlib,plistlib,secrets,sqlite3,subprocess,wave
p=argparse.ArgumentParser();p.add_argument('binary',type=pathlib.Path);p.add_argument('--root',type=pathlib.Path,required=True);p.add_argument('--old-cli',type=pathlib.Path);a=p.parse_args();binary=a.binary.resolve();base=a.root.resolve();base.mkdir(mode=0o700,exist_ok=False);package=base/'Fixture.oswindvault';alias=package/'Library';secret=secrets.token_urlsafe(32).encode();held=None;migrated=base/'Migrated.oswindvault';report={'state':'running','scope':'Owned native encrypted-library CLI flow. No Keychain, normal library or native user-auth/TCC changes.','checks':[],'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'schema_version':18}
def save():(base/'report.json').write_text(json.dumps(report,indent=2)+'\n')
def run(*args,password=None,ok=True):
 r=subprocess.run([str(binary),*map(str,args)],input=(password+b'\0') if password is not None else b'',capture_output=True,timeout=90)
 assert (r.returncode==0)==ok,(args,r.returncode,r.stderr.decode(errors='replace'));assert secret not in r.stdout and secret not in r.stderr
 return r.stdout.decode()
def mounted(candidate=None):
 v=plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil','info','-plist']));return [i for i in v.get('images',[]) if pathlib.Path(i.get('image-path','/nonexistent')).resolve()==((candidate or package)/'contents.sparsebundle').resolve()]
save()
try:
 created=json.loads(run('vault','create',package,'--name','Owned CLI fixture','--capacity-gb','1','--passphrase-stdin',password=secret));assert created['state']=='locked' and not mounted() and alias.is_file() and not alias.is_symlink();report['checks'].append('create initializes and detaches, public handle closed');save()
 run('--data',alias,'note','Must not create plaintext',ok=False);assert not (package/'memory.sqlite').exists();report['checks'].append('closed handle refuses plaintext fallback')
 run('vault','unlock',package,'--passphrase-stdin',password=b'Wrong-'+secrets.token_hex(16).encode(),ok=False);assert not mounted();report['checks'].append('wrong passphrase refused without attachment')
 opened=json.loads(run('vault','unlock',package,'--passphrase-stdin',password=secret));assert opened['state']=='unlocked' and alias.is_dir() and alias.is_symlink();assert len(mounted())==1
 identifier=run('--vault',package,'note','Owned encrypted memory marker').strip();assert json.loads(run('--vault',package,'get',identifier))['text']=='Owned encrypted memory marker';report['checks'].append('managed handle writes and retrieves on verified volume');save()
 library=alias.resolve()
 if a.old_cli:
  old=a.old_cli.resolve();before=hashlib.sha256((library/'memory.sqlite').read_bytes()).hexdigest();r=subprocess.run([str(old),'--data',str(alias),'note','Old writer must fail'],capture_output=True,text=True,timeout=30);assert r.returncode!=0 and 'newer OSwind' in r.stderr and hashlib.sha256((library/'memory.sqlite').read_bytes()).hexdigest()==before;report['checks'].append('supplied actual older writer refuses schema18 without changing DB bytes');report['old_binary_sha256']=hashlib.sha256(old.read_bytes()).hexdigest()
 else:report['old_writer_check']='not requested; pass --old-cli with a pinned older binary'
 audio=base/'input.wav'
 with wave.open(str(audio),'wb') as file:file.setnchannels(1);file.setsampwidth(2);file.setframerate(16000);file.writeframes(b'\xe8\x03'*32000)
 engine=base/'fixture-asr';engine.write_text('#!/usr/bin/env python3\nimport json,pathlib,sys\np=pathlib.Path(sys.argv[sys.argv.index("-of")+1]);p.with_suffix(".json").write_text(json.dumps({"transcription":[{"offsets":{"from":0,"to":1000},"text":"Owned fixture speech"}]}));print("Owned engine log")\n');engine.chmod(0o700);model=base/'model';model.write_bytes(b'synthetic model')
 (library/'settings.json').write_text(json.dumps({'whisperBinary':str(engine),'whisperModel':str(model),'automaticMaintenance':False,'captureOnLaunch':False,'apiEnabled':False,'routinesEnabled':False}))
 memory=json.loads(run('--vault',package,'import-audio',audio,'--retain-audio'));assert memory['text']=='Owned fixture speech' and memory.get('audioPath');assert not list((library/'audio/.staging').iterdir());run('--vault',package,'transcribe',library/memory['audioPath']);assert not list((library/'audio/.staging').iterdir());report['checks'].append('import and standalone Whisper workspaces remain in managed volume and clean on exit');save()
 backup=base/'explicit-plaintext.oswindbackup';run('--vault',package,'backup','create',backup);assert backup.is_dir();assert not list((library/'audio/.staging').iterdir());run('--vault',package,'export-markdown',base/'explicit-plaintext-markdown');assert not list((library/'audio/.staging').iterdir());report['checks'].append('explicit plaintext backup/Markdown export, private source staging cleaned')
 held=sqlite3.connect(library/'memory.sqlite');held.execute('BEGIN');held.execute('SELECT COUNT(*) FROM memories').fetchone();run('vault','lock',package,ok=False);status=json.loads(run('vault','status',package));assert status['state']=='closing' and mounted() and alias.is_file() and not alias.is_symlink();run('--data',alias,'note','Cannot reopen while busy',ok=False);report['checks'].append('held reader keeps mounted closing state; no forced detach or plaintext reopening');save()
 held.rollback();held.close();held=None;locked=json.loads(run('vault','lock',package));assert locked['state']=='locked' and not mounted();report['checks'].append('retry detaches after reader closes')
 run('vault','unlock',package,'--passphrase-stdin',password=secret);assert json.loads(run('--vault',package,'get',identifier))['text']=='Owned encrypted memory marker';run('vault','lock',package);assert not mounted();source=base/'Original';run('--data',source,'note','Owned migration source');copied=json.loads(run('vault','migrate',source,'--to',migrated,'--capacity-gb','1','--passphrase-stdin',password=secret));assert copied['sourceStable'] and copied['originalRetained'] and copied['status']['state']=='locked' and not mounted(migrated)
 run('vault','unlock',migrated,'--passphrase-stdin',password=secret);assert json.loads(run('--vault',migrated,'stats','--json'))['count']==1;run('vault','lock',migrated);assert not mounted(migrated);assert json.loads(run('--data',source,'stats','--json'))['count']==1;report['checks'].append('verified native migration remounts with history and retains original')
 missing=base/'Missing';bad=base/'MustNotExist.oswindvault';run('vault','migrate',missing,'--to',bad,'--passphrase-stdin',password=secret,ok=False);assert not missing.exists() and not bad.exists();report['checks'].append('missing source refuses before destination creation')
 report.update(state='completed',verified_detached=True,passphrase_persisted=False,normal_library_opened=False);save();print(json.dumps(report,indent=2))
except BaseException as error:report.update(state='failed',failure=str(error));save();raise
finally:
 if held:held.close()
 try:
  for candidate in [package,migrated]:
   if mounted(candidate):run('vault','lock',candidate)
  report['cleanup_detached']=not any(mounted(candidate) for candidate in [package,migrated])
 except BaseException as error:report['cleanup_failure']=str(error)
 save()
