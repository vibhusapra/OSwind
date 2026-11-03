#!/usr/bin/env python3
"""Matched authored offline CLI controls and end-to-end process observations.
No recorder, API server, cloud model, real history or capture-performance claim.
"""
import argparse,pathlib,subprocess,sqlite3,os,json,hashlib,struct,math,statistics,time,random,platform
p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--repetitions',type=int,default=21);p.add_argument('--oswind-frozen',type=pathlib.Path,required=True);p.add_argument('--oswind-baseline',type=pathlib.Path,required=True);p.add_argument('--fixtures',type=pathlib.Path,required=True);p.add_argument('--screenpipe',type=pathlib.Path,required=True);a=p.parse_args()
assert 3<=a.repetitions<=101
root=a.fixtures.resolve();folder=a.oswind_frozen.resolve()
ours=folder/'oswindctl';vendor=a.screenpipe.resolve();sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
baseline_folder=a.oswind_baseline.resolve()
baseline=baseline_folder/'oswindctl';baseline_manifest=json.loads((baseline_folder/'manifest.json').read_text())
manifest=json.loads((ours.parent/'manifest.json').read_text());pins={'oswind':manifest['binarySHA256'],'screenpipe':'49aab1665e03da5366314ad859c695958b17970414ae18f1dabad65e9451f3a8'}
assert sha(ours)==pins['oswind'] and sha(vendor)==pins['screenpipe'] and sha(baseline)==baseline_manifest['binarySHA256']
assert not a.output.exists();a.output.mkdir(mode=0o700)
base={k:v for k,v in os.environ.items() if not any(x in k.upper() for x in ['API_KEY','API_TOKEN','PASSWORD','CREDENTIAL','SECRET'])};base.update(SCREENPIPE_DISABLE_TELEMETRY='1',SCREENPIPE_DISABLE_ANALYTICS='1',SCREENPIPE_CLI_TELEMETRY_DISABLED='1',DO_NOT_TRACK='1')
def digest_rows(path,product):
 db=sqlite3.connect('file:'+str(path)+'?mode=ro',uri=True)
 query='SELECT id,text FROM memories ORDER BY id COLLATE BINARY' if product=='oswind' else 'SELECT name,full_text FROM frames ORDER BY name COLLATE BINARY'
 h=hashlib.sha256();count=0
 for identifier,text in db.execute(query):
  assert text=='Owned source '+identifier[6:]
  for value in [identifier,text]:b=value.encode();h.update(struct.pack('<Q',len(b)));h.update(b)
  count+=1
 db.close();return count,h.hexdigest()
def locations(rows):
 archive=root/('oswind-'+str(rows));assert (archive/'owned-fixture').read_text()=='OSwind authored capture scale fixture v1';owned=archive/'library'
 data=root/'data' if rows==1000 else root/'screenpipe-100000'
 receipt=root/'corpus-1000.json' if rows==1000 else data/'corpus.json'
 return owned,data,json.loads(receipt.read_text())
def verify():
 assert sha(ours)==pins['oswind'] and sha(vendor)==pins['screenpipe'] and sha(baseline)==baseline_manifest['binarySHA256']
 for rows in [1000,100000]:
  owned,data,receipt=locations(rows)
  assert digest_rows(owned/'memory.sqlite','oswind')==digest_rows(data/'db.sqlite','screenpipe')==(rows,receipt['identicalIDTextSHA256'])
verify()
def host_activity():
 try:cpu=sum(float(x) for x in subprocess.check_output(['ps','-axo','%cpu='],text=True).split())
 except (ValueError,subprocess.CalledProcessError):cpu=None
 return {'loadAverage':list(os.getloadavg()),'recentSystemCPUPercentSum':cpu,'logicalCPUs':os.cpu_count(),'processNamesRecorded':False,'otherHostActivityControlled':False}
activity_start=host_activity()
def cases(rows):return [('rare-first','"1"',{},['scale-1']),('rare-991','"991"',{},['scale-991']),('rare-last','"'+str(rows)+'"',{},['scale-'+str(rows)]),('absent','"OWNEDABSENT7k11"',{},[]),('broad','"Owned source"',{},None),('app-present','"991"',{'app':'Owned capture scale'},['scale-991']),('app-absent','"991"',{'app':'Owned absent app'},[]),('time-present','"991"',{'start':'2023-11-14T22:13:19Z','end':'2023-11-14T22:13:21Z'},['scale-991']),('time-absent','"991"',{'start':'2024-01-01T00:00:00Z','end':'2024-01-02T00:00:00Z'},[])]
def validate(text,product,rows,expected):
 hits=[json.loads(line) for line in text.splitlines() if line.strip()] if product=='screenpipe' else json.loads(text)
 ids=[]
 for hit in hits:
  if product=='screenpipe':
   assert hit['type']=='OCR';d=hit['content'];identifier=d['frame_name'];body=d['text'];app=d['app_name'];title=d['window_name']
  else:
   assert hit['match']=='keyword' and math.isfinite(hit['score']);d=hit['memory'];identifier=d['id'];body=d['text'];app=d['app'];title=d['title']
  assert identifier.startswith('scale-') and 1<=int(identifier[6:])<=rows
  assert body=='Owned source '+identifier[6:] and app=='Owned capture scale' and title=='Scale record' and d['timestamp']=='2023-11-14T22:13:20Z'
  ids.append(identifier)
 assert len(ids)==len(set(ids))
 if expected is None:assert len(ids)==100
 else:assert ids==expected,(product,ids,expected)
 return ids
def run(product,rows,case,iteration):
 label,query,scope,expected=case;owned,data,receipt=locations(rows)
 if product=='screenpipe':command=[str(vendor),'search',query,'--data-dir',str(data),'--content-type','ocr','--json','--limit','100']
 else:command=[str(baseline if product=='oswind-baseline' else ours),'--data',str(owned),'search','--mode','keyword','--limit','100',query]
 for key,value in scope.items():command.extend([({'app':'--app','start':'--start','end':'--end'} if product=='screenpipe' else {'app':'--app','start':'--from','end':'--to'})[key],value])
 stem=f'{rows}-{label}-{iteration}-{product}';stdout=a.output/(stem+'.stdout');stderr=a.output/(stem+'.stderr')
 with stdout.open('xb') as out,stderr.open('xb') as err:
  start=time.perf_counter();process=subprocess.Popen(command,cwd=root,env=base|{'SCREENPIPE_DATA_DIR':str(data),'OSWIND_DATA_DIR':str(owned)},stdout=out,stderr=err)
  deadline=start+60;timedout=False
  while True:
   pid,status,usage=os.wait4(process.pid,os.WNOHANG)
   if pid:break
   if time.perf_counter()>deadline:
    timedout=True
    try:process.kill()
    except ProcessLookupError:pass
    pid,status,usage=os.wait4(process.pid,0);break
   time.sleep(.001)
  wall=(time.perf_counter()-start)*1000;process.returncode=os.waitstatus_to_exitcode(status)
 assert not timedout and process.returncode==0,(stem,process.returncode,stderr.read_text()[-1000:])
 ids=validate(stdout.read_text(),product,rows,expected)
 return {'rows':rows,'case':label,'iteration':iteration,'product':product,'wallMS':wall,'userCPUSeconds':usage.ru_utime,'systemCPUSeconds':usage.ru_stime,'peakRSSBytes':usage.ru_maxrss*(1 if platform.system()=='Darwin' else 1024),'stdoutBytes':stdout.stat().st_size,'returnedIDs':ids,'stdoutSHA256':sha(stdout),'stderrSHA256':sha(stderr)}
def stats(values):
 assert values and all(math.isfinite(v) and v>=0 for v in values);s=sorted(values)
 return {'samples':len(values),'median':statistics.median(s),'p95':s[math.ceil(.95*len(s))-1]}
# One complete validated warm-up per product/case/scale; retained but excluded.
warm=[]
for rows in [1000,100000]:
 for case in cases(rows):
  for product in ['oswind-baseline','oswind','screenpipe']:warm.append(run(product,rows,case,'warm'))
measurements=[];rng=random.Random(71059)
for iteration in range(a.repetitions):
 tasks=[(rows,case) for rows in [1000,100000] for case in cases(rows)];rng.shuffle(tasks)
 for index,(rows,case) in enumerate(tasks):
  products=['oswind-baseline','oswind','screenpipe'];offset=(iteration+index)%3;products=products[offset:]+products[:offset]
  pair=[run(product,rows,case,iteration) for product in products]
  old=next(x for x in pair if x['product']=='oswind-baseline');new=next(x for x in pair if x['product']=='oswind')
  assert old['returnedIDs']==new['returnedIDs'] and old['stdoutSHA256']==new['stdoutSHA256'],('candidate output differs',rows,case[0])
  measurements.extend(pair)
 print('FINISHED_ROUND',iteration+1,flush=True)
verify();summaries=[]
for rows in [1000,100000]:
 for case in cases(rows):
  products={}
  for product in ['oswind-baseline','oswind','screenpipe']:
   values=[m for m in measurements if m['rows']==rows and m['case']==case[0] and m['product']==product]
   products[product]={metric:stats([v[metric] for v in values]) for metric in ['wallMS','userCPUSeconds','systemCPUSeconds','peakRSSBytes','stdoutBytes']}
  summaries.append({'rows':rows,'case':case[0],'query':case[1],'scope':case[2],'products':products})
result={'format':'OSwind matched offline CLI keyword observations v1','oswindBaselineSource':baseline_manifest['source'],'oswindBaselineBinarySHA256':baseline_manifest['binarySHA256'],'candidateOutputsByteIdenticalToBaseline':True,'oswindSource':manifest['source'],'oswindBuild':'swift build -c release --product oswindctl','screenpipePackage':'@screenpipe/cli-darwin-arm64@0.4.54','screenpipeBuild':'Unmodified publisher prebuilt; compiler options not independently established.','binaryPins':pins,'repetitions':a.repetitions,'harnessSHA256':sha(pathlib.Path(__file__)),'host':{'os':platform.platform(),'architecture':platform.machine()},'hostActivity':{'start':activity_start,'end':host_activity()},'summaries':summaries,'measurements':measurements,'warmups':warm,'scope':['Identical authored IDs/text, nine exact-term/broad/absent/app/time controls at1000/100000 rows; every returned ID/body/app/title/time validated. Broad ties may have different eligible membership/order.','Offline CLI process startup, DB opening/migration checks, SQL, output serialization/file writes and shutdown together; wall polling resolution about1ms. Child CPU and peakRSS from wait4. No daemon/API latency or isolated backend timing.','Full native schema initialized by Screenpipe search; authored SQL frame/FTS seed and authored MemoryStore scale baseline. Not capture/API ingestion equivalence or semantic/representative retrieval quality.','One complete warm-up excluded; filesystem/OS caches uncontrolled; rotating three-product order and shuffled case order. Background host activity remains uncontrolled; no energy or whole-product ranking claim.']}
with (a.output/'report.json').open('x') as h:json.dump(result,h,indent=2);h.write('\n')
print(json.dumps({'report':str(a.output/'report.json'),'validatedMeasurements':len(measurements),'validatedWarmups':len(warm)}))
