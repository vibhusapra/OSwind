#!/usr/bin/env python3
"""Independent readonly review of closed, explicitly authored routine fixtures."""
import argparse,contextlib,hashlib,importlib.util,json,pathlib,sqlite3,struct
helper=pathlib.Path(__file__).with_name('review-sync-identity-scale.py')
spec=importlib.util.spec_from_file_location('owned_run_frame_reader',helper);frames=importlib.util.module_from_spec(spec);spec.loader.exec_module(frames)

def need(value,message):
 if not value:raise ValueError(message)
def digest(data):return hashlib.sha256(data).hexdigest()
def encode(value):return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()
def strict(value,expected):
 if type(value) is not type(expected):return False
 if type(value) is dict:return value.keys()==expected.keys() and all(strict(v,expected[k]) for k,v in value.items())
 if type(value) is list:return len(value)==len(expected) and all(strict(a,b) for a,b in zip(value,expected))
 return value==expected

def review(root):
 root=pathlib.Path(root).absolute();need(root.resolve()==root and root.is_dir() and not root.is_symlink(),'Invalid owned fixture root')
 need((root/'owned-fixture').read_bytes()==b'OSwind authored incoming source projection v1','Owned marker differs')
 case=root/'-_SyncIncomingSourceTests_testIncomingRunKeepsOriginalRecipeAndSafeInterruptedStatusAcrossRecipeUpdate_';pins={}
 @contextlib.contextmanager
 def database(name):
  path=case/name/'memory.sqlite';need(path.resolve()==path and path.is_file() and not path.is_symlink(),'Invalid owned SQLite path')
  for suffix in ['-wal','-journal']:need(not path.with_name(path.name+suffix).exists() or path.with_name(path.name+suffix).stat().st_size==0,'Owned library is not closed')
  before=digest(path.read_bytes());pins[str(path.relative_to(root))]=before
  with contextlib.closing(sqlite3.connect(path.as_uri()+'?mode=ro&immutable=1',uri=True)) as db:
   need(db.execute('PRAGMA user_version').fetchone()==(29,) and db.execute('PRAGMA quick_check').fetchall()==[('ok',)] and db.execute('PRAGMA foreign_key_check').fetchall()==[],'SQLite integrity differs');frames.verify_run_original_schema(db)
   yield db
  need(digest(path.read_bytes())==before,'Readonly inspection changed SQLite')
 with database('producer') as producer,database('receiver') as receiver:
  originals=receiver.execute('SELECT run_id,payload,native_sha FROM routine_run_originals').fetchall();need(len(originals)==1,'Expected one admitted original')
  run_id,payload,native_sha=originals[0];original=json.loads(payload);need(set(original)=={'record','definition'} and encode(original)==payload,'Original encoding differs')
  record,definition=original['record'],original['definition'];body=record['body']['routineRun']['_0'];recipe=definition['body']['routine']['_0']
  need(record['identity']['table']=='routine_runs' and definition['identity']['table']=='routines' and strict(definition['identity'],body['recipe']['routine']),'Original identity differs')
  need(body['recipe']['ordinal']==1 and body['status']=='failed' and recipe['prompt']=='Original recorded prompt','Original recipe or status differs')
  packet=producer.execute("SELECT body FROM personal_sync_versions WHERE content_sha=?",(digest(encode(record)),)).fetchall();need(packet==[(encode(record),)],'Original run differs from actual producer bytes')
  need(body['recipe']['definition']=={'sha256':digest(encode(definition)),'bytes':len(encode(definition))},'Exact recipe reference differs')
  need(producer.execute('SELECT body FROM personal_sync_versions WHERE content_sha=?',(body['recipe']['definition']['sha256'],)).fetchall()==[(encode(definition),)],'Recipe differs from actual producer bytes')
  columns='id,routine_id,revision,scheduled_at,started,finished,trigger,status,chat_id,message,scope';native=receiver.execute('SELECT '+columns+' FROM routine_runs WHERE id=?',(run_id,)).fetchone()
  need(native is not None and digest(frames.frame(native))==native_sha,'Actual eleven-cell native run binding differs')
  need(native[2]==1 and native[6]==body['trigger'] and native[7]=='failed' and native[8] is None and native[9]==body['message'],'Native run fields differ')
  for index,key in [(3,'scheduledAt'),(4,'started'),(5,'finished')]:need(struct.pack('<d',native[index])==struct.pack('<d',body[key]+978307200),'Native run date differs')
  current=receiver.execute('SELECT revision,enabled,payload FROM routines WHERE id=?',(native[1],)).fetchone();need(current is not None and current[:2]==(2,0) and json.loads(current[2])['prompt']=='New current prompt','Current recipe differs')
  for raw, in receiver.execute('SELECT body FROM personal_sync_versions WHERE table_name=\'routine_runs\''):
   cached=json.loads(raw);need(strict(cached['identity'],record['identity']) and strict(cached['body']['routineRun']['_0']['recipe'],body['recipe']),'Historical run recipe changed')
  need(receiver.execute("SELECT count(*) FROM personal_sync_versions WHERE table_name='routine_runs'").fetchone()==(2,),'Old running wire version was not retained')
  need(receiver.execute('SELECT count(*) FROM personal_sync_changes').fetchone()==(0,) and receiver.execute('SELECT count(*) FROM personal_sync_outbox').fetchone()==(0,),'Incoming run echoed outgoing work')
  projected=receiver.execute("SELECT v.body FROM personal_sync_version_projection p JOIN personal_sync_versions v ON v.object_digest=p.object_digest AND v.content_sha=p.content_sha WHERE v.table_name='routine_runs'").fetchall();need(projected==[(encode(record),)],'Current wire binding differs')
 return dict(state='passed',scope='One owned two-library real producer sequence; current editor v2, original run recipe v1, old running and current failed wire records, native eleven-cell frame, exact recipe content, timestamps and no echo. Readonly; no transport, execution, model, energy or ranking claim.',originalRuns=1,wireVersions=2,unchangedSQLiteFiles=pins)
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=pathlib.Path);a=p.parse_args();print(json.dumps(review(a.root),indent=2))
