#!/usr/bin/env python3
"""Negative controls against copied, closed, explicitly owned scale output."""
import argparse,contextlib,copy,importlib.util,json,pathlib,shutil,sqlite3,tempfile
p=argparse.ArgumentParser();p.add_argument('root',type=pathlib.Path);a=p.parse_args()
reader=pathlib.Path(__file__).with_name('review-sync-incoming-source-scale.py');spec=importlib.util.spec_from_file_location('owned_incoming_oracle',reader);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
original=m.review(a.root);checks=[]
with tempfile.TemporaryDirectory(prefix='oswind-incoming-oracle-') as temporary:
 root=pathlib.Path(temporary).resolve()/'owned';shutil.copytree(a.root,root)
 reports=json.loads((root/'report.json').read_text());per=root/'n1000/report.json';database=root/'n1000/receiver/memory.sqlite';saved=pathlib.Path(temporary).resolve()/'saved.sqlite';shutil.copy2(database,saved)
 def write(value):
  (root/'report.json').write_text(json.dumps(value));per.write_text(json.dumps(value[0]))
 def refuses(name):
  try:m.review(root)
  except (ValueError,OSError,sqlite3.Error,KeyError,TypeError,IndexError):checks.append(name)
  else:raise AssertionError('Corruption admitted: '+name)
 def mutate(action):
  with contextlib.closing(sqlite3.connect(database)) as db:
   action(db);db.commit();db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
 def restore():shutil.copy2(saved,database)
 changed=copy.deepcopy(reports);changed[0]['incomingObjects']=0;write(changed);refuses('unrun incoming phase');write(reports)
 changed=copy.deepcopy(reports);changed[0]['incomingSeconds']=float('nan');write(changed);refuses('nonfinite incoming timer');write(reports)
 marker=root/'owned-fixture';marker.write_bytes(b'normal history');refuses('unmarked corpus');marker.write_bytes(b'OSwind authored incoming source scale v1')
 mutate(lambda db:db.execute("DROP TRIGGER incoming_source_writer_memories_delete"));refuses('missing source writer protection');restore()
 mutate(lambda db:db.execute("UPDATE personal_sync_version_projection SET row_digest=? WHERE object_digest=(SELECT object_digest FROM personal_sync_version_projection LIMIT 1)",('0'*64,)));refuses('forged current native frame binding');restore()
 mutate(lambda db:db.execute('DELETE FROM historical_evidence_dependencies WHERE (child,parent) IN (SELECT child,parent FROM historical_evidence_dependencies LIMIT 1)'));refuses('missing archival parent edge');restore()
 def projection(db):
  sql=db.execute("SELECT sql FROM sqlite_master WHERE name='historical_immutable'").fetchone()[0]
  for marker in ['oswind_historical_writer_v1','oswind_historical_scope_writer_v1','oswind_incoming_source_writer_v1']:db.create_function(marker,0,lambda:1)
  db.execute('DROP TRIGGER historical_immutable');db.execute('UPDATE historical_evidence SET projection_sha=? WHERE handle=(SELECT handle FROM historical_evidence LIMIT 1)',('0'*64,));db.execute(sql)
 mutate(projection);refuses('forged original native projection');restore()
 def pin(db):
  memory,old=db.execute('SELECT memory_id,handle FROM historical_evidence_pins LIMIT 1').fetchone();other=db.execute('SELECT handle FROM historical_evidence WHERE source_id<>? LIMIT 1',(memory,)).fetchone()[0];assert old!=other
  db.execute('UPDATE historical_evidence_pins SET handle=? WHERE memory_id=?',(other,memory))
 mutate(pin);refuses('retargeted pin with valid independent foreign keys');restore()
 assert m.review(root)['results']==original['results']
assert m.review(a.root)['unchangedProducerAndReceiverSQLiteFiles']==original['unchangedProducerAndReceiverSQLiteFiles']
print(json.dumps(dict(state='passed',controls=checks,originalFixturesUnchanged=True),indent=2))
