#!/usr/bin/env python3
"""Marked synthetic calendar archive + independent Python civil-time count oracle."""
from owned_sqlite_fixture import register_inactive_sync_fixture
import argparse,collections,datetime,hashlib,json,pathlib,sqlite3,subprocess,time,zoneinfo
p=argparse.ArgumentParser();p.add_argument('binary',type=pathlib.Path);p.add_argument('--root',type=pathlib.Path,required=True);p.add_argument('--sources',type=int,default=100000);p.add_argument('--text-bytes',type=int,default=1024);p.add_argument('--distribution',choices=['year','month'],default='year');p.add_argument('--repetitions',type=int,default=5);p.add_argument('--reuse-owned',action='store_true');p.add_argument('--output',type=pathlib.Path);a=p.parse_args()
assert 1<=a.sources<=2000000 and 32<=a.text_bytes<=16384 and 1<=a.repetitions<=50
binary=a.binary.resolve();base=a.root.resolve();library=base/'library';marker=base/'owned-activity-fixture.json';output=a.output.resolve() if a.output else base/'report.json'
parameters={'format':'OSwind owned activity benchmark fixture v1','sources':a.sources,'textBytes':a.text_bytes,'distribution':a.distribution,'seed':1729,'normalHistory':False}
def run(*args):
 r=subprocess.run([str(binary),'--data',str(library),*map(str,args)],capture_output=True,text=True,timeout=120);assert r.returncode==0,r.stderr;return r.stdout
UTC=datetime.timezone.utc;zone=zoneinfo.ZoneInfo('America/New_York');anchor=datetime.datetime(2024,1 if a.distribution=='year' else 3,1,tzinfo=UTC).timestamp();span=(366 if a.distribution=='year' else 31)*86400
apps=['Notes','Safari','Terminal'];kinds=['screen','audio','note','summary'];text=('Owned synthetic calendar source. '*((a.text_bytes+31)//32))[:a.text_bytes]
def metadata(i):return anchor+(i*15485863%span)+(i%1000)/1000,apps[i%3],kinds[i%4],i%7==0,['release' if i%5==0 else 'other']
if a.reuse_owned:
 assert json.loads(marker.read_text())==parameters
else:
 base.mkdir(mode=0o700,exist_ok=False);seed=run('note','Owned synthetic calendar benchmark seed').strip()
 connection=sqlite3.connect(library/'memory.sqlite')
 register_inactive_sync_fixture(connection)
 try:
  row=connection.execute('SELECT payload FROM memories WHERE id=?',(seed,)).fetchone();template=json.loads(row[0]);connection.execute('DELETE FROM memories');connection.commit();connection.execute('PRAGMA synchronous=OFF');connection.execute('BEGIN')
  sql='INSERT INTO memories(id,timestamp,kind,app,title,url,text,favorite,payload) VALUES(?,?,?,?,?,NULL,?,?,?)';chunk=[];began=time.monotonic()
  for i in range(a.sources):
   stamp,app,kind,favorite,tags=metadata(i);identifier=f'owned-calendar-{i}';payload=dict(template,id=identifier,timestamp=stamp-978307200,kind=kind,app=app,title='Owned activity fixture',text=text,favorite=favorite,tags=tags);payload.pop('embeddingModel',None);payload.pop('embedding',None)
   chunk.append((identifier,stamp,kind,app,'Owned activity fixture',text,int(favorite),json.dumps(payload,separators=(',',':')).encode()))
   if len(chunk)==1000:connection.executemany(sql,chunk);chunk=[]
  if chunk:connection.executemany(sql,chunk)
  connection.commit();connection.execute('PRAGMA wal_checkpoint(TRUNCATE)');assert connection.execute('SELECT COUNT(*) FROM memories').fetchone()[0]==a.sources
 finally:connection.close()
 marker.write_text(json.dumps(parameters,sort_keys=True)+'\n');(base/'generation.json').write_text(json.dumps({'wallSeconds':time.monotonic()-began})+'\n')
cases=[('all',[]),('application',['--app','Safari']),('kind',['--kind','screen']),('saved',['--favorites']),('tag',['--tag','release']),('combined',['--app','Safari','--kind','screen','--favorites']),('tagCombined',['--app','Safari','--kind','screen','--favorites','--tag','release']),('missingTag',['--tag','missing']),('wideTimeBounds',['--from','2024-01-01T00:00:00Z','--to','2025-01-01T00:00:00Z'])]
expected={name:{'days':collections.Counter(),'hours':collections.Counter()} for name,_ in cases};day_start=datetime.datetime(2024,3,10,tzinfo=zone).timestamp();day_end=datetime.datetime(2024,3,11,tzinfo=zone).timestamp()
for i in range(a.sources):
 stamp,app,kind,favorite,tags=metadata(i);local=datetime.datetime.fromtimestamp(stamp,zone)
 if local.year!=2024 or local.month!=3:continue
 names=['all','wideTimeBounds']+(['application'] if app=='Safari' else [])+(['kind'] if kind=='screen' else [])+(['saved'] if favorite else [])+(['tag'] if 'release' in tags else [])+(['combined'] if app=='Safari' and kind=='screen' and favorite else [])+(['tagCombined'] if app=='Safari' and kind=='screen' and favorite and 'release' in tags else [])
 for name in names:
  expected[name]['days'][local.strftime('%Y-%m-%d')]+=1
  if day_start<=stamp<day_end:expected[name]['hours'][int((stamp-day_start)//3600)]+=1
opened=time.monotonic();startup=json.loads(run('stats','--json'));initial_open_ms=(time.monotonic()-opened)*1000
assert startup['count']==a.sources
results={}
for name,flags in cases:
 measurements=[]
 for _ in range(a.repetitions):
  began=time.monotonic();response=json.loads(run('activity','--month','2024-03','--day','2024-03-10','--time-zone','America/New_York','--diagnostics',*flags));wall=(time.monotonic()-began)*1000
  assert len(response['days'])==31 and len(response['hours'])==23
  assert all(day['sources']==expected[name]['days'][day['key']] for day in response['days'])
  for index,hour in enumerate(response['hours']):
   start=datetime.datetime.fromisoformat(hour['start'].replace('Z','+00:00')).timestamp();end=datetime.datetime.fromisoformat(hour['end'].replace('Z','+00:00')).timestamp()
   assert start==day_start+index*3600 and end==start+3600 and hour['sources']==expected[name]['hours'][index]
  assert response['totalSources']==sum(expected[name]['days'].values())
  measurements.append({'aggregationMS':response['diagnostics']['aggregation_ms'],'wallMS':wall,'processPeakRSSBytes':response['diagnostics']['process_peak_rss_bytes']})
 ordered=sorted(m['aggregationMS'] for m in measurements);results[name]={'matchedMonthSources':sum(expected[name]['days'].values()),'measurements':measurements,'medianAggregationMS':ordered[len(ordered)//2],'p95AggregationMS':ordered[min(len(ordered)-1,int(len(ordered)*.95))]}
report={'format':'OSwind activity calendar synthetic benchmark v2','fixture':parameters,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'harnessSHA256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),'initialOpenWallMS':initial_open_ms,'initialOpenScope':'First stats CLI open before timed queries; includes derived-cache installation if needed. Not a controlled cold-start measurement. Fresh fixture generation already opens the store; reused older fixtures may require migration.','independentPythonZoneinfoOraclePass':True,'scope':'Synthetic metadata archive, complete month and23-hour DST day. Fresh CLI processes, uncontrolled caches/background activity; aggregation includes scheduling/validation/SQL, excludes encoding. Peak RSS includes process startup. No capture, inference, power or competitor claim.','cases':results}
assert not output.exists();output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({name:{'medianMS':r['medianAggregationMS'],'p95MS':r['p95AggregationMS']} for name,r in results.items()},indent=2))
