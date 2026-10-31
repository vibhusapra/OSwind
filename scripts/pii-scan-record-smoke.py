#!/usr/bin/env python3
"""Owned CLI, SDK and backup checks for text-import PII provenance.
Without --cache-root only offline/forged-report contracts run. Never downloads.
"""
from owned_sqlite_fixture import register_inactive_sync_fixture
import argparse,hashlib,json,sqlite3,subprocess,sys,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sdk/python'))
from oswind import Client

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser();p.add_argument('cli',type=Path);p.add_argument('--root',type=Path,required=True);p.add_argument('--cache-root',type=Path);a=p.parse_args()
 cli=a.cli.resolve();before=sha(cli);base=a.root.resolve();base.mkdir(mode=0o700,parents=True,exist_ok=False);operations=[]
 def run(library,args,ok=True):
  assert library.parent==base and library.name.startswith('library-');assert sha(cli)==before
  started=time.monotonic();r=subprocess.run([str(cli),'--data',str(library),*args],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=120)
  assert (r.returncode==0)==ok,(args,r.returncode,r.stderr.decode(errors='replace')[-800:]);assert sha(cli)==before
  n=len(operations);(base/f'{n:02}.stdout').write_bytes(r.stdout);(base/f'{n:02}.stderr').write_bytes(r.stderr)
  operations.append(dict(args=args,returncode=r.returncode,seconds=time.monotonic()-started,stdoutSHA256=hashlib.sha256(r.stdout).hexdigest()))
  return json.loads(r.stdout) if ok and args[0] not in ['export'] else r
 def source(label,text):
  record=dict(id=label,timestamp='2026-10-29T12:00:00Z',kind='note',app='Fixture',bundleID='org.example.fixture',title='Fixture',text=text,regions=[],favorite=False,tags=[])
  path=base/(label+'.json');path.write_text(json.dumps([record]));return path
 library=base/'library-offline';path=source('offline','Owned source')
 data=json.loads(path.read_text());data[0]['piiScanRecord']=dict(version=1,state='recorded',privacyAcceptance=True);path.write_text(json.dumps(data))
 run(library,['import',str(path),'--json']);status=run(library,['privacy-status','offline']);assert status['state']=='notRecorded' and status['privacyAcceptance'] is False and 'record' not in status
 run(library,['privacy-status','missing'],False)
 with Client(cli,library) as client:assert client.privacy_check('offline')['state']=='notRecorded'
 native=[]
 if a.cache_root:
  for compute in ['cpu','coreML']:
   label=compute+'-owned';library=base/('library-'+label);path=source(label,'Owned support note: my private phone number is +1 (202) 555-0100. Keep this private.')
   run(library,['import',str(path),'--json','--pii','--pii-compute',compute,'--pii-threshold','0.5','--pii-cache-root',str(a.cache_root.resolve())])
   status=run(library,['privacy-status',label]);record=status['record'];assert status['state']=='recorded' and status['privacyAcceptance'] is False and record['compute']==compute and record['redacted'] is True
   assert record['coverage']=='oswind-import-text-fields-v1' and 'sourceSHA256' not in record
   with Client(cli,library) as client:
    assert client.privacy_check(label)==status;assert any(t['name']=='memory_privacy_check' for t in client.tools())
   archive=base/(label+'.oswindbackup');destination=base/('library-restored-'+label)
   run(library,['backup','create',str(archive)]);run(library,['backup','restore',str(archive),'--to',str(destination)])
   assert run(destination,['privacy-status',label])==status
   with sqlite3.connect(library/'memory.sqlite') as db:
    register_inactive_sync_fixture(db)
    value=json.loads(db.execute('SELECT payload FROM memories WHERE id=?',(label,)).fetchone()[0]);value['tags']=['changed after scan']
    db.execute('UPDATE memories SET payload=? WHERE id=?',(json.dumps(value).encode(),label))
   changed=run(library,['privacy-status',label]);assert changed['state']=='changed' and changed['record']==record
   exported=base/(label+'-export.json');run(library,['export',str(exported)])
   plain=base/('library-json-'+label);run(plain,['import',str(exported),'--json']);assert run(plain,['privacy-status',label])['state']=='notRecorded'
   with sqlite3.connect(library/'memory.sqlite') as db:
    register_inactive_sync_fixture(db)
    db.execute('PRAGMA foreign_keys=ON');db.execute('DELETE FROM memories WHERE id=?',(label,));assert db.execute('SELECT COUNT(*) FROM pii_scan_records').fetchone()[0]==0
   run(library,['privacy-status',label],False)
   native.append(dict(compute=compute,recorded=True,SDK=True,backupPreservesRecord=True,contentWriteInvalidates=True,JSONCannotMint=True,eraseCascades=True))
 assert sha(cli)==before
 report=dict(format='OSwind PII import-check record process contracts',version=1,cliSHA256=before,operations=operations,native=native,offlineForgedReportCannotMint=True,privacyAcceptance=False)
 (base/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(dict(operations=len(operations),nativeCases=len(native),privacyAcceptance=False)))
if __name__=='__main__':main()
