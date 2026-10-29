#!/usr/bin/env python3
"""Paired ordinary CLI status observations on one owned detached APFS package.

No native fault injection, model inference, user history or power measurement.
Fixed 22 alternating AB/BA pairs; first two pairs are predeclared warmups.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import resource
import secrets
import statistics
import subprocess
import sys
import time


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def describe(values):
    return dict(samples=len(values), median=statistics.median(values),
                p95=statistics.quantiles(values, n=100, method='inclusive')[94],
                minimum=min(values), maximum=max(values))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['candidate', 'baseline']:
        parser.add_argument('--'+name, required=True, type=Path)
        parser.add_argument('--'+name+'-sha256', required=True)
    parser.add_argument('--root', required=True, type=Path)
    args=parser.parse_args()
    if sys.platform!='darwin':
        parser.error('Requires macOS encrypted APFS')
    binaries={name:getattr(args,name).resolve(strict=True) for name in ['candidate','baseline']}
    expected={name:getattr(args,name+'_sha256') for name in binaries}
    assert all(sha(path)==expected[name] for name,path in binaries.items())
    root=args.root.resolve();root.mkdir(mode=0o700,parents=True,exist_ok=False)
    plan=[dict(pair=i,order=['baseline','candidate'] if i%2==0 else ['candidate','baseline'],warmup=i<2) for i in range(22)]
    report=dict(format='OSwind paired ordinary CLI status observations v1',state='planned',binarySHA256=expected,
                scriptSHA256=sha(Path(__file__)),plan=plan,samples=[],
                scope='One synthetic detached encrypted APFS package, same status output, alternating AB/BA. Includes process startup/native IPC/identity checks. Host and caches uncontrolled; no isolated guard latency, energy, desktop, competitor or causal speed claim.',
                passphrasePersisted=False)
    def save():(root/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    save();secret=secrets.token_urlsafe(32).encode();package=root/'Fixture.oswindvault'
    def run(*command,password=None):
        p=subprocess.run([str(binaries['candidate']),*map(str,command)],input=password+b'\0' if password else b'',capture_output=True,timeout=180)
        assert p.returncode==0 and secret not in p.stdout+p.stderr,(p.returncode,p.stderr.decode(errors='replace'))
        return p.stdout
    def detached():
        values=plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil','info','-plist']))
        return not any(Path(x.get('image-path','/missing')).resolve()==(package/'contents.sparsebundle').resolve() for x in values.get('images',[]))
    try:
        run('vault','create',package,'--capacity-gb','1','--passphrase-stdin',password=secret)
        run('vault','unlock',package,'--passphrase-stdin',password=secret)
        identifier=run('--vault',package,'note','Owned normal-status timing marker').decode().strip()
        run('vault','lock',package);assert detached()
        manifest=sha(package/'oswind-vault.json');image=(package/'contents.sparsebundle').stat()
        reference=None;report['state']='running';save()
        for item in plan:
            for name in item['order']:
                assert sha(binaries[name])==expected[name]
                before=resource.getrusage(resource.RUSAGE_CHILDREN);start=time.monotonic();wall=time.time()
                p=subprocess.run([str(binaries[name]),'vault','status',str(package)],capture_output=True,timeout=90)
                seconds=time.monotonic()-start;wall_seconds=time.time()-wall;after=resource.getrusage(resource.RUSAGE_CHILDREN)
                assert p.returncode==0 and not p.stderr and secret not in p.stdout
                value=json.loads(p.stdout)
                assert value['state']=='locked' and not value['imageAttached'] and not value['volumeMounted']
                if reference is None:reference=value
                assert value==reference,'Different ordinary status output'
                row=dict(pair=item['pair'],binary=name,warmup=item['warmup'],elapsedSeconds=seconds,wallSeconds=wall_seconds,
                         waitedChildUserSeconds=after.ru_utime-before.ru_utime,waitedChildSystemSeconds=after.ru_stime-before.ru_stime,
                         outputSHA256=hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest(),exitCode=p.returncode)
                report['samples'].append(row);save()
                assert abs(seconds-wall_seconds)<1,'Clock gap; all samples retained, no timing acceptance'
        assert sha(package/'oswind-vault.json')==manifest
        final_image=(package/'contents.sparsebundle').stat();assert (image.st_dev,image.st_ino)==(final_image.st_dev,final_image.st_ino)
        run('vault','unlock',package,'--passphrase-stdin',password=secret)
        assert json.loads(run('--vault',package,'get',identifier))['text']=='Owned normal-status timing marker'
        run('vault','lock',package);assert detached()
        measured=[x for x in report['samples'] if not x['warmup']]
        metrics={}
        for name in binaries:
            rows=[x for x in measured if x['binary']==name];assert len(rows)==20
            metrics[name]=dict(elapsedSeconds=describe([x['elapsedSeconds'] for x in rows]),
                               waitedChildCPUSeconds=describe([x['waitedChildUserSeconds']+x['waitedChildSystemSeconds'] for x in rows]))
        paired=[]
        for i in range(2,22):
            pair={x['binary']:x for x in measured if x['pair']==i};paired.append(pair['candidate']['elapsedSeconds']-pair['baseline']['elapsedSeconds'])
        report.update(state='completed',metrics=metrics,pairedCandidateMinusBaselineSeconds=describe(paired),all44StatusOutputsEqual=True,
                      manifestAndImageIdentityUnchangedDuringStatus=True,historyPreserved=True,independentlyDetached=True)
        save();print(json.dumps(dict(metrics=metrics,pairedCandidateMinusBaselineSeconds=report['pairedCandidateMinusBaselineSeconds'])),flush=True)
    except BaseException as error:
        report.update(state='failed',errorType=type(error).__name__)
        try:run('vault','lock',package);report['normalRecoveryDetached']=detached()
        except BaseException as recovery:report['normalRecoveryErrorType']=type(recovery).__name__
        save();raise


if __name__=='__main__':main()
