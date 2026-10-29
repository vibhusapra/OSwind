#!/usr/bin/env python3
"""Owned file bounds, FIFO refusal and collector/wipe ordering through real CLIs.

Optional immutable baseline is observed separately. Creates a NEW private root;
every wipe targets only its authored fixture library. No normal history, capture,
accounts, provider calls, physical power or whole-competitor measurements.
"""
import argparse
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import statistics
import subprocess
import time

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary',type=Path)
parser.add_argument('--baseline',type=Path)
parser.add_argument('--root',type=Path,required=True)
args=parser.parse_args();root=args.root.resolve();root.mkdir(mode=0o700,exist_ok=False)
systems={'after':args.binary.resolve(strict=True)}
if args.baseline:systems['before']=args.baseline.resolve(strict=True)
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
pins={name:sha(path) for name,path in systems.items()}
report=dict(format='OSwind input lifetime process checks',version=1,state='running',systems={k:dict(binarySHA256=v) for k,v in pins.items()},operations=[],checks=[],scope='Owned local inputs and synthetic libraries. Sparse oversized-file RSS includes process startup; uncontrolled host/cache, not isolated throughput, energy or competitor ranking.')
children=[]
def save():
    (root/'report.tmp').write_text(json.dumps(report,indent=2)+'\n');(root/'report.tmp').replace(root/'report.json')
def unchanged():
    for name,path in systems.items():assert sha(path)==pins[name],name+' CLI changed'
def prefix(name,library):return [str(systems[name]),'--data',str(library)]
def observe(name,command,code,out,err):
    report['operations'].append(dict(system=name,command=command,returncode=code,stdoutSHA256=hashlib.sha256(out).hexdigest(),stderrSHA256=hashlib.sha256(err).hexdigest()));save()
def run(name,library,*command):
    unchanged();p=subprocess.run(prefix(name,library)+list(map(str,command)),capture_output=True,timeout=90)
    observe(name,command[0],p.returncode,p.stdout,p.stderr);assert p.returncode==0,p.stderr.decode(errors='replace');return json.loads(p.stdout) if p.stdout.lstrip().startswith((b'{',b'[')) else p.stdout
def check(text):report['checks'].append(text);save()
def open_names(child):
    return subprocess.run(['/usr/sbin/lsof','-a','-p',str(child.pid),'-Fn'],capture_output=True,timeout=5).stdout.splitlines()
def wait_for_file(child,path,timeout=10):
    deadline=time.monotonic()+timeout
    while True:
        assert child.poll() is None,'Owned process exited before expected descriptor observation'
        if ('n'+str(path)).encode() in open_names(child):return
        assert time.monotonic()<deadline,'Expected owned descriptor was not observed';time.sleep(.02)
def spawn(argv,**kwargs):
    unchanged();p=subprocess.Popen(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kwargs);children.append(p);return p
def exclusive_available(path):
    fd=os.open(path,os.O_RDWR|os.O_CREAT,0o600)
    try:
        try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:return False
        fcntl.flock(fd,fcntl.LOCK_UN);return True
    finally:os.close(fd)

payload=json.dumps([dict(id='fifo-note',timestamp='2026-10-29T12:00:00Z',kind='note',app='Fixture',bundleID='dev.example.fixture',title='Owned input',text='Owned FIFO fixture',favorite=False,tags=[],regions=[])]).encode()
batch=json.dumps(dict(format='OSwind collector batch',version=1,collectorID='dev.example.inputlifetime',records=[dict(key='owned',timestamp='2026-10-29T12:00:00Z',app='Fixture',bundleID='dev.example.fixture',title='Owned note',text='Owned pending input')])).encode()
try:
    oversized=root/'oversized.json'
    with oversized.open('xb') as f:f.truncate(100_000_001)
    readings={name:[] for name in systems}
    order=['after','before','before','after','after','before'] if 'before' in systems else ['after']*3
    for trial,name in enumerate(order):
        library=root/('size-'+name);run(name,library,'stats')
        unchanged();p=subprocess.run(['/usr/bin/time','-l',*prefix(name,library),'import',str(oversized),'--json'],capture_output=True,timeout=90)
        observe(name,'oversized import',p.returncode,p.stdout,p.stderr);assert p.returncode!=0
        match=re.search(rb'\s(\d+)\s+maximum resident set size',p.stderr);assert match,'macOS time RSS missing'
        readings[name].append(dict(trial=trial,maximumResidentBytes=int(match[1])))
        if name=='after':assert b'Import file exceeds its 100000000-byte limit' in p.stderr
        assert run(name,library,'stats')['count']==0
    for name,rows in readings.items():
        report['systems'][name]['sparseOversizedFileRSS']=dict(samples=rows,medianMaximumResidentBytes=statistics.median(x['maximumResidentBytes'] for x in rows))
    check('100000001-byte sparse file refuses without rows; per-process RSS observations retained')

    for name in systems:
        library=root/('fifo-'+name);fifo=root/(name+'.fifo');os.mkfifo(fifo,0o600)
        child=spawn(prefix(name,library)+['import',str(fifo),'--json'],stdin=subprocess.DEVNULL)
        writer_used=False
        if name=='after':out,err=child.communicate(timeout=10)
        else:
            try:out,err=child.communicate(timeout=.5)
            except subprocess.TimeoutExpired:
                deadline=time.monotonic()+10
                while child.poll() is None:
                    try:fd=os.open(fifo,os.O_WRONLY|os.O_NONBLOCK)
                    except OSError as error:
                        if error.errno!=errno.ENXIO:raise
                        assert time.monotonic()<deadline,'Baseline FIFO did not finish or accept an owned writer';time.sleep(.02);continue
                    try:os.write(fd,payload);writer_used=True
                    finally:os.close(fd)
                    break
                out,err=child.communicate(timeout=30)
        observe(name,'FIFO import',child.returncode,out,err)
        count=run(name,library,'stats')['count'];report['systems'][name]['fifo']=dict(returncode=child.returncode,ownedWriterNeeded=writer_used,sourceCount=count)
        if name=='after':assert child.returncode!=0 and count==0
    check('Current CLI refuses FIFO without a writer; baseline behavior retained without assumed failure')

    for name in systems:
        library=root/('ordering-'+name);run(name,library,'note','Owned pre-wipe marker')
        settings=library/'settings.json';settings.write_text(json.dumps(run(name,library,'config')));settings.chmod(0o600)
        collector=spawn(prefix(name,library)+['collect','--stdin'],stdin=subprocess.PIPE)
        wait_for_file(collector,settings)
        lock=library/'.media-admission.lock';reserved=not exclusive_available(lock)
        if name=='after':assert reserved,'Pending collector input is missing its library reservation'
        wipe=spawn(prefix(name,library)+['wipe','--confirm','DELETE-ALL','--json'],stdin=subprocess.DEVNULL)
        completed_early=False
        if name=='before' and not reserved:
            wiped,wipe_err=wipe.communicate(timeout=15);completed_early=True
            assert wipe.returncode==0,'Baseline wipe did not finish while unreserved stdin remained pending'
        else:
            wait_for_file(wipe,lock);assert wipe.poll() is None
        collected,collect_err=collector.communicate(batch,timeout=30)
        assert collector.returncode==0,collect_err.decode(errors='replace')
        if not completed_early:wiped,wipe_err=wipe.communicate(timeout=30)
        assert wipe.returncode==0,wipe_err.decode(errors='replace')
        admitted=json.loads(collected);erased=json.loads(wiped)
        assert admitted['imported']==1 and admitted['excluded']==0
        assert erased['cleanupComplete'] is True and erased['erasure']['pendingMedia']==0
        observe(name,'pending collector',collector.returncode,collected,collect_err);observe(name,'concurrent owned wipe',wipe.returncode,wiped,wipe_err)
        final_count=run(name,library,'stats')['count'];report['systems'][name]['pendingInputWipe']=dict(settingsDescriptorObserved=True,reservedDuringStdin=reserved,collectorImported=admitted['imported'],wipeRemovedSources=erased['erasure']['sources'],finalSourceCount=final_count)
        if name=='after':assert final_count==0,'A pending import resurrected data after the completed wipe'
        if final_count:
            assert final_count==1
            remaining=run(name,library,'get',admitted['sourceIDs'][0]);assert remaining['text']=='Owned pending input'
            report['systems'][name]['pendingInputWipe']['remainingSourceIsPendingCollector']=True
    check('Current collector reservation orders pending stdin before full wipe; no late imported source survives')
    unchanged();report['state']='completed';save();print(json.dumps(report,indent=2))
except BaseException as error:
    report['state']='failed';report['error']=str(error);save();raise
finally:
    for child in children:
        if child.poll() is None:child.send_signal(signal.SIGINT)
    for child in children:
        if child.poll() is None:
            try:child.communicate(timeout=10)
            except subprocess.TimeoutExpired:child.terminate();child.communicate(timeout=10)
        for stream in [child.stdin,child.stdout,child.stderr]:
            if stream is not None:stream.close()
