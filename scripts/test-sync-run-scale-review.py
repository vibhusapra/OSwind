#!/usr/bin/env python3
"""Admission and corruption controls on copied, closed, authored run scales."""
import argparse,contextlib,copy,hashlib,importlib.util,json,pathlib,shutil,sqlite3,tempfile
p=pathlib.Path(__file__).with_name('review-sync-run-scale.py');spec=importlib.util.spec_from_file_location('owned_run_scale_oracle',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
def controls(original):
 baseline=m.review(original);checks=[]
 with tempfile.TemporaryDirectory(prefix='owned-run-scale-review-') as temporary:
  parent=pathlib.Path(temporary).resolve();root=parent/'owned';shutil.copytree(original,root)
  run=json.loads((root/'run.json').read_text());log=parent/run['logName'];inputs=parent/'inputs.json';shutil.copy2(original.parent/run['logName'],log);shutil.copy2(original.parent/'inputs.json',inputs)
  original_run=(root/'run.json').read_bytes();original_log=log.read_bytes();original_inputs=inputs.read_bytes();original_report=(root/'report.json').read_bytes();per=root/'n1000/report.json';original_per=per.read_bytes()
  database=root/'n1000/receiver/memory.sqlite';saved=parent/'saved.sqlite';shutil.copy2(database,saved)
  def write_run(value): (root/'run.json').write_text(json.dumps(value))
  def refuse(name):
   try:m.review(root)
   except (ValueError,OSError,sqlite3.Error,KeyError,TypeError,IndexError):checks.append(name)
   else:raise AssertionError('Run-scale corruption admitted: '+name)
  def mutate(fn):
   with contextlib.closing(sqlite3.connect(database)) as db:fn(db);db.commit();db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
  def restore():shutil.copy2(saved,database)
  marker=root/'owned-fixture';marker.write_bytes(b'normal history');refuse('unmarked fixture');marker.write_bytes(b'OSwind authored incoming run scale v1')
  changed=copy.deepcopy(run);changed['state']='running';write_run(changed);refuse('incomplete driver');(root/'run.json').write_bytes(original_run)
  log.write_text('Executed 0 tests, with 0 failures (0 unexpected)\n');changed=copy.deepcopy(run);changed['logSHA256']=m.sha(log.read_bytes());write_run(changed);refuse('zero-test substitution with recomputed log hash');log.write_bytes(original_log);(root/'run.json').write_bytes(original_run)
  source=json.loads(original_inputs);source['Sources/OSwindCore/MemoryStore.swift']='0'*64;inputs.write_text(json.dumps(source));changed=copy.deepcopy(run);changed['sourceInputsSHA256']=m.sha(inputs.read_bytes());write_run(changed);refuse('changed compiled input with recomputed manifest pin');inputs.write_bytes(original_inputs);(root/'run.json').write_bytes(original_run)
  report=json.loads(original_report);report[0]['incomingSeconds']=float('nan');(root/'report.json').write_text(json.dumps(report));per.write_text(json.dumps(report[0]));changed=copy.deepcopy(run);changed['reportSHA256']=m.sha((root/'report.json').read_bytes());write_run(changed);refuse('nonfinite incoming timer with recomputed report pin');(root/'report.json').write_bytes(original_report);per.write_bytes(original_per);(root/'run.json').write_bytes(original_run)
  trace=root/'n1000/before-updates.json';original_trace=trace.read_bytes();old_values=json.loads(original_trace);old_raw=m.encode(old_values[0]);old_values[0]['body']['routineRun']['_0']['filter']['limit']+=1;forged_raw=m.encode(old_values[0]);assert len(old_raw)==len(forged_raw);trace.write_bytes(m.encode(old_values))
  def forged_prior(db):
   sql=db.execute("SELECT sql FROM sqlite_master WHERE name='sync_versions_immutable'").fetchone()[0];db.execute('DROP TRIGGER sync_versions_immutable');db.execute('UPDATE personal_sync_versions SET content_sha=?,body=? WHERE content_sha=?',(m.sha(forged_raw),forged_raw,m.sha(old_raw)));db.execute(sql)
  mutate(forged_prior);refuse('forged prior wire and matching trace with valid current state');restore();trace.write_bytes(original_trace)
  mutate(lambda db:db.execute('DROP TRIGGER run_original_writer_routine_runs_update'));refuse('missing native run writer fence');restore()
  def edit_original(db,fn):
   sql=db.execute("SELECT sql FROM sqlite_master WHERE name='routine_original_immutable'").fetchone()[0];db.execute('DROP TRIGGER routine_original_immutable');db.create_function('oswind_run_original_writer_v1',0,lambda:1);fn(db);db.execute(sql)
  def recipe(db):
   local,payload=db.execute('SELECT run_id,payload FROM routine_run_originals LIMIT 1').fetchone();value=json.loads(payload);value['definition']['body']['routine']['_0']['prompt']='New current scale prompt';raw=m.encode(value['definition']);value['record']['body']['routineRun']['_0']['recipe']['definition']=dict(bytes=len(raw),sha256=m.sha(raw));db.execute('UPDATE routine_run_originals SET payload=? WHERE run_id=?',(m.encode(value),local))
  mutate(lambda db:edit_original(db,recipe));refuse('retargeted original recipe with recomputed reference');restore()
  def native(db):
   triggers=db.execute("SELECT name,sql FROM sqlite_master WHERE type='trigger' AND tbl_name='routine_runs'").fetchall()
   for name,_ in triggers:db.execute('DROP TRIGGER '+name)
   local=db.execute('SELECT id FROM routine_runs LIMIT 1').fetchone()[0];db.execute("UPDATE routine_runs SET message='Forged native correction' WHERE id=?",(local,))
   for _,sql in triggers:db.execute(sql)
   row=db.execute('SELECT '+m.COLUMNS+' FROM routine_runs WHERE id=?',(local,)).fetchone();fingerprint=m.sha(m.m.frames.frame(row));edit_original(db,lambda db:db.execute('UPDATE routine_run_originals SET native_sha=? WHERE run_id=?',(fingerprint,local)));db.execute('UPDATE personal_sync_version_projection SET row_digest=? WHERE object_digest=(SELECT object_digest FROM personal_sync_identities WHERE table_name=\'routine_runs\' AND key_frame=?)',(fingerprint,m.m.frames.frame([local])))
  mutate(native);refuse('native correction with recomputed frame bindings');restore()
  def binding(db):
   sql=db.execute("SELECT sql FROM sqlite_master WHERE name='sync_runs_immutable'").fetchone()[0];db.execute('DROP TRIGGER sync_runs_immutable');digest,raw=db.execute('SELECT object_digest,recipe FROM personal_sync_version_runs LIMIT 1').fetchone();recipe=json.loads(raw);recipe['ordinal']=2;encoded=m.encode(recipe);db.execute('UPDATE personal_sync_version_runs SET recipe=?,recipe_sha=? WHERE object_digest=?',(encoded,m.sha(b'OSwind.sync.run-recipe.v1\0'+encoded),digest));db.execute(sql)
  mutate(binding);refuse('retargeted durable run recipe with recomputed checksum');restore()
  old=json.loads((root/'n1000/before-updates.json').read_bytes())[0];mutate(lambda db:db.execute('DELETE FROM personal_sync_versions WHERE content_sha=?',(m.sha(m.encode(old)),)));refuse('missing exact pre-update wire version');restore()
  mutate(lambda db:db.execute("UPDATE personal_sync_receipts SET digest=? WHERE (replica,sequence) IN (SELECT replica,sequence FROM personal_sync_receipts WHERE sequence>0 LIMIT 1)",('0'*64,)));refuse('forged receipt digest');restore()
  assert m.review(root)['results']==baseline['results']
 assert m.review(original)['unchangedSQLiteFiles']==baseline['unchangedSQLiteFiles']
 return dict(state='passed',controls=checks,all4OriginalSQLiteFilesUnchanged=True)
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=pathlib.Path);a=p.parse_args();print(json.dumps(controls(a.root),indent=2))
