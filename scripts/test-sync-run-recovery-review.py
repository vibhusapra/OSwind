#!/usr/bin/env python3
"""Negative controls against copied authored closed run-recovery output."""
import argparse,contextlib,importlib.util,json,pathlib,shutil,sqlite3,tempfile
p=pathlib.Path(__file__).with_name('review-sync-run-recovery.py');spec=importlib.util.spec_from_file_location('owned_recovery_oracle',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
def controls(original):
 baseline=m.review(original);checks=[]
 with tempfile.TemporaryDirectory(prefix='owned-run-recovery-review-') as temporary:
  root=pathlib.Path(temporary).resolve()/'owned';root.mkdir();shutil.copy2(original/'owned-fixture',root/'owned-fixture')
  for case in original.glob('*IncomingRun*Death*'):shutil.copytree(case,root/case.name)
  case=next(root.glob('*UpdateDeathAfter*'))/'retained-crash';database=case/'receiver/memory.sqlite';saved=pathlib.Path(temporary).resolve()/'saved.sqlite';shutil.copy2(database,saved);state=json.loads((case/'expected.json').read_text())
  def refuse(name):
   try:m.review(root)
   except (ValueError,OSError,sqlite3.Error,KeyError,TypeError,IndexError):checks.append(name)
   else:raise AssertionError('Recovery corruption admitted: '+name)
  def mutate(fn):
   with contextlib.closing(sqlite3.connect(database)) as db:fn(db);db.commit();db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
  def restore():shutil.copy2(saved,database)
  marker=root/'owned-fixture';marker.write_bytes(b'normal history');refuse('unmarked fixture');marker.write_bytes(b'OSwind authored incoming source projection v1')
  def head(db):
   data=json.loads(db.execute("SELECT state FROM personal_sync_registers WHERE kind='routineRun'").fetchone()[0]);data['heads']=[];db.execute("UPDATE personal_sync_registers SET state=? WHERE kind='routineRun'",(m.encode(data),))
  mutate(head);refuse('missing committed causal head');restore()
  mutate(lambda db:db.execute('UPDATE personal_sync_peers SET cursor=cursor-1 WHERE replica=?',(state['operation']['dot']['replica'],)));refuse('rolled-back cursor with committed native row');restore()
  mutate(lambda db:db.execute('UPDATE personal_sync_receipts SET digest=? WHERE replica=? AND sequence=?',('0'*64,state['operation']['dot']['replica'],state['operation']['dot']['counter'])));refuse('forged target receipt digest');restore()
  def clock(db):
   data=json.loads(db.execute("SELECT state FROM personal_sync_registers WHERE kind='routineRun'").fetchone()[0]);data['clock'][state['operation']['dot']['replica']]+=1;db.execute("UPDATE personal_sync_registers SET state=? WHERE kind='routineRun'",(m.encode(data),))
  mutate(clock);refuse('forged causal clock with exact head intact');restore()
  def binding(db):
   sql=db.execute("SELECT sql FROM sqlite_master WHERE name='sync_runs_immutable'").fetchone()[0];db.execute('DROP TRIGGER sync_runs_immutable');recipe=json.loads(db.execute('SELECT recipe FROM personal_sync_version_runs').fetchone()[0]);recipe['ordinal']=2;raw=m.encode(recipe);db.execute('UPDATE personal_sync_version_runs SET recipe=?,recipe_sha=?',(raw,m.sha(b'OSwind.sync.run-recipe.v1\0'+raw)));db.execute(sql)
  mutate(binding);refuse('retargeted durable recipe with recomputed checksum');restore()
  mutate(lambda db:db.execute('DELETE FROM personal_sync_receipts WHERE replica=? AND sequence=?',(state['operation']['dot']['replica'],state['operation']['dot']['counter'])));refuse('missing committed target receipt');restore()
  mutate(lambda db:db.execute('DELETE FROM personal_sync_versions WHERE content_sha=?',(m.sha(m.encode(state['old'])),)));refuse('missing prior running wire version');restore()
  def native(db):
   triggers=db.execute("SELECT name,sql FROM sqlite_master WHERE type='trigger' AND tbl_name='routine_runs'").fetchall()
   for name,_ in triggers:db.execute('DROP TRIGGER '+name)
   db.execute("UPDATE routine_runs SET message='Forged native correction'")
   for _,sql in triggers:db.execute(sql)
   row=db.execute('SELECT '+m.COLUMNS+' FROM routine_runs').fetchone();fingerprint=m.sha(m.m.frames.frame(row))
   immutable=db.execute("SELECT sql FROM sqlite_master WHERE name='routine_original_immutable'").fetchone()[0];db.execute('DROP TRIGGER routine_original_immutable');db.create_function('oswind_run_original_writer_v1',0,lambda:1);db.execute('UPDATE routine_run_originals SET native_sha=?',(fingerprint,));db.execute(immutable);db.execute('UPDATE personal_sync_version_projection SET row_digest=? WHERE object_digest=?',(fingerprint,state['operation']['key']['digest']))
  mutate(native);refuse('changed native message with recomputed frame hashes');restore()
  mutate(lambda db:db.execute('DROP TRIGGER routine_original_delete'));refuse('missing original deletion guard');restore()
  assert m.review(root)['results']==baseline['results']
 assert m.review(original)['unchangedSQLiteFiles']==baseline['unchangedSQLiteFiles']
 return dict(state='passed',controls=checks,all16OriginalSQLiteFilesUnchanged=True)
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=pathlib.Path);a=p.parse_args();print(json.dumps(controls(a.root),indent=2))
