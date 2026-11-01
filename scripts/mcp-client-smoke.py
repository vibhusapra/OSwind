#!/usr/bin/env python3
"""Manual client process contracts against OSwind's independently implemented MCP server.
Only authored temporary libraries/configs. No external credentials or servers.
"""
import argparse,base64,json,os,pathlib,signal,subprocess,tempfile,time,hashlib
p=argparse.ArgumentParser();p.add_argument('binary');p.add_argument('--output');a=p.parse_args();binary=str(pathlib.Path(a.binary).resolve());checks=[]
def require(value,label):
 if not value:raise AssertionError(label)
 checks.append(label)
with tempfile.TemporaryDirectory(prefix='oswind-mcp-process-') as scratch:
 root=pathlib.Path(scratch);quiet=root/'must-not-open';server=root/'authored-server';env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(root/'home'),'TMPDIR':str(root),'LANG':'en_US.UTF-8','OSWIND_DATA_DIR':str(quiet),'OSWIND_TEST_PARENT_SECRET':'owned-unrelated-probe'}
 def run(args,ok=True,timeout=45):
  r=subprocess.run([binary,*args],env=env,input=b'',stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
  require((r.returncode==0)==ok,'exit '+str(len(checks))+': '+args[0]+'; '+r.stderr[-1500:].decode('utf-8','replace'));return json.loads(r.stdout) if ok else r
 config=root/'command.json';config.write_text(json.dumps({'executable':binary,'arguments':['--data',str(server),'mcp'],'credentialNames':[]}));os.chmod(config,0o600)
 base=['mcp-client','list','--config',str(config)]
 run(base,False);require(not server.exists(),'discovery requires explicit local-code authorization')
 run(['--data',str(root/'rejected-data'),*base,'--allow-server-process'],False);run(['--vault',str(root/'rejected-vault'),*base,'--allow-server-process'],False)
 require(not quiet.exists() and not (root/'rejected-data').exists() and not (root/'rejected-vault').exists(),'client refuses data/vault before library access')
 review=run([*base,'--allow-server-process']);require(review['protocolVersion']=='2025-11-25','legacy negotiation with existing server');require(len(review['tools'])==7 and 'memory_stats'in [t['name']for t in review['tools']],'all seven independently implemented server tools discovered')
 require(all(isinstance(t['definitionJSON'],str) and json.loads(t['definitionJSON'])['name']==t['name']for t in review['tools']),'review definitions are literal readable JSON tied to each tool')
 reviewfile=root/'review.json';reviewfile.write_text(json.dumps(review));argsfile=root/'arguments.json';argsfile.write_text('{}')
 call=['mcp-client','call','--config',str(config),'--review',str(reviewfile),'--tool','memory_stats','--arguments',str(argsfile),'--allow-server-process']
 run(call,False)
 result=run([*call,'--confirm-call']);wire=json.loads(base64.b64decode(result['resultJSON']));text=wire['content'][0]['text'];stats=json.loads(text)
 require(not result['isError'] and stats['count']==0,'reviewed tool call reads actual authored empty library');require(len(result['commandFingerprint'])==64 and result['toolFingerprint']==next(t['fingerprint']for t in review['tools']if t['name']=='memory_stats'),'result carries command/tool provenance');require(result['text']==text,'complete original tool text preserved')
 argsfile.write_text('{"x":1,"x":2}');run([*call,'--confirm-call'],False);argsfile.write_text('{}')
 forged=dict(review);forged['tools']=[dict(t,description='forged display')for t in review['tools']];reviewfile.write_text(json.dumps(forged));run([*call,'--confirm-call'],False)
 require(not quiet.exists(),'manual list/call never open ambient/default client history')
 require(b'owned-unrelated-probe' not in json.dumps(result).encode(),'unrelated parent secret absent from returned tool context')
 # The interrupt path is exercised through the real CLI signal handler,
 # separately from the Core Task-cancellation fixture.
 script=root/'blocking-server.py';marker=root/'blocking.pid'
 script.write_text("""import sys,json,os,time,signal
marker=sys.argv[1]
for line in sys.stdin:
 q=json.loads(line);i=q.get('id');m=q['method']
 if i is None:continue
 if m=='server/discover':reply={'error':{'code':-32601,'message':'legacy'}}
 elif m=='initialize':reply={'result':{'protocolVersion':'2025-11-25','capabilities':{'tools':{}},'serverInfo':{'name':'owned','version':'1'}}}
 elif m=='tools/list':reply={'result':{'tools':[{'name':'block','inputSchema':{'type':'object'}}]}}
 elif m=='tools/call':
  signal.signal(signal.SIGTERM,signal.SIG_IGN)
  with open(marker,'w') as f:f.write(str(os.getpid()))
  while True:time.sleep(.1)
 else:continue
 reply.update(jsonrpc='2.0',id=i);print(json.dumps(reply),flush=True)
""")
 config.write_text(json.dumps({'executable':'/usr/bin/python3','arguments':[str(script),str(marker)],'credentialNames':[]}))
 review=run([*base,'--allow-server-process']);reviewfile.write_text(json.dumps(review));call[call.index('memory_stats')]='block'
 child=subprocess.Popen([binary,*call,'--confirm-call'],env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE);owned_pid=None
 try:
  deadline=time.monotonic()+15
  while time.monotonic()<deadline and child.poll() is None:
   if marker.exists():owned_pid=int(marker.read_text());break
   time.sleep(.02)
  require(owned_pid is not None,'interrupt fixture reached actual tool call')
  child.send_signal(signal.SIGINT);out,err=child.communicate(timeout=15)
  require(child.returncode==130 and not out,'CLI Ctrl-C joins cancellation without a false result')
  try:os.kill(owned_pid,0);alive=True
  except ProcessLookupError:alive=False
  require(not alive,'CLI cancellation reaped only its owned server')
 finally:
  if child.poll() is None:
   child.send_signal(signal.SIGINT)
   try:child.wait(timeout=5)
   except subprocess.TimeoutExpired:child.kill();child.wait()
  if owned_pid is not None:
   # A diagnostic failure must not strand this authored, still-identical child.
   observed=subprocess.run(['/bin/ps','-p',str(owned_pid),'-o','command='],capture_output=True,text=True).stdout
   if str(script) in observed and str(marker) in observed:os.kill(owned_pid,signal.SIGKILL)
 report={'format':'OSwind MCP manual client process check','state':'passed','checks':checks,'binarySHA256':hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest(),'scope':'Owned local existing-server interoperability and manual review gates. No HTTP, third-party server, model loop, automatic ingestion or native UI acceptance.'}
 if a.output:pathlib.Path(a.output).write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps(report,indent=2))
