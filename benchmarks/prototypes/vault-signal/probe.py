#!/usr/bin/env python3
from pathlib import Path
import os,pty,termios,fcntl,subprocess,json,time,signal,errno,hashlib,argparse,sys
parser=argparse.ArgumentParser(description='Read-only Foundation launch/terminal signal diagnostic; not a native vault reproduction or performance benchmark.');parser.add_argument('--binary',type=Path,required=True);parser.add_argument('--root',type=Path,required=True);args=parser.parse_args()
if sys.platform!='darwin':parser.error('Requires macOS')
binary=args.binary.resolve(strict=True);out=args.root.resolve();out.mkdir(mode=0o700,parents=True,exist_ok=False);plans=[dict(mode=mode,delaySeconds=delay,repeat=i) for mode in ['info','control'] for delay in [None,0,.0005,.002,.005] for i in range(3)];(out/'plan.json').write_text(json.dumps(dict(plans=plans,binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),scope='Read-only hdiutil info and synthetic Python control. One private controlling PTY per probe; no vault mutations, user terminal, keys or settings. Native inventory stdout only count/hash, never retained.'),indent=2)+'\n');results=[]
for index,plan in enumerate(plans):
 assert hashlib.sha256(binary.read_bytes()).hexdigest()==json.loads((out/'plan.json').read_text())['binarySHA256']
 master,slave=pty.openpty();attrs=termios.tcgetattr(slave);attrs[3]=(attrs[3]|termios.ISIG)&~(termios.ECHO|termios.TOSTOP);attrs[6][termios.VINTR]=b'\x03';termios.tcsetattr(slave,termios.TCSANOW,attrs)
 readfd,writefd=os.pipe();pid=os.fork();stem=out/f'trial-{index:02d}'
 if pid==0:
  try:
   os.close(master);os.close(writefd);os.setsid();fcntl.ioctl(slave,termios.TIOCSCTTY,0);os.tcsetpgrp(slave,os.getpid());os.dup2(readfd,0);os.dup2(slave,1);os.dup2(slave,2)
   if readfd>2:os.close(readfd)
   if slave>2:os.close(slave)
   os.execv(str(binary),[str(binary),plan['mode'],str(stem)])
  finally:os._exit(127)
 os.close(slave);os.close(readfd);os.close(writefd);os.set_blocking(master,False);data=bytearray();status=None;target=None;sent=False;start=time.monotonic();deadline=start+10
 try:
  while time.monotonic()<deadline:
   while True:
    try:
     chunk=os.read(master,65536)
     if not chunk:break
     data.extend(chunk);assert len(data)<65536
    except OSError as e:
     if e.errno in [errno.EIO,errno.EAGAIN]:break
     raise
   if target is None and b'"beforeLaunch"' in data and plan['delaySeconds'] is not None:target=time.monotonic()+plan['delaySeconds']
   if not sent and target is not None and time.monotonic()>=target:
    assert os.tcgetpgrp(master)==os.getpgid(pid)==pid;os.write(master,b'\x03');sent=True
   done,code=os.waitpid(pid,os.WNOHANG)
   if done:status=code;break
   time.sleep(.0001)
  assert status is not None,'Owned read-only probe timeout'
  while True:
   try:
    chunk=os.read(master,65536)
    if not chunk:break
    data.extend(chunk)
   except OSError as e:
    if e.errno in [errno.EIO,errno.EAGAIN]:break
    raise
  stem.with_suffix('.pty-output').write_bytes(data);lines=[]
  text=data.decode(errors='replace');cursor=0;decoder=json.JSONDecoder()
  while cursor<len(text):
   cursor=text.find('{',cursor)
   if cursor<0:break
   value,end=decoder.raw_decode(text,cursor);lines.append(value);cursor=end
  first=next(x for x in lines if x['phase']=='beforeLaunch');last=next(x for x in lines if x['phase']=='completed');assert first['parentPID']==first['parentGroup']==first['parentSession']==pid
  assert os.waitstatus_to_exitcode(status)==0,'Probe process did not complete'
  row=dict(index=index,parentPID=pid,plan=plan,terminalCtrlC=sent,probeExit=os.waitstatus_to_exitcode(status),seconds=time.monotonic()-start,result=last);results.append(row);(out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
  if last['status']!=0:print(json.dumps(row),flush=True)
 finally:
  if status is None:
   children=subprocess.run(['/usr/bin/pgrep','-P',str(pid)],capture_output=True,text=True).stdout.split()
   for child in children:
    try:os.kill(int(child),signal.SIGTERM)
    except ProcessLookupError:pass
   try:os.kill(pid,signal.SIGTERM)
   except ProcessLookupError:pass
   os.waitpid(pid,0)
  os.close(master)
summary=dict(trials=len(results),unsuccessful=sum(x['result']['status']!=0 for x in results),sameChildGroup=sum(x['result']['childGroup']==x['parentPID'] for x in results),scope='Component analogue only; native termination classes and all outcomes retained, no failure probability or historical cause claim')
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary),flush=True)
