#!/usr/bin/env python3
"""Exercise terminal-generated Ctrl-C on owned encrypted create/unlock/lock.

macOS only. Creates a new explicit fixture root and private controlling terminal.
The random passphrase travels only over a separate stdin pipe. Existing user
terminals, libraries, Keychain and permission settings are never selected.
Packages and raw synthetic output stay under --root for inspection.
"""
import argparse,pathlib,os,pty,termios,fcntl,subprocess,plistlib,json,secrets,signal,time,errno,hashlib,sys,sqlite3
from owned_vault_diagnostics import OwnedVaultDiagnostics
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('binary',type=pathlib.Path);parser.add_argument('--root',type=pathlib.Path,required=True);parser.add_argument('--held-reader',action='store_true',help='Verify Ctrl-C preserves a deliberate busy error, then recover normally');args=parser.parse_args()
if sys.platform!='darwin':parser.error('Requires macOS encrypted APFS disk-image tools')
cli=args.binary.resolve(strict=True);secret=secrets.token_urlsafe(32).encode();diagnostics=OwnedVaultDiagnostics.create(args.root,secret,hashlib.sha256(cli.read_bytes()).hexdigest());base=diagnostics.root;results=[]
def failure_receipt(package,action,code,stdout=b'',stderr=b''):
 try:
  path=diagnostics.save_failure(package,action,code,stdout=stdout,stderr=stderr)
  print('Owned failure receipt: '+path.name,flush=True)
  return json.loads(path.read_text())
 except Exception as error:
  # Never replace the original CLI/terminal failure with diagnostic failure or
  # print arbitrary exception text, paths or credentials from a diagnostic.
  print('Owned diagnostic refused: '+type(error).__name__,flush=True)
  return None
def run(*args,password=None):
 p=subprocess.run([str(cli),*map(str,args)],input=b'' if password is None else password+b'\0',capture_output=True,timeout=180)
 assert secret not in p.stdout+p.stderr,'Fixture credential appeared in output'
 if p.returncode and len(args)>=3 and args[0]=='vault':failure_receipt(pathlib.Path(args[2]),str(args[1]),p.returncode,p.stdout,p.stderr)
 assert p.returncode==0,(p.returncode,p.stderr.decode(errors='replace'))
 return json.loads(p.stdout)
def images(package):
 p=plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil','info','-plist']));target=(package/'contents.sparsebundle').resolve()
 return [v for v in p.get('images',[]) if pathlib.Path(v.get('image-path','/nonexistent')).resolve()==target]
def child_helper(pid,action,package):
 p=subprocess.run(['/usr/bin/pgrep','-P',str(pid),'-x','hdiutil'],capture_output=True,text=True)
 ids=[x for x in p.stdout.split() if x.isdigit()]
 if not ids:return None
 p=subprocess.run(['/bin/ps','-p',','.join(ids),'-o','pid=,ppid=,pgid=,args='],capture_output=True,text=True)
 for line in p.stdout.splitlines():
  fields=line.strip().split(None,3)
  if len(fields)==4 and fields[1]==str(pid) and fields[3].startswith('/usr/bin/hdiutil '+action+' ') and str(package/'contents.sparsebundle') in fields[3]:return dict(pid=int(fields[0]),group=int(fields[2]))
 return None
def interrupt(action,package,expectBusy=False):
 command=['vault',action,str(package),'--passphrase-stdin'] if action!='lock' else ['vault','lock',str(package)]
 if action=='create':command+=['--capacity-gb','1']
 master,slave=pty.openpty();attributes=termios.tcgetattr(slave);attributes[3]=(attributes[3]|termios.ISIG)&~(termios.ECHO|termios.TOSTOP);attributes[6][termios.VINTR]=b'\x03';termios.tcsetattr(slave,termios.TCSANOW,attributes)
 readSecret,writeSecret=os.pipe();pid=os.fork()
 if pid==0:
  try:
   os.close(master);os.close(writeSecret);os.setsid();fcntl.ioctl(slave,termios.TIOCSCTTY,0);os.tcsetpgrp(slave,os.getpid())
   os.dup2(readSecret,0);os.dup2(slave,1);os.dup2(slave,2)
   if readSecret>2:os.close(readSecret)
   if slave>2:os.close(slave)
   os.execv(str(cli),[str(cli),*command])
  finally:os._exit(127)
 os.close(slave);os.close(readSecret)
 if action!='lock':os.write(writeSecret,secret+b'\0')
 os.close(writeSecret);os.set_blocking(master,False);output=bytearray();status=None;observed=None;signalled=False;start=time.monotonic();deadline=start+180
 def drain():
  while True:
   try:
    data=os.read(master,65536)
    if not data:break
    output.extend(data)
    assert len(output)<=1024*1024,'Owned PTY output exceeded bound'
   except OSError as e:
    if e.errno in [errno.EAGAIN,errno.EIO]:break
    raise
 try:
  while time.monotonic()<deadline:
   drain();done,code=os.waitpid(pid,os.WNOHANG)
   if done:status=code;break
   if not signalled:
    if action=='lock':
     try:closing=json.loads((package/'session.json').read_text()).get('phase')=='closing'
     except (FileNotFoundError,json.JSONDecodeError):closing=False
     if closing:observed=dict(boundary='persisted closing phase')
    else:
     child=child_helper(pid,'attach' if action=='unlock' else 'create',package)
     if child:observed=dict(boundary='owned native helper',helperPID=child['pid'],helperGroup=child['group'])
    if observed:
     observed['foregroundGroup']=os.tcgetpgrp(master);observed['CLIGroup']=os.getpgid(pid);assert observed['foregroundGroup']==observed['CLIGroup']==pid
     os.write(master,b'\x03');signalled=True
   time.sleep(.002)
  assert status is not None,'Owned controlling-PTY operation exceeded native observation budget'
  drain();assert secret not in output,'Fixture credential appeared in terminal output'
  code=os.waitstatus_to_exitcode(status);outputFile=base/(action+'.pty-output');outputFile.write_bytes(output)
  record=dict(action=action,exitCode=code,wallSeconds=time.monotonic()-start,terminalCtrlC=signalled,observed=observed,outputSHA256=hashlib.sha256(output).hexdigest(),ownedImageAttachedAfterExit=bool(images(package)))
  results.append(record);save()
  if code != 130:failure_receipt(package,action,code,bytes(output))
  assert signalled and code==(1 if expectBusy else 130),(action,record)
  assert b'Stopping vault work safely' in output,record
  if expectBusy:
   assert record['ownedImageAttachedAfterExit'] and b'files are in use' in output,record
   assert b'Vault operation cancelled.' not in output,record
  else:assert not record['ownedImageAttachedAfterExit'],record
  # Raw process and PTY details are preserved in the owned fixture report.
 finally:
  if status is None:
   # Only this private session; preserve packages and allow product recovery.
   try:os.kill(pid,signal.SIGINT)
   except ProcessLookupError:pass
   _,status=os.waitpid(pid,0)
  os.close(master)
def save():
 (base/'report.json').write_text(json.dumps(dict(format='OSwind private controlling-PTY cooperative cancellation v1',binarySHA256=hashlib.sha256(cli.read_bytes()).hexdigest(),trials=results,scope='Actual VINTR Ctrl-C from a new private controlling PTY. Secret uses a separate closed pipe because CLI refuses interactive password stdin. Owned synthetic encrypted packages only; no user terminal, credentials, Keychain, TCC, forced detach or power changes.'),indent=2)+'\n')
if args.held_reader:
 package=base/'Busy.oswindvault';held=None;identifier=None
 try:
  run('vault','create',package,'--capacity-gb','1','--passphrase-stdin',password=secret)
  run('vault','unlock',package,'--passphrase-stdin',password=secret)
  identifier=subprocess.run([str(cli),'--data',str(package/'Library'),'note','Owned cancellation must preserve busy failure'],capture_output=True,text=True,check=True).stdout.strip()
  held=sqlite3.connect(package/'Library'/'memory.sqlite');held.execute('BEGIN');held.execute('SELECT COUNT(*) FROM memories').fetchone()
  interrupt('lock',package,expectBusy=True)
  receipts=[json.loads(p.read_text()) for p in base.glob('failure-*.json')]
  assert any(any(r['pid']==os.getpid() and r['path'].endswith('/Library/memory.sqlite') for r in d.get('observation',{}).get('readers',[])) for d in receipts),'Owned known reader was not observed after failed detach'
  assert run('vault','status',package)['state']=='closing' and images(package)
  assert (package/'Library').is_file() and not (package/'Library').is_symlink()
 finally:
  if held is not None:held.rollback();held.close()
  # Only normal product recovery, even if the error-visibility assertion fails.
  # Preserve all packages and keep the original failed trial in its report.
  run('vault','lock',package);assert not images(package)
  if identifier is not None:
   run('vault','unlock',package,'--passphrase-stdin',password=secret)
   assert run('--data',package/'Library','get',identifier)['text']=='Owned cancellation must preserve busy failure'
   run('vault','lock',package);assert not images(package)
  if (base/'report.json').exists():
   report=json.loads((base/'report.json').read_text());report.update(normalRecoveryDetached=True,recoveredHistoryPreserved=identifier is not None);(base/'report.json').write_text(json.dumps(report,indent=2)+'\n')
 report=json.loads((base/'report.json').read_text());report.update(state='completed',busyFailurePreserved=True);(base/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2));raise SystemExit(0)
created=base/'Create.oswindvault';interrupt('create',created);run('vault','unlock',created,'--passphrase-stdin',password=secret);run('vault','lock',created);assert not images(created)
opened=base/'Unlock.oswindvault';run('vault','create',opened,'--capacity-gb','1','--passphrase-stdin',password=secret)
run('vault','unlock',opened,'--passphrase-stdin',password=secret);identifier=subprocess.run([str(cli),'--data',str(opened/'Library'),'note','Owned PTY history survives cooperative interruption'],capture_output=True,text=True,check=True).stdout.strip();run('vault','lock',opened)
interrupt('unlock',opened);run('vault','unlock',opened,'--passphrase-stdin',password=secret);source=run('--data',opened/'Library','get',identifier);assert source['text']=='Owned PTY history survives cooperative interruption'
interrupt('lock',opened);assert run('vault','status',opened)['state']=='locked';run('vault','unlock',opened,'--passphrase-stdin',password=secret);assert run('--data',opened/'Library','get',identifier)['text']==source['text'];run('vault','lock',opened);assert not images(opened)
report=json.loads((base/'report.json').read_text());report.update(state='completed',immediateRecoveryPassed=True,sourceHistoryPreserved=True,noOwnedImagesAfterFinalLock=True,passphrasePersisted=False);(base/'report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
