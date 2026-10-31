#!/usr/bin/env python3
"""Corruption controls on copied, closed, explicitly owned routine output."""
import argparse,contextlib,importlib.util,json,pathlib,shutil,sqlite3,tempfile
path=pathlib.Path(__file__).with_name('review-sync-incoming-routines.py');spec=importlib.util.spec_from_file_location('owned_run_oracle',path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
def controls(original):
 result=m.review(original);checks=[]
 with tempfile.TemporaryDirectory(prefix='owned-run-oracle-') as temporary:
  root=pathlib.Path(temporary).resolve()/'owned';root.mkdir();shutil.copy2(original/'owned-fixture',root/'owned-fixture')
  case='-_SyncIncomingSourceTests_testIncomingRunKeepsOriginalRecipeAndSafeInterruptedStatusAcrossRecipeUpdate_';shutil.copytree(original/case,root/case)
  database=root/case/'receiver/memory.sqlite';saved=pathlib.Path(temporary).resolve()/'saved.sqlite';shutil.copy2(database,saved)
  def refuse(name):
   try:m.review(root)
   except (ValueError,OSError,sqlite3.Error,KeyError,TypeError,IndexError):checks.append(name)
   else:raise AssertionError('Corruption admitted: '+name)
  def mutate(action):
   with contextlib.closing(sqlite3.connect(database)) as db:action(db);db.commit();db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
  def restore():shutil.copy2(saved,database)
  marker=root/'owned-fixture';marker.write_bytes(b'normal history');refuse('unmarked fixture');marker.write_bytes(b'OSwind authored incoming source projection v1')
  mutate(lambda db:db.execute('DROP TRIGGER run_original_writer_routine_runs_update'));refuse('missing writer fence');restore()
  mutate(lambda db:db.execute('DROP TRIGGER routine_original_delete'));refuse('missing original deletion guard');restore()
  def original_edit(db,change):
   sql=db.execute("SELECT sql FROM sqlite_master WHERE name='routine_original_immutable'").fetchone()[0];db.execute('DROP TRIGGER routine_original_immutable');db.create_function('oswind_run_original_writer_v1',0,lambda:1);change(db);db.execute(sql)
  mutate(lambda db:original_edit(db,lambda db:db.execute("UPDATE routine_run_originals SET native_sha=?",('0'*64,))));refuse('forged native fingerprint');restore()
  def recipe(db):
   original=json.loads(db.execute('SELECT payload FROM routine_run_originals').fetchone()[0]);original['definition']['body']['routine']['_0']['prompt']='New current prompt'
   definition=m.encode(original['definition']);original['record']['body']['routineRun']['_0']['recipe']['definition']={'sha256':m.digest(definition),'bytes':len(definition)}
   db.execute('UPDATE routine_run_originals SET payload=?',(m.encode(original),))
  mutate(lambda db:original_edit(db,recipe));refuse('retargeted original recipe with recomputed content reference');restore()
  def native(db):
   triggers=db.execute("SELECT name,sql FROM sqlite_master WHERE type='trigger' AND tbl_name='routine_runs'").fetchall()
   for name,_ in triggers:db.execute('DROP TRIGGER '+name)
   db.execute("UPDATE routine_runs SET message='Forged native correction'")
   for _,sql in triggers:db.execute(sql)
  mutate(native);refuse('changed native frame with original payload intact');restore()
  mutate(lambda db:db.execute("DELETE FROM personal_sync_versions WHERE table_name='routine_runs' AND json_extract(CAST(body AS TEXT),'$.body.routineRun._0.status')='running'"));refuse('missing historical running wire version');restore()
  assert m.review(root)['wireVersions']==result['wireVersions']
 assert m.review(original)['unchangedSQLiteFiles']==result['unchangedSQLiteFiles']
 return dict(state='passed',controls=checks,originalSQLiteFilesUnchanged=True)
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=pathlib.Path);a=p.parse_args();print(json.dumps(controls(a.root),indent=2))
