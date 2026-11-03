#!/usr/bin/env python3
import argparse,pathlib,sqlite3,json,hashlib,struct,os,subprocess
p=argparse.ArgumentParser();p.add_argument('--rows',type=int,choices=[1000,100000],required=True);p.add_argument('--destination',type=pathlib.Path,required=True);p.add_argument('--fixtures',type=pathlib.Path,required=True);p.add_argument('--screenpipe',type=pathlib.Path,required=True);a=p.parse_args()
root=a.fixtures.resolve();owned=root/('oswind-'+str(a.rows));dest=a.destination.resolve();assert dest.parent==root
assert (owned/'owned-fixture').read_text()=='OSwind authored capture scale fixture v1'
report=json.loads((owned/'report.json').read_text());assert report['state']=='completed' and report['rows']==a.rows
assert not dest.exists();dest.mkdir(mode=0o700)
with sqlite3.connect(dest/'db.sqlite') as db:db.execute('PRAGMA journal_mode=WAL')
binary=a.screenpipe.resolve();env={k:v for k,v in os.environ.items() if not any(x in k.upper() for x in ['API_KEY','API_TOKEN','PASSWORD','CREDENTIAL','SECRET'])};env.update(SCREENPIPE_DATA_DIR=str(dest),SCREENPIPE_DISABLE_TELEMETRY='1',SCREENPIPE_DISABLE_ANALYTICS='1',SCREENPIPE_CLI_TELEMETRY_DISABLED='1',DO_NOT_TRACK='1')
assert hashlib.sha256(binary.read_bytes()).hexdigest()=='49aab1665e03da5366314ad859c695958b17970414ae18f1dabad65e9451f3a8'
def native(args,name):
 r=subprocess.run([str(binary),*args],env=env,cwd=root,capture_output=True,text=True,timeout=60)
 (dest/(name+'.stdout')).write_text(r.stdout);(dest/(name+'.stderr')).write_text(r.stderr);assert r.returncode==0,(name,r.stderr)
 return r
assert native(['search','OWNEDABSENT7k11','--data-dir',str(dest),'--content-type','ocr','--json','--limit','1'],'initialize').stdout==''
source=sqlite3.connect('file:'+str(owned/'library/memory.sqlite')+'?mode=ro',uri=True)
rows=source.execute('SELECT id,timestamp,app,title,url,text FROM memories ORDER BY id COLLATE BINARY').fetchall();source.close();assert len(rows)==a.rows
h=hashlib.sha256()
for identifier,stamp,app,title,url,text in rows:
 assert identifier.startswith('scale-') and text=='Owned source '+identifier[6:] and app=='Owned capture scale' and title=='Scale record' and stamp==1700000000
 for s in [identifier,text]:b=s.encode();h.update(struct.pack('<Q',len(b)));h.update(b)
assert h.hexdigest()==report['originalIDTextSHA256After']
db=sqlite3.connect(dest/'db.sqlite');assert db.execute('SELECT COUNT(*) FROM frames').fetchone()==(0,)
with db:
 db.execute('PRAGMA foreign_keys=ON')
 db.execute('INSERT INTO video_chunks(id,file_path,device_name) VALUES(1,?,?)',(str(dest/'authored-no-media.mp4'),'Authored benchmark only'))
 db.executemany("INSERT INTO frames(id,video_chunk_id,offset_index,timestamp,name,app_name,window_name,focused,browser_url,device_name,full_text,text_source) VALUES(?,1,0,strftime('%Y-%m-%dT%H:%M:%fZ',?,'unixepoch'),?,?,?,1,?,?,?,'ocr')",((int(identifier[6:]),stamp,identifier,app,title,url,'Authored benchmark only',text) for identifier,stamp,app,title,url,text in rows))
assert db.execute('SELECT name,full_text FROM frames ORDER BY name COLLATE BINARY').fetchall()==[(r[0],r[5]) for r in rows]
assert not db.execute('PRAGMA foreign_key_check').fetchall()
with db:db.execute("INSERT INTO frames_fts(frames_fts,rank) VALUES('integrity-check',1)")
db.execute('PRAGMA wal_checkpoint(TRUNCATE)');db.close()
check=native(['db','check'],'native-check');assert str(dest/'db.sqlite') in check.stdout and 'database is healthy' in check.stdout
value={'rows':a.rows,'identicalIDTextSHA256':h.hexdigest(),'fixtureSourceCommit':report.get('sourceCommit','See owned fixture source receipt'),'screenpipePackage':'@screenpipe/cli-darwin-arm64@0.4.54','nativeQuickCheckSHA256':hashlib.sha256((dest/'native-check.stdout').read_bytes()).hexdigest(),'nativeFTSContentIntegrityCheck':True,'schemaInitialization':'Unmodified published offline search initializes its normal empty database and migrations.','screenpipeIngestion':'Authored SQL rows with native-installed frame/FTS triggers; no capture/API ingestion.','oswindIngestion':'Existing explicit authored scale fixture with ordinary MemoryStore source/index triggers.','scope':'Identical authored ID/text corpus only. No media/models/recording service, ingestion/capture equivalence, performance/energy or product ranking claim.'}
with (dest/'corpus.json').open('x') as f:json.dump(value,f,indent=2);f.write('\n')
print(json.dumps({'manifest':str(dest/'corpus.json'),'rows':a.rows,'identicalIDTextSHA256':h.hexdigest(),'nativeQuickCheck':True,'FTSContentIntegrity':True}))
