#!/usr/bin/env python3
"""Owned settings compatibility/portability checks; no screen access or capture."""
import contextlib
import argparse,hashlib,json,pathlib,sqlite3,subprocess
p=argparse.ArgumentParser();p.add_argument('binary',type=pathlib.Path);p.add_argument('--root',type=pathlib.Path,required=True);p.add_argument('--old-cli',type=pathlib.Path);a=p.parse_args()
binary=a.binary.resolve();base=a.root.resolve();base.mkdir(mode=0o700,exist_ok=False);library=base/'library';report={'format':'OSwind capture-region compatibility v1','scope':'Owned synthetic source/settings, library compatibility refusal and quiet backup/restore. No pixels, normal library, credentials or native input.','binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'checks':[]}
def save():(base/'report.json').write_text(json.dumps(report,indent=2)+'\n')
def run(cli,*args,ok=True):
 r=subprocess.run([str(cli),*map(str,args)],capture_output=True,text=True,timeout=60)
 assert (r.returncode==0)==ok,(args,r.returncode,r.stderr);return r

def snapshot():
 with contextlib.closing(sqlite3.connect(library/'memory.sqlite')) as db:return {'schema':db.execute('PRAGMA user_version').fetchone()[0],'ids':db.execute('SELECT id,text FROM memories ORDER BY id').fetchall()}
try:
 creator=a.old_cli.resolve() if a.old_cli else binary
 identifier=run(creator,'--data',library,'note','Owned capture scope marker').stdout.strip()
 if a.old_cli:
  report['olderBinarySHA256']=hashlib.sha256(creator.read_bytes()).hexdigest();assert snapshot()['schema']==19;report['actualOlderSchema19Creator']=True
 else:
  with contextlib.closing(sqlite3.connect(library/'memory.sqlite')) as db:db.execute('PRAGMA user_version=19');db.commit()
  report['actualOlderSchema19Creator']=False
 region={'selectedDisplays':['11111111-1111-4111-8111-111111111111'],'displayCrops':{'11111111-1111-4111-8111-111111111111':{'x':0.1,'y':0.2,'width':0.6,'height':0.5}},'focusedWindowCrop':{'x':0.5,'y':0,'width':0.5,'height':1}}
 settings={'allDisplays':True,'snapshotRegions':region,'captureOnLaunch':True,'apiEnabled':True,'automaticMaintenance':False}
 settingsFile=library/'settings.json';settingsFile.write_text(json.dumps(settings));settingsSHA=hashlib.sha256(settingsFile.read_bytes()).hexdigest();before=snapshot()
 assert json.loads(run(binary,'--data',library,'stats','--json').stdout)['count']==1
 after=snapshot();assert after['schema']==22 and before['ids']==after['ids'] and hashlib.sha256(settingsFile.read_bytes()).hexdigest()==settingsSHA
 report['checks'].append('schema19 upgrades to22 with exact source identity/text and unchanged settings bytes')
 if a.old_cli:
  for command in [('stats','--json'),('note','Older capture client must refuse')]:
   refusal=run(creator,'--data',library,*command,ok=False);assert 'newer OSwind' in refusal.stderr
  assert snapshot()==after and hashlib.sha256(settingsFile.read_bytes()).hexdigest()==settingsSHA
  report['checks'].append('actual signed schema19 CLI refuses read/write with unchanged logical schema, sources and region settings')
 else:report['olderClientRefusal']='Not exercised; supply pinned --old-cli for actual refusal evidence'
 archive=base/'owned.oswindbackup';restored=base/'restored'
 run(binary,'--data',library,'backup','create',archive);run(binary,'backup','restore',archive,'--to',restored)
 assert json.loads(run(binary,'--data',restored,'get',identifier).stdout)['text']=='Owned capture scope marker'
 quiet=json.loads((restored/'settings.json').read_text());assert quiet['allDisplays'] and not quiet['captureOnLaunch'] and not quiet['apiEnabled']
 for key,value in region.items():assert quiet['snapshotRegions'][key]==value
 report['checks'].append('quiet backup restore preserves exact selected identities and both crop scopes without starting capture or API')
 report.update(state='completed',sourceSchema=19,targetSchema=22,physicalCaptureClaimed=False);save();print(json.dumps(report,indent=2))
except BaseException as error:report.update(state='failed',failure=str(error));save();raise
