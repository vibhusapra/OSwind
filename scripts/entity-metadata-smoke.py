#!/usr/bin/env python3
"""Owned project metadata preservation and optional paired old/new observations.

Only generated text is imported. Roots must not exist. Timings include CLI startup,
SQLite and extraction/resume with uncontrolled caches; no power/competitor claim.
"""
from owned_sqlite_fixture import register_inactive_sync_fixture
import argparse,contextlib,hashlib,json,pathlib,sqlite3,statistics,subprocess,time
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary',type=pathlib.Path);p.add_argument('--root',required=True,type=pathlib.Path);p.add_argument('--baseline-cli',type=pathlib.Path);p.add_argument('--sources',type=int,default=1000);p.add_argument('--repetitions',type=int,default=3);a=p.parse_args()
assert 3<=a.sources<=100000 and 1<=a.repetitions<=10
root=a.root.resolve();root.mkdir(mode=0o700,parents=True,exist_ok=False)
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
rows=[dict(id=f'owned-{i:06d}',timestamp='2026-10-24T12:00:00Z',kind='note',app='Owned metadata fixture',bundleID='org.oswind.entity-metadata',title=f'Synthetic source {i}',text=f'Apollo Launch is the owned project. Synthetic record {i}.',tags=[],favorite=False,regions=[]) for i in range(a.sources)]
inputFile=root/'sources.json';inputFile.write_text(json.dumps(rows));results=[]
def qualify(label,binary,preserves):
 binary=binary.resolve();library=root/label/'library';library.parent.mkdir(mode=0o700)
 def cmd(*args,data=library):
  result=subprocess.run([str(binary),'--data',str(data),*map(str,args)],capture_output=True,text=True,timeout=180);assert result.returncode==0,result.stderr
  return json.loads(result.stdout) if result.stdout.strip() else None
 def snapshot(data=library):
  with contextlib.closing(sqlite3.connect(data/'memory.sqlite')) as db:
   revision=db.execute("SELECT value FROM store_metadata WHERE key='entity_rules_revision'").fetchone()[0]
   anchors=list(db.execute("SELECT memory_id,origin,revision,start,length,surface,method FROM entity_mentions WHERE entity_id=? AND origin='automatic' ORDER BY memory_id",(project['id'],)))
   manual=db.execute("SELECT COUNT(*) FROM entity_mentions WHERE entity_id=? AND origin='manual'",(project['id'],)).fetchone()[0]
   ignored=db.execute('SELECT COUNT(*) FROM entity_ignored WHERE memory_id=?',(rows[-1]['id'],)).fetchone()[0]
   if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='entity_project_ignored'").fetchone():ignored+=db.execute('SELECT COUNT(*) FROM entity_project_ignored WHERE memory_id=?',(rows[-1]['id'],)).fetchone()[0]
   return dict(revision=revision,automatic=len(anchors),manual=manual,ignored=ignored,anchorSHA256=hashlib.sha256(json.dumps(anchors,separators=(',',':')).encode()).hexdigest())
 assert cmd('import',inputFile,'--json')['imported']==a.sources
 project=cmd('entity','create','project','Apollo Launch')
 cmd('entity','link',project['id'],rows[0]['id']);assert cmd('entity','index')['indexed']==a.sources
 cmd('entity','unlink',project['id'],rows[-1]['id']);initial=snapshot();assert initial['automatic']==a.sources-1 and initial['manual']==initial['ignored']==1
 trials=[]
 for i in range(a.repetitions):
  before=snapshot();start=time.monotonic();edited=cmd('entity','edit',project['id'],'--notes',f'Owned notes revision {i}');editSeconds=time.monotonic()-start;after=snapshot();progress=cmd('entity','progress')
  assert edited['detail']==f'Owned notes revision {i}' and after['manual']==after['ignored']==1
  assert (after['revision']==before['revision']) is preserves
  assert progress['indexed']==(a.sources if preserves else 0)
  assert after['automatic']==(a.sources-1 if preserves else 0)
  if preserves:assert after['anchorSHA256']==before['anchorSHA256']
  start=time.monotonic();resumed=cmd('entity','index');resumeSeconds=time.monotonic()-start;assert resumed['indexed']==a.sources
  assert snapshot()['anchorSHA256']==initial['anchorSHA256']
  trials.append(dict(editWallSeconds=editSeconds,resumeWallSeconds=resumeSeconds,totalWallSeconds=editSeconds+resumeSeconds,pendingSourcesAfterEdit=progress['eligible']-progress['indexed'],automaticLinksAfterEdit=after['automatic'],manualLinksAfterEdit=after['manual'],rejectedSourceStillSuppressed=True))
 # A genuine alias addition still invalidates completion and clears only
 # automatic links. The unused alias does not change the authored membership.
 before=snapshot();cmd('entity','edit',project['id'],'--aliases','Apollo Launch,UNUSED-METADATA-RULE-42');changed=snapshot();assert changed['revision']!=before['revision'] and changed['automatic']==0 and changed['manual']==1
 assert cmd('entity','progress')['indexed']==0;assert cmd('entity','index')['indexed']==a.sources;assert snapshot()['anchorSHA256']==initial['anchorSHA256']
 archive=library.parent/'archive.oswindbackup';restored=library.parent/'restored'
 subprocess.run([str(binary),'--data',str(library),'backup','create',str(archive)],capture_output=True,check=True,timeout=180)
 subprocess.run([str(binary),'backup','restore',str(archive),'--to',str(restored)],capture_output=True,check=True,timeout=180)
 assert snapshot(restored)['anchorSHA256']==initial['anchorSHA256'];assert cmd('entity','progress',data=restored)['indexed']==0
 restoredProject=next(v for v in cmd('entity','list',data=restored) if v['id']==project['id']);assert restoredProject['detail']==f'Owned notes revision {a.repetitions-1}'
 assert set(restoredProject['aliases'])=={'Apollo Launch','UNUSED-METADATA-RULE-42'}
 assert not json.loads((restored/'settings.json').read_text())['entityAutomaticIndex']
 assert cmd('entity','index',data=restored)['indexed']==a.sources and snapshot(restored)['anchorSHA256']==initial['anchorSHA256']
 # Restores may contain an uncurated project. Completing a plan without it
 # and subsequently curating it adds rules, even with identical aliases/name.
 with contextlib.closing(sqlite3.connect(restored/'memory.sqlite')) as db:
  register_inactive_sync_fixture(db)
  db.execute('UPDATE memory_entities SET curated=0 WHERE id=?',(project['id'],))
  db.execute("DELETE FROM entity_mentions WHERE entity_id=? AND origin='automatic'",(project['id'],));db.commit()
 uncuratedArchive=library.parent/'uncurated.oswindbackup'
 subprocess.run([str(binary),'--data',str(restored),'backup','create',str(uncuratedArchive)],capture_output=True,check=True,timeout=180)
 for action in ['edit','create']:
  data=library.parent/('uncurated-restored-'+action)
  subprocess.run([str(binary),'backup','restore',str(uncuratedArchive),'--to',str(data)],capture_output=True,check=True,timeout=180)
  assert not next(v for v in cmd('entity','list',data=data) if v['id']==project['id'])['curated']
  assert cmd('entity','index',data=data)['indexed']==a.sources and snapshot(data)['automatic']==0
  before=snapshot(data)
  if action=='edit':cmd('entity','edit',project['id'],'--notes','Activate restored project',data=data)
  else:cmd('entity','create','project','Apollo Launch','--notes','Activate restored project',data=data)
  assert snapshot(data)['revision']!=before['revision'] and cmd('entity','progress',data=data)['indexed']==0
  assert cmd('entity','index',data=data)['indexed']==a.sources and snapshot(data)['anchorSHA256']==initial['anchorSHA256']
 return dict(label=label,binarySHA256=sha(binary),metadataPreserved=preserves,trials=trials,medianEditWallSeconds=statistics.median(v['editWallSeconds'] for v in trials),medianResumeWallSeconds=statistics.median(v['resumeWallSeconds'] for v in trials),medianTotalWallSeconds=statistics.median(v['totalWallSeconds'] for v in trials),checks=['source anchors unchanged after resume','manual link retained','rejected automatic source remains suppressed','real alias change invalidates completion/automatic links','quiet full backup preserves edited definitions and memberships','restored completion resets and resumed extraction retains correction','restored uncurated project activation by edit/create invalidates its completed plan'])
if a.baseline_cli:results.append(qualify('baseline',a.baseline_cli,False))
results.append(qualify('candidate',a.binary,True))
report=dict(format='OSwind project metadata preservation observations v1',passed=True,sources=a.sources,repetitions=a.repetitions,syntheticInputSHA256=sha(inputFile),harnessSHA256=sha(pathlib.Path(__file__)),results=results,scope='Owned short synthetic sources and project metadata/alias/correction/backup contracts. Sequential CLI trials include startup, SQLite and extraction/resume with uncontrolled caches and host activity. Required rescan counts are exact for this fixture; no representative workload, energy or competitor claim.')
(root/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
