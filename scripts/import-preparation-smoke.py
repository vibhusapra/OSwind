#!/usr/bin/env python3
"""Owned CLI/settings races. New workspace; no normal history or account access.

Collector stdin is a deterministic pause. lsof must observe its retained settings
descriptor before a cooperative atomic save. No latency/energy/competitor claim.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary',type=Path)
parser.add_argument('--root',type=Path,required=True)
args=parser.parse_args();binary=args.binary.resolve(strict=True);root=args.root.resolve()
root.mkdir(mode=0o700,exist_ok=False);library=root/'library'
binary_hash=hashlib.sha256(binary.read_bytes()).hexdigest();prefix=[str(binary),'--data',str(library)]
report=dict(format='OSwind import preparation process checks',version=1,state='running',binarySHA256=binary_hash,checks=[],operations=[])
def save():
    (root/'report.tmp').write_text(json.dumps(report,indent=2)+'\n');(root/'report.tmp').replace(root/'report.json')
def unchanged():assert hashlib.sha256(binary.read_bytes()).hexdigest()==binary_hash,'CLI changed during evaluation'
def run(*arguments,payload=None,ok=True):
    unchanged();p=subprocess.run(prefix+list(map(str,arguments)),input=payload,capture_output=True,timeout=90)
    report['operations'].append(dict(command=arguments[0],returncode=p.returncode,stdoutSHA256=hashlib.sha256(p.stdout).hexdigest(),stderrSHA256=hashlib.sha256(p.stderr).hexdigest()));save()
    assert (p.returncode==0)==ok,(arguments,p.returncode,p.stderr.decode(errors='replace'));return p
def check(name):report['checks'].append(name);save()
def count():return json.loads(run('stats').stdout)['count']
settings=library/'settings.json';config=json.loads(run('config').stdout)
def atomic_settings(data):
    with (library/'.settings-admission.lock').open('a+b') as lock:
        os.chmod(lock.fileno(),0o600);deadline=time.monotonic()+3
        while True:
            try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);break
            except BlockingIOError:
                assert time.monotonic()<deadline,'Settings lock did not release';time.sleep(.01)
        temporary=library/('.settings-fixture-'+uuid.uuid4().hex)
        try:
            with temporary.open('xb') as output:
                os.chmod(output.fileno(),0o600);output.write(data);output.flush();os.fsync(output.fileno())
            temporary.replace(settings)
        finally:temporary.unlink(missing_ok=True);fcntl.flock(lock,fcntl.LOCK_UN)
baseline=json.dumps(config,sort_keys=True).encode();atomic_settings(baseline)
batch=json.dumps(dict(format='OSwind collector batch',version=1,collectorID='dev.example.importfence',records=[dict(key='owned',timestamp='2026-10-29T12:00:00Z',app='Fixture',bundleID='dev.example.fixture',title='Owned source',text='password=owned-fixture-value')])).encode()
def paused_collect(change,ok):
    atomic_settings(baseline);unchanged()
    child=subprocess.Popen(prefix+['collect','--stdin'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:
        deadline=time.monotonic()+15
        while True:
            assert child.poll() is None,'Collector exited before stdin admission'
            observed=subprocess.run(['/usr/sbin/lsof','-a','-p',str(child.pid),'-Fn'],capture_output=True,timeout=5)
            if ('n'+str(settings)).encode() in observed.stdout.splitlines():break
            assert time.monotonic()<deadline,'Retained settings descriptor was not observed';time.sleep(.02)
        before=settings.stat().st_ino;change();after=settings.stat().st_ino
        stdout,stderr=child.communicate(batch,timeout=60)
        report['operations'].append(dict(command='paused collect',returncode=child.returncode,settingsDescriptorObserved=True,settingsInodeChanged=before!=after,stdoutSHA256=hashlib.sha256(stdout).hexdigest(),stderrSHA256=hashlib.sha256(stderr).hexdigest()));save()
        assert (child.returncode==0)==ok,(child.returncode,stderr.decode(errors='replace'))
        if not ok:assert b'Saved settings changed' in stderr
    finally:
        if child.poll() is None:child.terminate();child.wait(timeout=10)
        for stream in [child.stdin,child.stdout,child.stderr]:stream.close()
try:
    changed=dict(config);changed['privacy']=dict(config['privacy']);changed['privacy']['redactSecrets']=not changed['privacy']['redactSecrets']
    paused_collect(lambda:atomic_settings(json.dumps(changed).encode()),False);assert count()==0;check('Changed policy refuses pending collector input')
    paused_collect(lambda:atomic_settings(baseline),False);assert count()==0;check('Identical atomic resave invalidates old snapshot')
    def aba():atomic_settings(json.dumps(changed).encode());atomic_settings(baseline)
    paused_collect(aba,False);assert count()==0;check('Policy change and restore invalidates old snapshot')
    paused_collect(lambda:None,True);assert count()==1;check('Unchanged snapshot admits collector input')
    standard=root/'ordinary.json';standard.write_text(json.dumps([dict(id='json',timestamp='2026-10-29T12:00:00Z',kind='note',app='Fixture',bundleID='dev.example.fixture',title='Owned JSON',text='Owned JSON text',favorite=False,tags=[],regions=[])]))
    limitless=root/'limitless.json';limitless.write_text(json.dumps(dict(data=dict(lifelogs=[dict(id='owned-limitless',title='Owned lifelog',markdown='Owned text',startTime='2026-10-29T12:00:00Z',endTime='2026-10-29T12:01:00Z')]))))
    for name,arguments,payload in [('JSON',['import',standard,'--json'],None),('Limitless',['import-limitless',limitless,'--json'],None),('collector',['collect','--stdin'],batch)]:
        atomic_settings(b'{malformed');p=run(*arguments,payload=payload,ok=False);assert b'malformed' in p.stderr;assert count()==1;check(name+' route refuses malformed saved policy')
    atomic_settings(baseline)
    assert json.loads(run('import',standard,'--json').stdout)['imported']==1
    assert json.loads(run('import-limitless',limitless,'--json').stdout)['imported']==1
    assert count()==3;check('Repaired policy admits JSON and Limitless and preserves collector')
    unchanged();report['state']='completed';save();print(json.dumps(report,indent=2))
except BaseException as error:
    report['state']='failed';report['error']=str(error);save();raise
