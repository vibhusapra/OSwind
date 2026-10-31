#!/usr/bin/env python3
"""Meaningful corruption controls on copies of real native benchmark output."""
import argparse,contextlib,importlib.util,json,pathlib,shutil,sqlite3,time
parser=argparse.ArgumentParser(description="Refusal controls against copies of actual closed authored fanout output; originals stay readonly.")
parser.add_argument('root',type=pathlib.Path);parser.add_argument('profile',type=pathlib.Path);parser.add_argument('--output',type=pathlib.Path,required=True);a=parser.parse_args()
base=pathlib.Path(__file__).resolve().parent;profile=a.profile.absolute();source_root=a.root.absolute();assert source_root.resolve()==source_root and source_root.is_dir();source=source_root.parent
spec=importlib.util.spec_from_file_location('controls_reader',base/'review-sync-mutation-fanout.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
work=a.output.absolute();assert work.resolve()==work and work.parent.is_dir() and not work.exists();work.mkdir(mode=0o700)
assert source_root.name=='fanout'
for name in ['fanout','inputs.json','fanout.log']:
 p=source/name;q=work/name
 if p.is_dir():shutil.copytree(p,q)
 else:shutil.copy2(p,q)
root=work/'fanout';pins=m.g.tree(source/'fanout');results=[]
files=[root/'owned-fixture',root/'run.json',root/'report.json',root/'n1000/report.json',work/'fanout.log',root/'n1000/receiver/memory.sqlite',root/'n1000/before-delete.sqlite']
backups={p:p.read_bytes() for p in files}
def restore():
 for p,data in backups.items():p.write_bytes(data)
def receipt(**updates):
 p=root/'run.json';r=json.loads(p.read_text());r.update(updates);p.write_text(json.dumps(r))
def sql(relative,callback):
 with contextlib.closing(sqlite3.connect(root/relative)) as db:
  with db:callback(db)
  db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
def changed_report(change):
 reports=json.loads((root/'report.json').read_text());change(reports);(root/'report.json').write_text(json.dumps(reports));(root/'n1000/report.json').write_text(json.dumps(reports[0]));receipt(reportSHA256=m.g.sha(root/'report.json'))
def barrier(db):
 key,raw=db.execute("SELECT digest,state FROM personal_sync_registers WHERE kind='routineRun' LIMIT 1").fetchone();r=json.loads(raw);r['deletions']={};db.execute('UPDATE personal_sync_registers SET state=? WHERE digest=?',(json.dumps(r),key))
def causality(db):
 seq,raw=db.execute('SELECT sequence,revision FROM personal_sync_outbox WHERE sequence>1000 ORDER BY sequence LIMIT 1').fetchone();r=json.loads(raw);r['context']={};db.execute('UPDATE personal_sync_outbox SET revision=? WHERE sequence=?',(json.dumps(r),seq))
def duplicate(db):
 rows=db.execute('SELECT sequence,revision FROM personal_sync_outbox WHERE sequence>1000 ORDER BY sequence LIMIT 2').fetchall();a=json.loads(rows[0][1]);b=json.loads(rows[1][1]);b['key']=a['key'];db.execute('UPDATE personal_sync_outbox SET revision=? WHERE sequence=?',(json.dumps(b),rows[1][0]))
def cache(db):db.execute("DELETE FROM personal_sync_version_revoked WHERE object_digest=(SELECT digest FROM personal_sync_registers WHERE kind='routineRun' LIMIT 1)")
def native(db):
 triggers=db.execute("SELECT name,sql FROM sqlite_master WHERE type='trigger' AND tbl_name='routine_runs'").fetchall()
 for name,_ in triggers:db.execute('DROP TRIGGER "'+name.replace('"','""')+'"')
 db.execute("UPDATE routine_runs SET message='Different authored input' WHERE id='fanout-00000001'")
 for _,sql in triggers:db.execute(sql)
def index(db):
 db.execute('DROP INDEX IF EXISTS sync_identities_local');db.execute('CREATE INDEX sync_identities_local ON personal_sync_identities(origin)')
def zero():
 p=work/'fanout.log';p.write_text('Executed 0 tests, with 0 failures (0 unexpected)\n');receipt(logSHA256=m.g.sha(p))
cases=[('owned-marker',lambda:(root/'owned-fixture').write_text('other')),('running-driver',lambda:receipt(state='running')),('zero-executed-tests',zero),('nonfinite-timer',lambda:changed_report(lambda r:r[0].update(deletionSeconds=float('nan')))),('missing-size',lambda:changed_report(lambda r:r.pop())),('missing-child-barrier',lambda:sql('n1000/receiver/memory.sqlite',barrier)),('missing-root-causality',lambda:sql('n1000/receiver/memory.sqlite',causality)),('duplicate-child-membership',lambda:sql('n1000/receiver/memory.sqlite',duplicate)),('missing-cache-barrier',lambda:sql('n1000/receiver/memory.sqlite',cache)),('changed-authored-native-input',lambda:sql('n1000/before-delete.sqlite',native)),('altered-lookup-index',lambda:sql('n1000/before-delete.sqlite',index))]
try:
 for name,change in cases:
  restore();change();start=time.monotonic()
  try:m.review(root,profile)
  except (AssertionError,ValueError,KeyError,RuntimeError) as error:
   assert 'Live SQLite journal' not in str(error),str(error)
   if name=='changed-authored-native-input':assert 'Authored native run differs' in str(error),str(error)
   results.append(dict(case=name,state='refused',reason=str(error),seconds=time.monotonic()-start));print(name,str(error),flush=True)
  else:raise AssertionError('Accepted negative control '+name)
 restore();positive=m.review(root,profile);assert positive['state']=='passed';assert m.g.tree(source/'fanout')==pins
 (work/'result.json').write_text(json.dumps(dict(state='passed',negativeControls=results,restoredPositive=positive,originalDatasetUnchanged=True),indent=2)+'\n');print('ALL CONTROLS PASSED',flush=True)
finally:restore()
