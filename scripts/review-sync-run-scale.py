#!/usr/bin/env python3
"""Independent readonly check of authored1k/10k native incoming-run output."""
import argparse,contextlib,hashlib,importlib.util,json,math,pathlib,re,sqlite3,statistics
p=pathlib.Path(__file__).with_name('review-sync-incoming-routines.py');spec=importlib.util.spec_from_file_location('owned_run_common',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
need=m.need;encode=m.encode;sha=m.digest
COLUMNS='id,routine_id,revision,scheduled_at,started,finished,trigger,status,chat_id,message,scope'
def object_digest(identity):return sha(b'OSwind.sync.object.v1\0routineRun\0'+m.frames.frame([identity['table'],identity['origin'],identity['lifetime']]))
def review(root):
 root=pathlib.Path(root).absolute();need(root.resolve()==root and root.is_dir() and not root.is_symlink(),'Invalid owned scale root');need((root/'owned-fixture').read_bytes()==b'OSwind authored incoming run scale v1','Owned marker differs')
 run=json.loads((root/'run.json').read_text());need(run['state']=='completed' and run['returncode']==0,'Successful completed driver required')
 log=root.parent/run['logName'];need(run['logName'] in ['source-projection-regression.log','optimized.log'] and sha(log.read_bytes())==run['logSHA256'],'Actual log differs')
 text=log.read_text();case="Test Case '-[OSwindCoreTests.SyncIncomingSourceTests testOwnedIncomingRunProjectionAtBoundedScale]' passed";need(text.count(case)==1 and text.count('INCOMING_RUN_SCALE rows=1000 ')==1 and text.count('INCOMING_RUN_SCALE rows=10000 ')==1,'Executed passing benchmark required')
 summaries=re.findall(r'Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures? \((\d+) unexpected\)',text);need(summaries and int(summaries[-1][2])==0 and int(summaries[-1][3])==0,'Suite failed')
 inputs=root.parent/'inputs.json';need(sha(inputs.read_bytes())==run['sourceInputsSHA256'],'Input manifest changed')
 for name,h in json.loads(inputs.read_text()).items():
  if name.startswith(('Sources/','Tests/','Vendor/')) or name in ['Package.swift','Package.resolved']:
   relative=pathlib.PurePosixPath(name);need(not relative.is_absolute() and '..' not in relative.parts and str(relative)==name,'Invalid source input path');need(sha((pathlib.Path.cwd()/relative).read_bytes())==h,'Compiled source/test input changed')
 report_path=root/'report.json';need(sha(report_path.read_bytes())==run['reportSHA256'],'Benchmark report changed');reports=json.loads(report_path.read_text());need([r['count'] for r in reports]==[1000,10000],'Scale coverage differs');results=[];pins={}
 @contextlib.contextmanager
 def database(path):
  need(path.resolve()==path and path.is_file() and not path.is_symlink(),'Invalid SQLite path')
  for suffix in ['-wal','-journal']:need(not path.with_name(path.name+suffix).exists() or path.with_name(path.name+suffix).stat().st_size==0,'Library still has live journal')
  before=sha(path.read_bytes());pins[str(path.relative_to(root))]=before
  with contextlib.closing(sqlite3.connect(path.as_uri()+'?mode=ro&immutable=1',uri=True)) as db:
   need(db.execute('PRAGMA user_version').fetchone()==(29,) and db.execute('PRAGMA quick_check').fetchall()==[('ok',)] and db.execute('PRAGMA foreign_key_check').fetchall()==[],'SQLite integrity differs');m.frames.verify_run_original_schema(db);yield db
  need(sha(path.read_bytes())==before,'Readonly review changed SQLite')
 for report in reports:
  size=report['count'];base=root/('n%d'%size);need(json.loads((base/'report.json').read_text())==report and report['librarySchema']==29 and report['incomingRuns']==size and report['incomingObjects']==size+1 and report['recipeUpdates']==1 and report['updatedRuns']==10,'Run coverage differs')
  need(report['batchSize']==128 and sum(b['objects'] for b in report['batches'])==size+1 and all(type(b['objects']) is int and 0<b['objects']<=128 and math.isfinite(b['seconds']) and b['seconds']>=0 for b in report['batches']),'Batch coverage differs')
  for name in ['loadSeconds','outgoingPreparationSeconds','incomingSeconds','runUpdateSeconds']:need(type(report[name]) in [float,int] and math.isfinite(report[name]) and report[name]>=0,'Invalid timer')
  history=report['nativeHistoryWarmMS'];need(report['nativeHistoryLimit']==100 and len(history)==7 and all(type(x) in [float,int] and math.isfinite(x) and x>=0 for x in history),'Native history samples differ')
  old_records=json.loads((base/'before-updates.json').read_bytes());need(len(old_records)==10,'Ten actual pre-update packets required');old={object_digest(r['identity']):encode(r) for r in old_records};need(len(old)==10,'Duplicate pre-update packet')
  with database(base/'producer/memory.sqlite') as producer,database(base/'receiver/memory.sqlite') as receiver:
   packets={};heads={};revisions=producer.execute('SELECT sequence,revision FROM personal_sync_outbox ORDER BY sequence').fetchall();journal_contents=set()
   for _,revision_raw in revisions:
    revision=json.loads(revision_raw)
    if revision['mutation']=='put':journal_contents.add((revision['key']['digest'],revision['content']['sha256'],revision['content']['bytes']))
   sql="SELECT i.object_digest,i.origin,i.lifetime,i.key_frame,v.body,p.content_sha,p.row_digest FROM personal_sync_identities i JOIN personal_sync_version_projection p ON p.object_digest=i.object_digest JOIN personal_sync_versions v ON v.object_digest=p.object_digest AND v.content_sha=p.content_sha WHERE i.table_name='routine_runs'"
   for digest,origin,lifetime,key,raw,content,frame_sha in producer.execute(sql):
    local=m.frames.key_name(key);need(local.startswith('run-'),'Producer key differs');index=int(local[4:]);need(local=='run-%08d'%index and 1<=index<=size,'Producer index differs');packet=json.loads(raw);identity=dict(table='routine_runs',origin=origin,lifetime=lifetime)
    need(m.strict(packet['identity'],identity) and object_digest(identity)==digest and sha(raw)==content and encode(packet)==raw,'Producer typed packet differs')
    native=producer.execute('SELECT '+COLUMNS+' FROM routine_runs WHERE id=?',(local,)).fetchone();need(native is not None and sha(m.frames.frame(native))==frame_sha,'Producer native frame differs');packets[digest]=(index,raw,packet)
    state=producer.execute("SELECT state FROM personal_sync_registers WHERE kind='routineRun' AND digest=?",(digest,)).fetchone();need(state is not None,'Producer register missing');heads[digest]=state[0]
   need(len(packets)==size,'Producer current packet count differs')
   editor=receiver.execute('SELECT revision,enabled,payload FROM routines WHERE id=?',(report['recipeLocal'],)).fetchone();need(editor is not None and editor[:2]==(2,0) and json.loads(editor[2])['prompt']=='New current scale prompt','Current editor differs')
   need(receiver.execute('SELECT count(*) FROM routine_runs').fetchone()==(size,) and receiver.execute('SELECT count(*) FROM routine_run_originals').fetchone()==(size,),'Native/original count differs');seen=set();expected_wire={};definition_cache={}
   for local,payload,frame_sha in receiver.execute('SELECT run_id,payload,native_sha FROM routine_run_originals'):
    original=json.loads(payload);need(encode(original)==payload and set(original)=={'record','definition'},'Original encoding differs');packet=original['record'];digest=object_digest(packet['identity']);need(digest in packets and digest not in seen,'Unexpected/duplicate original');seen.add(digest);index,raw,expected=packets[digest];need(encode(packet)==raw,'Original differs from actual producer packet');body=packet['body']['routineRun']['_0'];recipe=body['recipe'];definition=original['definition'];definition_bytes=encode(definition);reference=recipe['definition']
    need(recipe['ordinal']==1 and reference==dict(bytes=len(definition_bytes),sha256=sha(definition_bytes)) and m.strict(definition['identity'],recipe['routine']),'Exact old recipe reference differs')
    if reference['sha256'] not in definition_cache:
     need(producer.execute('SELECT body FROM personal_sync_versions WHERE content_sha=?',(reference['sha256'],)).fetchall()==[(definition_bytes,)],'Original recipe differs from actual producer');need(definition['body']['routine']['_0']['prompt']=='Original scale prompt '+'x'*1024,'Old prompt replaced by current');definition_cache[reference['sha256']]=definition_bytes
    native=receiver.execute('SELECT '+COLUMNS+' FROM routine_runs WHERE id=?',(local,)).fetchone();need(native is not None and native[1]==report['recipeLocal'] and sha(m.frames.frame(native))==frame_sha,'Native binding differs');need(native[3:6]==(1700000000+index,1700000000+index,1700000001+index) and native[6:9]==('manual','failed',None),'Native dates/status differ')
    need(body['scheduledAt']+978307200==native[3] and body['started']+978307200==native[4] and body['finished']+978307200==native[5] and body['status']=='failed' and body['trigger']=='manual' and body.get('conversation') is None and body.get('message')==native[9] and m.strict(body['filter'],json.loads(native[10])),'Native body differs from wire')
    need(native[9]==('Owned updated run %d'%index if index<=10 else 'Owned initial run %d'%index),'Run message differs')
    primary=m.frames.frame([local]);need(receiver.execute('SELECT local_key,key_frame,origin,lifetime FROM personal_sync_identities WHERE object_digest=?',(digest,)).fetchone()==(hashlib.sha256(primary).digest(),primary,packet['identity']['origin'],packet['identity']['lifetime']),'Global/native identity differs')
    current=receiver.execute("SELECT v.body,p.row_digest FROM personal_sync_version_projection p JOIN personal_sync_versions v ON v.object_digest=p.object_digest AND v.content_sha=p.content_sha WHERE p.object_digest=?",(digest,)).fetchall();need(current==[(raw,frame_sha)],'Current wire/native projection differs')
    recipe_bytes=encode(recipe);need(receiver.execute('SELECT local_key,routine_key,local_revision,recipe,recipe_sha FROM personal_sync_version_runs WHERE object_digest=?',(digest,)).fetchone()==(hashlib.sha256(primary).digest(),hashlib.sha256(m.frames.frame([report['recipeLocal']])).digest(),native[2],recipe_bytes,sha(b'OSwind.sync.run-recipe.v1\0'+recipe_bytes)),'Durable original recipe binding differs')
    need(receiver.execute("SELECT state FROM personal_sync_registers WHERE kind='routineRun' AND digest=?",(digest,)).fetchone()==(heads[digest],),'Exact producer/receiver causal head differs');expected_wire[digest,sha(raw)]=raw
   for digest,raw in old.items():
    need((digest,sha(raw),len(raw)) in journal_contents,'Prior trace does not match an actual producer journal reference')
    index=packets[digest][0];need(1<=index<=10 and json.loads(raw)['body']['routineRun']['_0']['message']=='Owned initial run %d'%index,'Pre-update trace differs');expected_wire[digest,sha(raw)]=raw
   actual={(digest,content):body for digest,content,body in receiver.execute("SELECT object_digest,content_sha,body FROM personal_sync_versions WHERE table_name='routine_runs'")};need(actual==expected_wire,'Current or prior wire membership differs')
   need(receiver.execute('SELECT count(*) FROM personal_sync_versions').fetchone()==(size+12,) and receiver.execute('SELECT count(*) FROM personal_sync_changes').fetchone()==(0,) and receiver.execute('SELECT count(*) FROM personal_sync_outbox').fetchone()==(0,) and receiver.execute('SELECT count(*) FROM personal_sync_pending').fetchone()==(0,),'Version counts or no-echo/pending differs')
   replica=producer.execute('SELECT replica FROM personal_sync_local').fetchone()[0];need(len(revisions)==size+12 and receiver.execute('SELECT cursor FROM personal_sync_peers WHERE replica=?',(replica,)).fetchone()==(size+12,),'Sequence coverage differs');need(receiver.execute('SELECT sequence,digest FROM personal_sync_receipts WHERE replica=? ORDER BY sequence',(replica,)).fetchall()==[(seq,sha(raw)) for seq,raw in revisions],'Actual receipt digests differ')
   need(receiver.execute('SELECT used_bytes FROM personal_sync_version_state').fetchone()[0]==receiver.execute('SELECT (SELECT COALESCE(SUM(bytes+128),0) FROM personal_sync_versions)+(SELECT COUNT(*)*192 FROM personal_sync_version_recipes)+(SELECT COALESCE(SUM(128+length(token)),0) FROM personal_sync_version_sessions)+(SELECT COALESCE(SUM(224+length(recipe)),0) FROM personal_sync_version_runs)').fetchone()[0],'Version accounting differs')
  results.append(dict(count=size,incomingSeconds=report['incomingSeconds'],runUpdateSeconds=report['runUpdateSeconds'],history100MedianMS=statistics.median(history),exactOriginals=size,retainedPriorWireVersions=10,allActualProducerPacketsVerified=True))
 return dict(state='passed',results=results,unchangedSQLiteFiles=pins,scope='One warm metadata run per size; all11000 exact actual producer/current/native/original/recipe bindings and twenty retained pre-update packets, journal receipts and accounting. No models/media/transport/cold-cache/energy/product-ranking acceptance.')
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=pathlib.Path);a=p.parse_args();print(json.dumps(review(a.root),indent=2))
