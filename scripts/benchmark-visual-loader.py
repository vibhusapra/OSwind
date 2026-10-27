#!/usr/bin/env python3
"""Sequential signed-CLI visual pairs on a frozen explicit image fixture.

macOS only. Per-child wait4 CPU/RSS; uncontrolled OS/CoreML caches. No capture,
normal history, provider calls, power settings or energy/competitor assertion.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('candidate',type=Path)
parser.add_argument('--baseline',type=Path,required=True)
parser.add_argument('--model-dir',type=Path,required=True)
parser.add_argument('--fixture',type=Path,required=True)
parser.add_argument('--protocol',type=Path,required=True)
parser.add_argument('--root',type=Path,required=True)
args=parser.parse_args()
if sys.platform!='darwin':parser.error('Per-child RSS units and pipeline require macOS')
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
protocol=json.loads(args.protocol.read_text());fixture=json.loads(args.fixture.read_text())
baseline,candidate=args.baseline.resolve(strict=True),args.candidate.resolve(strict=True)
model=args.model_dir.resolve(strict=True);inputFile=args.fixture.resolve(strict=True)
assert sha(baseline)==protocol['baselineSignedCLISHA256'],'Frozen baseline differs'
assert sha(candidate)!=sha(baseline),'Candidate equals baseline'
if 'candidateSignedCLISHA256' in protocol:assert sha(candidate)==protocol['candidateSignedCLISHA256']
def value_sha(value):
    return hashlib.sha256(json.dumps(value,ensure_ascii=False,separators=(',',':')).encode()).hexdigest()


if 'queries' in protocol:
    assert fixture['queries']==protocol['queries'] and fixture['targets']==protocol['targets']
else:
    assert value_sha(fixture['queries'])==protocol['queriesSHA256']
    assert value_sha(fixture['targets'])==protocol['targetsSHA256']
imageCount=len(protocol['fixtureImages']);queryCount=len(fixture['queries'])
assert 1<=imageCount<=256 and 1<=queryCount<=1024
assert len(fixture['images'])==imageCount and len(fixture['targets'])==queryCount
images=[]
for path,expected in zip(fixture['images'],protocol['fixtureImages']):
    path=Path(path);path=path if path.is_absolute() else inputFile.parent/path
    path=path.resolve(strict=True);assert sha(path)==expected['sha256'];images.append(str(path))
assert sha(model/'tokenizer.json')==protocol['tokenizerSHA256']
if 'modelManifestSHA256' in protocol:
    assert sha(model/'OSWIND-VISION.json')==protocol['modelManifestSHA256']
order=['baseline','candidate','candidate','baseline','baseline','candidate']
assert protocol['order']==['old','new','new','old','old','new']


def competing_jobs():
    output=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True)
    names={'swift-frontend','swift-build','swift-test','swift-driver','xctest','oswindctl'}
    return [line.strip() for line in output.splitlines() if line.strip().split() and Path(line.strip().split(maxsplit=1)[1]).name in names]


assert not competing_jobs(),'Wait for local Swift/test/CLI jobs to finish before comparison'
root=args.root.resolve();root.mkdir(mode=0o700,exist_ok=False)
sourceInputFile=inputFile;inputFile=root/'input-fixture.json'
inputFile.write_text(json.dumps(fixture|{'images':images},indent=2)+'\n')
report=dict(format='OSwind paired visual-loader workload v1' if imageCount==3 and queryCount==3 else 'OSwind paired visual workload v2',state='running',
            protocolSHA256=sha(args.protocol),fixtureSHA256=sha(sourceInputFile),normalizedFixtureSHA256=sha(inputFile),
            baselineSHA256=sha(baseline),candidateSHA256=sha(candidate),
            order=order,trials=[],scope=protocol.get('workloadScope',protocol.get('scope','Explicit frozen image/query fixture through signed CLI index/query/reopen. Uncontrolled caches/background activity; no capture, energy or competitor claim.')),
            limits=['Child CPU excludes shared daemons; wait4 maximum RSS is macOS bytes, not total system memory.','No baseline/candidate build or model/test job may overlap; other background activity is uncontrolled.','Clock divergence over1 second stops the run and retains the trial. No replacement trials are silently added.'])


def save():
    (root/'report.json').write_text(json.dumps(report,indent=2)+'\n')


def stop_owned_child(child):
    # Preserve ownership/reaping even if the harness itself is interrupted.
    # This never signals a process group, native helper, or unrelated process.
    previous=signal.signal(signal.SIGINT,signal.SIG_IGN)
    try:
        for native_signal,budget in [(signal.SIGINT,10),(signal.SIGTERM,2),(signal.SIGKILL,2)]:
            try:os.kill(child.pid,native_signal)
            except ProcessLookupError:pass
            until=time.monotonic()+budget
            while time.monotonic()<until:
                pid,status,_=os.wait4(child.pid,os.WNOHANG)
                if pid:child.returncode=os.waitstatus_to_exitcode(status);return
                time.sleep(.02)
        _,status,_=os.wait4(child.pid,0);child.returncode=os.waitstatus_to_exitcode(status)
    finally:
        signal.signal(signal.SIGINT,previous)


def verify_inputs():
    assert sha(baseline)==protocol['baselineSignedCLISHA256'] and sha(candidate)==report['candidateSHA256']
    assert sha(sourceInputFile)==report['fixtureSHA256'] and sha(args.protocol)==report['protocolSHA256']
    assert sha(inputFile)==report['normalizedFixtureSHA256']
    for path,expected in zip(images,protocol['fixtureImages']):assert sha(Path(path))==expected['sha256']
    assert sha(model/'tokenizer.json')==protocol['tokenizerSHA256']
    if 'modelManifestSHA256' in protocol:assert sha(model/'OSWIND-VISION.json')==protocol['modelManifestSHA256']


save()
try:
    for index,label in enumerate(order):
        assert not competing_jobs(),'Competing local build/test/CLI job appeared'
        verify_inputs()
        folder=root/f'{index}-{label}';folder.mkdir(mode=0o700)
        cli=baseline if label=='baseline' else candidate
        command=[str(cli),'benchmark-visual','--fixture',str(inputFile),'--model-dir',str(model),'--root',str(folder/'library'),'--compute','cpuAndGPU','--output',str(folder/'benchmark.json')]
        begin=time.monotonic();systemBegin=time.time();deadline=begin+300;timedOut=False;stage=0
        with (folder/'stdout.log').open('wb') as stdout,(folder/'stderr.log').open('wb') as stderr:
            child=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=stdout,stderr=stderr)
            # No Popen.poll/wait: wait4 must reap this exact child to retain its
            # resource receipt, rather than cumulative unrelated-child metrics.
            try:
                while True:
                    pid,status,usage=os.wait4(child.pid,os.WNOHANG)
                    if pid:
                        child.returncode=os.waitstatus_to_exitcode(status);break
                    now=time.monotonic()
                    if now>=deadline:
                        timedOut=True
                        try:os.kill(child.pid,[signal.SIGINT,signal.SIGTERM,signal.SIGKILL][min(stage,2)])
                        except ProcessLookupError:pass
                        stage+=1;deadline=now+(10 if stage==1 else 2)
                    time.sleep(.02)
            finally:
                if child.returncode is None:
                    report['abortedTrialIndex']=index;save();stop_owned_child(child)
        trial=dict(index=index,label=label,exitCode=child.returncode,timedOut=timedOut,
                   awakeElapsedSeconds=time.monotonic()-begin,systemElapsedSeconds=time.time()-systemBegin,
                   childUserCPUSeconds=usage.ru_utime,childSystemCPUSeconds=usage.ru_stime,
                   childMaximumResidentBytes=usage.ru_maxrss,
                   stdoutSHA256=sha(folder/'stdout.log'),stderrSHA256=sha(folder/'stderr.log'))
        if (folder/'benchmark.json').exists():
            trial['benchmark']=json.loads((folder/'benchmark.json').read_text())
        trial['competingJobsAfter']=competing_jobs()
        report['trials'].append(trial);save();print(json.dumps(trial),flush=True)
        assert child.returncode==0 and not timedOut,'Owned trial failed; retained without replacement'
        assert abs(trial['awakeElapsedSeconds']-trial['systemElapsedSeconds'])<=1,'Clock divergence; retain trial'
        assert not trial['competingJobsAfter'],'Competing local workload; retain trial'
        verify_inputs()
        native=trial['benchmark']
        assert native['images']==imageCount and native['queries']==queryCount and native['reopenedIndexSources']==imageCount and native['scopedResultsVerified']
        if 'expectedModelID' in protocol:assert native['modelID']==protocol['expectedModelID']
        if 'expectedCorpusSHA256' in protocol:assert native['corpusSHA256']==protocol['expectedCorpusSHA256']
        if 'expectedCorrectCounts' in protocol:
            assert {f'at{k}':round(native[f'recallAt{k}']*queryCount) for k in [1,5,10]}==protocol['expectedCorrectCounts']
        if index:
            original=report['trials'][0]['benchmark']
            for key in ['modelID','corpusSHA256','recallAt1','recallAt5','recallAt10','indexedFrames']:
                assert native[key]==original[key],('Correctness differs',key)
    report['state']='completed'
except BaseException:
    report['state']='failed';raise
finally:
    save()
