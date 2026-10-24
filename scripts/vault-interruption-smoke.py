#!/usr/bin/env python3
"""Observe and interrupt only this script's own hdiutil helpers; no Keychain or user library."""
import argparse,hashlib,json,pathlib,plistlib,secrets,signal,subprocess,time
p=argparse.ArgumentParser();p.add_argument('binary',type=pathlib.Path);p.add_argument('--root',type=pathlib.Path,required=True);a=p.parse_args();binary=a.binary.resolve();root=a.root.resolve();root.mkdir(mode=0o700,exist_ok=False);secret=secrets.token_urlsafe(32).encode();checks=[]
def images(package):
 data=plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil','info','-plist']));return [x for x in data.get('images',[]) if pathlib.Path(x.get('image-path','/nonexistent')).resolve()==(package/'contents.sparsebundle').resolve()]
def run(*args,password=None):
 r=subprocess.run([str(binary),*map(str,args)],input=password+b'\0' if password is not None else b'',capture_output=True,timeout=90);assert r.returncode==0,(r.returncode,r.stderr);return json.loads(r.stdout)
def interrupt(command,package):
 process=subprocess.Popen([str(binary),*map(str,command)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 process.stdin.write(secret+b'\0');process.stdin.close();process.stdin=None
 deadline=time.monotonic()+30;observed=False;helper='attach' if command[1]=='unlock' else 'create'
 while time.monotonic()<deadline and process.poll() is None:
  rows=subprocess.check_output(['ps','-axo','pid,ppid,args'],text=True).splitlines()[1:]
  if any(len(x:=line.strip().split(None,2))==3 and x[1]==str(process.pid) and x[2].startswith('/usr/bin/hdiutil '+helper+' ') for line in rows):observed=True;process.send_signal(signal.SIGINT);break
  time.sleep(.01)
 try:
  stdout,stderr=process.communicate(timeout=30);assert observed,(command,'No active owned helper observed');assert process.returncode==130,(command,process.returncode,stderr);assert not stdout and secret not in stderr
  attached=images(package);checks.append({'action':command[1],'exit_code':process.returncode,'owned_helper_observed_before_interrupt':observed,'helper_action':helper,'still_attached':bool(attached),'stdout_empty':True})
  assert not attached,('Cancelled operation left owned attachment',attached)
 finally:
  if process.poll() is None:process.kill();process.wait()
created=root/'Create.oswindvault';interrupt(['vault','create',created,'--capacity-gb','1','--passphrase-stdin'],created)
opened=root/'Unlock.oswindvault';run('vault','create',opened,'--capacity-gb','1','--passphrase-stdin',password=secret);interrupt(['vault','unlock',opened,'--passphrase-stdin'],opened)
status=run('vault','status',opened);assert status['state']=='locked';run('vault','unlock',opened,'--passphrase-stdin',password=secret);run('vault','lock',opened);assert not images(opened)
report={'state':'completed','binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'scope':'Actual SIGINT during observed owned hdiutil create/attach helpers; random in-memory passphrase, no Keychain or normal library','checks':checks,'recovery_unlock_and_lock_passed':True,'passphrase_persisted':False};(root/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
