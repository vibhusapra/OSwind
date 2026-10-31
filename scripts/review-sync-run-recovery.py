#!/usr/bin/env python3
"""Readonly independent inspection of closed authored run SIGKILL fixtures."""
import argparse,contextlib,hashlib,importlib.util,json,pathlib,sqlite3,struct
path=pathlib.Path(__file__).with_name('review-sync-incoming-routines.py');spec=importlib.util.spec_from_file_location('owned_run_common',path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
need=m.need;encode=m.encode;sha=m.digest
COLUMNS='id,routine_id,revision,scheduled_at,started,finished,trigger,status,chat_id,message,scope'
def review(root):
 root=pathlib.Path(root).absolute();need(root.resolve()==root and root.is_dir() and not root.is_symlink(),'Invalid owned root');need((root/'owned-fixture').read_bytes()==b'OSwind authored incoming source projection v1','Owned marker differs')
 cases=sorted(root.glob('*IncomingRun*Death*'));need(len(cases)==4,'Four distinct crash cases required');observed=set();pins={};results=[]
 @contextlib.contextmanager
 def database(path):
  need(path.resolve()==path and path.is_file() and not path.is_symlink(),'Invalid SQLite path')
  for suffix in ['-wal','-journal']:need(not path.with_name(path.name+suffix).exists() or path.with_name(path.name+suffix).stat().st_size==0,'Library has a live journal')
  before=sha(path.read_bytes());pins[str(path.relative_to(root))]=before
  with contextlib.closing(sqlite3.connect(path.as_uri()+'?mode=ro&immutable=1',uri=True)) as db:
   need(db.execute('PRAGMA user_version').fetchone()==(29,) and db.execute('PRAGMA quick_check').fetchall()==[('ok',)] and db.execute('PRAGMA foreign_key_check').fetchall()==[],'SQLite integrity differs');m.frames.verify_run_original_schema(db);yield db
  need(sha(path.read_bytes())==before,'Readonly review changed SQLite')
 for case in cases:
  state=json.loads((case/'retained-crash/expected.json').read_bytes());action,phase=(case/'retained-crash/ready').read_text().split(':');need(action==state['action'] and action in ['create','update'] and phase in ['before','after'] and (action,phase) not in observed,'Crash identity differs');observed.add((action,phase))
  target,definition=state['target'],state['definition'];operation=state['operation'];target_body=target['body']['routineRun']['_0'];need(target_body['status']==('running' if action=='create' else 'failed'),'Real target transition missing')
  need(operation['content']==dict(bytes=len(encode(target)),sha256=sha(encode(target))) and operation['mutation']=='put' and operation['key']['kind']=='routineRun','Target operation differs')
  old=state.get('old');need((old is not None)==(action=='update'),'Initial/update state differs')
  if old:need(old['body']['routineRun']['_0']['status']=='running' and encode(old)!=encode(target),'Real prior running version missing')
  for label in ['retained-crash','retained-retry']:
   base=case/label;need((base/'expected.json').read_bytes()==(case/'retained-crash/expected.json').read_bytes(),'Retry expectation changed')
   committed=label=='retained-retry' or phase=='after';expected=target if committed else old
   with database(base/'producer/memory.sqlite') as producer,database(base/'receiver/memory.sqlite') as receiver:
    for packet in [target,definition]:need(producer.execute('SELECT body FROM personal_sync_versions WHERE content_sha=?',(sha(encode(packet)),)).fetchall()==[(encode(packet),)],'Expected packet differs from actual producer')
    native=receiver.execute('SELECT '+COLUMNS+' FROM routine_runs').fetchall();originals=receiver.execute('SELECT run_id,payload,native_sha FROM routine_run_originals').fetchall();need(len(native)==len(originals)==(0 if expected is None else 1),'Native/original partial commit')
    need(receiver.execute('SELECT count(*) FROM personal_sync_versions').fetchone()==(state['versions']+int(committed),),'Cached version commit differs')
    need(receiver.execute('SELECT count(*) FROM personal_sync_changes').fetchone()==(0,) and receiver.execute('SELECT count(*) FROM personal_sync_outbox').fetchone()==(state['outbox'],),'Incoming recovery echoed outgoing work')
    editor=receiver.execute('SELECT revision,enabled,payload FROM routines WHERE id=?',(state['recipeLocal'],)).fetchone();need(editor is not None and editor[1]==0 and json.loads(editor[2])['prompt']==state['editorPrompt'],'Editor changed or activated')
    digest=operation['key']['digest'];head=receiver.execute('SELECT state FROM personal_sync_registers WHERE kind=? AND digest=?',('routineRun',digest)).fetchone()
    if expected is None:
     need(head is None and receiver.execute('SELECT count(*) FROM personal_sync_identities WHERE object_digest=?',(digest,)).fetchone()==(0,),'Uncommitted head/identity leaked')
    else:
     native=native[0];run_id,payload,frame_sha=originals[0];original=json.loads(payload);body=expected['body']['routineRun']['_0'];packet=encode(expected);content=dict(bytes=len(packet),sha256=sha(packet))
     need(run_id==state['local']==native[0] and native[1]==state['recipeLocal'] and sha(m.frames.frame(native))==frame_sha,'Native frame binding differs')
     need(encode(original)==payload and m.strict(original,dict(record=expected,definition=definition)),'Original exact run/recipe differs')
     need(body['recipe']['definition']==dict(bytes=len(encode(definition)),sha256=sha(encode(definition))) and definition['body']['routine']['_0']['prompt']=='Original crash recipe prompt','Original recipe retargeted')
     need(native[6]==body['trigger'] and native[7]==('interrupted' if body['status']=='running' else body['status']) and native[8] is None and native[9]==body.get('message'),'Native state differs from wire')
     for index,key in [(3,'scheduledAt'),(4,'started'),(5,'finished')]:need(native[index] is None if key not in body else struct.pack('<d',native[index])==struct.pack('<d',body[key]+978307200),'Native date differs')
     need(receiver.execute("SELECT v.body,p.row_digest FROM personal_sync_version_projection p JOIN personal_sync_versions v ON v.object_digest=p.object_digest AND v.content_sha=p.content_sha WHERE p.object_digest=?",(digest,)).fetchall()==[(packet,frame_sha)],'Projected cache/native binding differs')
     row=receiver.execute('SELECT origin,lifetime,local_key,key_frame FROM personal_sync_identities WHERE object_digest=?',(digest,)).fetchone();primary=m.frames.frame([state['local']]);need(row==(expected['identity']['origin'],expected['identity']['lifetime'],hashlib.sha256(primary).digest(),primary),'Native/global identity differs')
     need(head is not None,'Missing committed register');register=json.loads(head[0]);need(len(register['heads'])==1 and register['heads'][0]['content']==content and register['heads'][0]['key']==operation['key'] and register['deletions']=={},'Journal head differs')
     expected_revision=operation if committed else json.loads(producer.execute("SELECT revision FROM personal_sync_outbox WHERE json_extract(CAST(revision AS TEXT),'$.content.sha256')=?",(content['sha256'],)).fetchone()[0]);need(m.strict(register['heads'][0],expected_revision),'Exact causal head differs');clock=dict(expected_revision['context']);dot=expected_revision['dot'];clock[dot['replica']]=max(clock.get(dot['replica'],0),dot['counter']);need(register['clock']==clock,'Register causal clock differs')
     binding=receiver.execute('SELECT local_key,routine_key,local_revision,recipe,recipe_sha FROM personal_sync_version_runs WHERE object_digest=?',(digest,)).fetchone();recipe_bytes=encode(body['recipe'])
     need(binding==(hashlib.sha256(primary).digest(),hashlib.sha256(m.frames.frame([state['recipeLocal']])).digest(),native[2],recipe_bytes,sha(b'OSwind.sync.run-recipe.v1\0'+recipe_bytes)),'Durable original recipe binding differs')
    if old:need(receiver.execute('SELECT body FROM personal_sync_versions WHERE content_sha=?',(sha(encode(old)),)).fetchall()==[(encode(old),)],'Prior running wire version lost')
    peer=operation['dot']['replica'];cursor=operation['dot']['counter'] if committed else operation['context'].get(peer,0)
    need(receiver.execute('SELECT cursor FROM personal_sync_peers WHERE replica=?',(peer,)).fetchone()==(cursor,) and receiver.execute('SELECT count(*) FROM personal_sync_pending').fetchone()==(0,),'Recovery cursor/pending differs')
    need(receiver.execute('SELECT count(*) FROM personal_sync_receipts WHERE replica=? AND sequence=?',(peer,operation['dot']['counter'])).fetchone()==(int(committed),),'Target receipt partial commit')
    if committed:need(receiver.execute('SELECT digest FROM personal_sync_receipts WHERE replica=? AND sequence=?',(peer,operation['dot']['counter'])).fetchone()==(sha(encode(operation)),),'Target receipt digest differs')
    need(receiver.execute('SELECT used_bytes FROM personal_sync_version_state').fetchone()[0]==receiver.execute('SELECT (SELECT COALESCE(SUM(bytes+128),0) FROM personal_sync_versions)+(SELECT COUNT(*)*192 FROM personal_sync_version_recipes)+(SELECT COALESCE(SUM(128+length(token)),0) FROM personal_sync_version_sessions)+(SELECT COALESCE(SUM(224+length(recipe)),0) FROM personal_sync_version_runs)').fetchone()[0],'Version accounting differs')
   results.append(dict(action=action,phase=phase,state=label,committed=committed,exactOriginal=True,exactCausalHead=True,noEcho=True))
 need(observed=={(a,p) for a in ['create','update'] for p in ['before','after']},'Crash coverage incomplete')
 return dict(state='passed',scope='Four actual owned-worker SIGKILL cases and their retries; readonly closed producer/receiver SQLite, native frames, exact originals/wire versions, journal heads/cursors/receipts, accounting and no echo. Process death, not physical power or full sync acceptance.',results=results,unchangedSQLiteFiles=pins)
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=pathlib.Path);a=p.parse_args();print(json.dumps(review(a.root),indent=2))
