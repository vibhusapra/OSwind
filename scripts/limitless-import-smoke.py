#!/usr/bin/env python3
"""Owned, offline Limitless API text migration through an immutable CLI.

Creates a NEW private workspace, optionally its own encrypted APFS image.
No normal history, vendor account, provider request or settings change.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import secrets
import signal
import subprocess
import time

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary',type=Path)
parser.add_argument('--root',type=Path,required=True)
parser.add_argument('--native-vault',action='store_true')
args=parser.parse_args()
binary,root=args.binary.resolve(strict=True),args.root.resolve()
root.mkdir(mode=0o700,exist_ok=False)
library=root/'library'
binary_hash=hashlib.sha256(binary.read_bytes()).hexdigest()
report=dict(format='OSwind Limitless API migration process checks',version=1,state='running',binarySHA256=binary_hash,scope='Authored offline API responses only; no vendor history, real credentials, capture, energy or competitor claim',checks=[],operations=[])
environment=os.environ.copy();environment['OSWIND_DATA_DIR']=str(library)
secret=secrets.token_urlsafe(32).encode()
package=root/'Migration.oswindvault'

def save():
    temporary=root/'report.tmp'
    temporary.write_text(json.dumps(report,indent=2)+'\n');temporary.replace(root/'report.json')

def check(name):
    report['checks'].append(name);save()

def run(name,*arguments,data=library,payload=None,ok=True,raw=False):
    assert hashlib.sha256(binary.read_bytes()).hexdigest()==binary_hash,'CLI changed before process'
    command=[str(binary)]+([] if raw else ['--data',str(data)])+list(map(str,arguments))
    output,error=root/(name+'.stdout'),root/(name+'.stderr')
    started,system=time.monotonic(),time.time()
    usage=None
    with output.open('wb') as out,error.open('wb') as err:
        child=subprocess.Popen(command,env=environment,stdin=subprocess.PIPE if payload is not None else subprocess.DEVNULL,stdout=out,stderr=err)
        try:
            if payload is not None:child.stdin.write(payload);child.stdin.close()
            while True:
                pid,status,usage=os.wait4(child.pid,os.WNOHANG)
                if pid:child.returncode=os.waitstatus_to_exitcode(status);break
                if time.monotonic()-started>180:raise TimeoutError('Owned migration CLI deadline exceeded')
                time.sleep(.01)
        finally:
            if child.returncode is None:
                child.send_signal(signal.SIGTERM)
                try:child.wait(timeout=20)
                except subprocess.TimeoutExpired:child.kill();child.wait()
    stdout,stderr=output.read_bytes(),error.read_bytes()
    assert secret not in stdout and secret not in stderr,'Own vault secret echoed'
    report['operations'].append(dict(name=name,exitCode=child.returncode,awakeSeconds=time.monotonic()-started,systemSeconds=time.time()-system,userCPUSeconds=usage.ru_utime if usage else None,systemCPUSeconds=usage.ru_stime if usage else None,peakRSSBytes=usage.ru_maxrss if usage else None,stdoutSHA256=hashlib.sha256(stdout).hexdigest(),stderrSHA256=hashlib.sha256(stderr).hexdigest()))
    save()
    assert hashlib.sha256(binary.read_bytes()).hexdigest()==binary_hash,'CLI changed during process'
    assert (child.returncode==0)==ok,(name,child.returncode,stderr.decode(errors='replace'))
    return json.loads(stdout) if child.returncode==0 and stdout.strip().startswith((b'{',b'[')) else stdout

def fixture(records,cursor=None):
    return dict(data=dict(lifelogs=records),meta=dict(lifelogs=dict(count=len(records),nextCursor=cursor)))

def record(identity='owned-release',text='MigrationAuroraEvidence Maya owns the Aurora release.'):
    return dict(id=identity,title='Owned release review',markdown=text,startTime='2024-11-03T01:20:00-04:00',endTime='2024-11-03T01:40:00-05:00',isStarred=True,updatedAt='2024-11-04T12:00:00Z',contents=[dict(type='heading1',content='Owned review',children=[dict(type='blockquote',content='MigrationRobinEvidence Robin confirmed Friday.',speakerName='Robin',speakerIdentifier='user',startOffsetMs=60000,endOffsetMs=68000)])])

def write(name,value):
    path=root/name;path.write_text(json.dumps(value,ensure_ascii=False));return path

def vault(name,*arguments,password=False):
    return run(name,'vault',*arguments,payload=secret+b'\0' if password else None,raw=True)

def attached():
    value=plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil','info','-plist'],timeout=30))
    assert isinstance(value.get('images'),list),'Native attachment inventory unavailable'
    target=(package/'contents.sparsebundle').resolve()
    return any(Path(image.get('image-path','/')).resolve()==target for image in value['images'])

save()
try:
    source=write('owned-response.json',fixture([record()],cursor='owned-next-page'))
    first=run('first','import-limitless',source,'--json')
    identity='limitless:'+hashlib.sha256(b'owned-release').hexdigest()
    assert first['sourceIDs']==[identity] and first['hasMorePages'] and first['imported']==1
    assert run('retry','import-limitless',source,'--json')==first
    saved=run('get','get',identity)
    assert saved['timestamp']=='2024-11-03T05:20:00Z' and saved['endTimestamp']=='2024-11-03T06:40:00Z'
    assert saved['kind']=='note' and saved['favorite'] and saved['tags']==['import:limitless']
    assert all(not saved.get(key) for key in ('audioPath','imagePath','videoPath','transcript'))
    assert 'speakerName: Robin' in saved['text'] and 'endOffsetMs: 68000' in saved['text']
    hits=run('search','search','--mode','keyword','MigrationRobinEvidence')
    assert [hit['memory']['id'] for hit in hits]==[identity]
    check('exact identity, DST-crossing instants, nested speaker text, page notice, retry and keyword search across processes')

    saved.update(favorite=False,tags=['reviewed'])
    curated=write('owned-curation.json',[saved]);run('curate','import',curated,'--json')
    updated=write('owned-updated.json',fixture([record(text='MigrationCedarEvidence new owner.')]))
    run('update','import-limitless',updated,'--json');current=run('get-updated','get',identity)
    assert not current['favorite'] and set(current['tags'])=={'reviewed','import:limitless'}
    assert 'MigrationCedarEvidence' in current['text'] and 'MigrationAuroraEvidence' not in current['text']
    assert run('count','stats')['count']==1
    malformed=fixture([record(text='must not publish'),dict(record('last'),unknown='refuse')])
    run('invalid-final','import-limitless',write('invalid-final.json',malformed),'--json',ok=False)
    assert run('after-invalid','get',identity)['text']==current['text']
    check('update preserves user curation; malformed final entry publishes no earlier changes')

    private=dict(record('private'),title='Private browsing fixture')
    protected=record('redacted',text='password=owned-fixture-value')
    result=run('privacy','import-limitless',write('privacy.json',fixture([private,protected])),'--json')
    assert (result['imported'],result['excluded'])==(1,1)
    redacted=run('redacted','get',result['sourceIDs'][1]);assert 'owned-fixture-value' not in redacted['text'] and '[REDACTED]' in redacted['text']
    link=root/'symlink.json';link.symlink_to(source)
    run('symlink-refusal','import-limitless',link,'--json',ok=False)
    fifo=root/'fifo.json';os.mkfifo(fifo,0o600)
    run('fifo-refusal','import-limitless',fifo,'--json',ok=False)
    check('default privacy redaction and exclusion; final symlink/FIFO refusal without blocking')

    export=root/'portable.json';run('export','export',export)
    portable=root/'portable-library';run('import-portable','import',export,'--json',data=portable)
    assert run('portable-get','get',identity,data=portable)['text']==current['text']
    check('normal OSwind JSON round trip retains imported note text')

    bulk=write('owned-thousand.json',fixture([record('bulk-'+str(i),text='OwnedBulkEvidence '+str(i)) for i in range(1000)]))
    result=run('thousand-import','import-limitless',bulk,'--json',data=root/'bulk-library')
    assert result['imported']==1000 and len(set(result['sourceIDs']))==1000
    assert run('thousand-stats','stats',data=root/'bulk-library')['count']==1000
    report['bulkInputBytes']=bulk.stat().st_size
    report['bulkInputSHA256']=hashlib.sha256(bulk.read_bytes()).hexdigest()
    check('1000 authored entries admitted by one bounded page; timing includes fresh CLI startup, Apple embeddings and SQLite')

    if args.native_vault:
        assert vault('vault-create','create',package,'--name','Owned migration','--capacity-gb','1','--passphrase-stdin',password=True)['state']=='locked'
        vault('vault-unlock','unlock',package,'--passphrase-stdin',password=True)
        alias=package/'Library'
        assert run('encrypted-import','import-limitless',updated,'--json',data=alias)['imported']==1
        encrypted=run('encrypted-get','get',identity,data=alias)
        assert vault('vault-lock','lock',package)['state']=='locked' and not attached()
        run('locked-refusal','import-limitless',updated,'--json',data=alias,ok=False)
        assert alias.is_file() and not alias.is_symlink() and not alias.is_dir()
        vault('vault-reopen','unlock',package,'--passphrase-stdin',password=True)
        assert run('encrypted-get-reopened','get',identity,data=alias)==encrypted
        assert vault('vault-final-lock','lock',package)['state']=='locked' and not attached()
        check('encrypted APFS import, exact note reopen and locked refusal without plaintext fallback')
    report['state']='completed'
except BaseException:
    report['state']='failed';raise
finally:
    # An unconfirmed create response does not prove native attachment absence.
    # Inspect the exact owned path even when create raised before acknowledgement.
    if args.native_vault:
        try:
            if attached():vault('vault-cleanup-lock','lock',package)
            report['nativeCleanupDetached']=not attached()
        except BaseException as error:
            report['state']='failed';report['nativeCleanupDetached']=False
            report['cleanupErrorType']=type(error).__name__;raise
        finally:save()
    save()
print(json.dumps(report,indent=2))
