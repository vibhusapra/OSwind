#!/usr/bin/env python3
"""Owned authored-span interchange, scoped retrieval and portability contracts.

Positive native AX capture is not exercised. No normal-library default, model
provider, permission request or external connection is used.
"""
import argparse,datetime,hashlib,json,pathlib,socket,sqlite3,subprocess,sys,time,urllib.error,urllib.parse,urllib.request,uuid
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary',type=pathlib.Path);p.add_argument('--root',required=True,type=pathlib.Path);p.add_argument('--old-cli',type=pathlib.Path);a=p.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1];binary=a.binary.resolve();base=a.root.resolve();base.mkdir(mode=0o700,exist_ok=False);library=base/'library';sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
report=dict(format='OSwind sampled text process contracts',version=1,state='running',cliSHA256=sha(binary),harnessSHA256=sha(pathlib.Path(__file__)),checks=[],operations=[],fixtureIsNativeCapture=False)
def save():(base/'report.json').write_text(json.dumps(report,indent=2)+'\n')
def run(*args,data=library,cli=binary,ok=True):
 r=subprocess.run([str(cli),'--data',str(data),*map(str,args)],capture_output=True,text=True,timeout=120)
 report['operations'].append(dict(command=str(args[0]),returncode=r.returncode,stdoutSHA256=hashlib.sha256(r.stdout.encode()).hexdigest(),stderrSHA256=hashlib.sha256(r.stderr.encode()).hexdigest()));save()
 assert (r.returncode==0)==ok,(args,r.stdout,r.stderr)
 return r
def value(*args,**kwargs):return json.loads(run(*args,**kwargs).stdout)
def ids(result):return [h['memory']['id'] for h in (result['hits'] if isinstance(result,dict) else result)]
def cli_search(data=library,starts=False):return value('search','--mode','keyword','--from',lower,'--to',upper,*(['--source-starts-only'] if starts else []),'observedmarker',data=data)
server=None
try:
 seed=run('note','Owned observation interchange seed').stdout.strip();template=value('get',seed)
 first=datetime.datetime(2024,11,3,5,59,50,tzinfo=datetime.timezone.utc);last=first+datetime.timedelta(seconds=20)
 stamp=lambda d:d.isoformat().replace('+00:00','Z')
 lower=stamp(first+datetime.timedelta(seconds=10));upper=stamp(last+datetime.timedelta(seconds=1))
 sources=[]
 for n in range(2):
  m=template.copy();begin=first+datetime.timedelta(minutes=10*n)
  m.update(id='owned-observation-'+str(n),kind='screen',timestamp=stamp(begin),endTimestamp=stamp(begin+datetime.timedelta(seconds=20)),app='Owned fixture',bundleID='org.oswind.owned',title='Owned sampled page',text='Owned observedmarker archive context',display='accessibility-window',regions=[],textObservation=dict(version=1,sessionID=str(uuid.uuid4()).upper(),samples=5,largestGapSeconds=5))
  sources.append(m)
 fixture=base/'authored-spans.json';fixture.write_text(json.dumps(sources));assert value('import',fixture,'--json')['imported']==2
 assert ids(cli_search())==['owned-observation-0'];assert ids(cli_search(starts=True))==[]
 assert value('get','owned-observation-0')['textObservation']['samples']==5
 assert ids(value('search','--mode','keyword','--from',stamp(last),'--to',upper,'observedmarker'))==['owned-observation-0']
 assert ids(value('search','--mode','keyword','--to',stamp(first),'observedmarker'))==[]
 run('search','--source-starts-only','--source-starts-only','observedmarker',ok=False)
 report['checks'].append('authored spans retain metadata; inclusive last sample, exclusive query end and strict source-start CLI option')
 calendar=value('activity','--month','2024-11','--day','2024-11-03','--time-zone','America/New_York')
 repeated=[h for h in calendar['hours'] if h['hour']==1];assert [h['sources'] for h in repeated]==[1,1]
 # The second span starts after the transition. Scope the first span only:
 scoped=value('activity','--month','2024-11','--day','2024-11-03','--time-zone','America/New_York','--from',lower,'--to',upper)
 assert scoped['totalSources']==0 and scoped['timeBasis']=='source-start' and scoped['scope']['sourceStartsOnly'] is True
 report['checks'].append('repeated civil hours retain start-based calendar counts; later span overlap does not inflate calendar buckets')
 sys.path.insert(0,str(repo/'sdk/python'));from oswind import Client
 with Client(binary,library) as client:
  assert ids(client.search('observedmarker',start=lower,end=upper))==['owned-observation-0']
  assert ids(client.search('observedmarker',start=lower,end=upper,sourceStartsOnly=True))==[]
  assert client.get('owned-observation-0')['textObservation']['samples']==5
  tool=next(t for t in client.tools() if t['name']=='search_memory');assert tool['inputSchema']['properties']['sourceStartsOnly']['type']=='boolean'
 report['checks'].append('actual read-only Python SDK/MCP child preserves sampled metadata and source-start scope; tool schema advertises boolean')
 # Reuse a recently closed socket address, while still refusing a live listener.
 # The preceding integration smoke uses this same fixed local API port.
 probe=socket.socket();probe.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);probe.bind(('127.0.0.1',47831));probe.close()
 server=subprocess.Popen([str(binary),'--data',str(library),'serve'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 tokenfile=library/'api-token';deadline=time.monotonic()+10
 while not tokenfile.exists():
  assert server.poll() is None and time.monotonic()<deadline,'Owned server did not become ready';time.sleep(.02)
 token=tokenfile.read_text()
 def http(parameters):
  request=urllib.request.Request('http://127.0.0.1:47831/v1/search?'+urllib.parse.urlencode(parameters),headers={'Authorization':'Bearer '+token})
  try:
   with urllib.request.urlopen(request,timeout=10) as response:return response.status,json.load(response)
  except urllib.error.HTTPError as error:return error.code,json.load(error)
 params=dict(query='observedmarker',mode='keyword',start=lower,end=upper)
 while True:
  try:status,body=http(params);break
  except urllib.error.URLError:
   assert server.poll() is None and time.monotonic()<deadline;time.sleep(.02)
 assert status==200 and ids(body)==['owned-observation-0'];assert ids(http(params|dict(sourceStartsOnly='true'))[1])==[];assert http(params|dict(sourceStartsOnly='1'))[0]==400
 server.terminate();server.wait(timeout=10);server=None
 report['checks'].append('owned authenticated loopback socket includes overlap, supports strict source-start filtering and refuses non-boolean input')
 archive=base/'observations.oswindbackup';assert value('backup','create',archive)['sourceSchema']==26
 restored=base/'restored';run('backup','restore',archive,'--to',restored)
 quiet=json.loads((restored/'settings.json').read_text());assert not quiet['captureOnLaunch'] and not quiet['apiEnabled'];assert ids(cli_search(data=restored))==['owned-observation-0']
 assert value('get','owned-observation-0',data=restored)['textObservation']==sources[0]['textObservation']
 exported=base/'observations.json';run('export',exported);copied=base/'json-copy';assert value('import',exported,'--json',data=copied)['imported']==3;assert ids(cli_search(data=copied))==['owned-observation-0']
 report['checks'].append('quiet schema26 backup and JSON round trip preserve observed extent and rebuild sparse range lookup')
 markdown=base/'markdown';run('export-markdown',markdown)
 pages=list(markdown.rglob('*.md'));observed=[f.read_text() for f in pages if 'text_observation_samples:' in f.read_text()]
 assert len(observed)==2 and all('largest_observation_gap_seconds:' in s and 'not continuous activity' in s for s in observed)
 report['checks'].append('portable Markdown identifies sample counts and gaps without claiming continuous activity')
 if a.old_cli:
  old=a.old_cli.resolve();before=sha(library/'memory.sqlite');refusal=run('stats','--json',cli=old,ok=False);assert 'newer OSwind version' in refusal.stderr;assert sha(library/'memory.sqlite')==before
  run('backup','inspect',archive,cli=old,ok=False);report['olderCLI_SHA256']=sha(old);report['checks'].append('actual preceding signed23 client refuses schema26 library and archive; database bytes unchanged')
  legacy=base/'actual-older23-library';assert value('import',fixture,'--json',cli=old,data=legacy)['imported']==2
  def legacy_snapshot():
   with sqlite3.connect('file:'+str(legacy/'memory.sqlite')+'?mode=ro',uri=True) as db:
    rows=db.execute('SELECT id,hex(payload) FROM memories ORDER BY id').fetchall();version=db.execute('PRAGMA user_version').fetchone()[0]
    return version,rows
  version,beforeRows=legacy_snapshot();assert version==23 and all('textObservation' not in bytes.fromhex(row[1]).decode() for row in beforeRows)
  assert value('stats','--json',data=legacy)['count']==2
  version,afterRows=legacy_snapshot();assert version==26 and afterRows==beforeRows
  with sqlite3.connect('file:'+str(legacy/'memory.sqlite')+'?mode=ro',uri=True) as db:assert db.execute('SELECT COUNT(*) FROM text_observation_ranges').fetchone()[0]==0
  report['checks'].append('actual prior23 writer strips unknown span fields; upgrade preserves exact typed source payloads and installs empty range projection')

 preview=value('erase','preview','--from',stamp(last),'--to',upper);assert preview['sources']==1
 erased=value('erase','apply','--from',stamp(last),'--to',upper,'--token',preview['token']);assert erased['sources']==1;assert ids(cli_search())==[]
 report['checks'].append('preview-guarded erasure includes exact last observed sample and removes its range from later retrieval')
 report.update(state='completed',schema=26,fixtureIsNativeCapture=False,scope='Authored bounded span fixtures, actual CLI/HTTP/MCP/SDK/backup/Markdown/erase processes and optional older-client refusal. No positive native AX capture, normal history, calibrated performance/power or whole-product competitor acceptance.');save();print(json.dumps(report,indent=2))
except BaseException as error:report.update(state='failed',failure=str(error));save();raise
finally:
 if server is not None:
  if server.poll() is None:server.terminate()
  try:server.wait(timeout=10)
  except subprocess.TimeoutExpired:server.kill();server.wait(timeout=10)
