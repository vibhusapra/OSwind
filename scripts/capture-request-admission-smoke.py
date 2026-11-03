#!/usr/bin/env python3
"""Actual CLI capture preflight contracts; own disabled policies prevent sampling.

No native permission, user history, model download or credential is needed.
Every malformed request must fail before any library/vault activity. Positive
controls reach their existing configured policy guards, so refusing all commands
cannot pass. Output is create-only and bound to the actual binary/harness bytes.
"""
import argparse, hashlib, json, os, pathlib, sqlite3, subprocess, tempfile, time

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary',type=pathlib.Path,required=True)
p.add_argument('--output',type=pathlib.Path,required=True)
a=p.parse_args();binary=a.binary.resolve();output=a.output.resolve()
assert binary.is_file() and os.access(binary,os.X_OK) and not output.exists()
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
binary_sha=sha(binary);harness_sha=sha(pathlib.Path(__file__).resolve())
settings={'snapshotRegions':{'blocked':True,'selectedDisplays':[],'displayCrops':{}},'visualCaptureMode':'snapshots','captureOnLaunch':False,'audioEnabled':False,'systemAudioEnabled':False,'apiEnabled':False,'automaticMaintenance':False}

def footprint(root):
    return {str(path.relative_to(root)):('directory' if path.is_dir() else sha(path)) for path in root.rglob('*')}

def run(label,arguments,*,valid=False,prefix_data=True):
    with tempfile.TemporaryDirectory(prefix='owned-capture-preflight-') as directory:
        root=pathlib.Path(directory);library=root/'selected library';library.mkdir(mode=0o700)
        # A parser regression must still never sample the user's foreground.
        # Also guard the relative roots a malformed global flag could select.
        for guarded in [root,library,*[root/name for name in ['--app-bundle','--seconds','--vault','--data']]]:
            guarded.mkdir(mode=0o700,exist_ok=True)
            (guarded/'settings.json').write_text(json.dumps(settings))
        args=[str(library) if x=='{data}' else str(root/'missing.oswindvault') if x=='{vault}' else x for x in arguments]
        command=([str(binary),'--data',str(library)] if prefix_data else [str(binary)])+args
        env={**os.environ,'OSWIND_DATA_DIR':str(library),'LANG':'en_US.UTF-8'}
        before=footprint(root);started=time.monotonic()
        r=subprocess.run(command,cwd=root,env=env,stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=30)
        elapsed=time.monotonic()-started;after=footprint(root)
        if valid:
            database=library/'memory.sqlite';assert database.is_file(),(label,r.returncode,r.stdout,r.stderr)
            with sqlite3.connect('file:'+str(database)+'?mode=ro',uri=True) as db:count=db.execute('SELECT COUNT(*) FROM memories').fetchone()[0]
            policy_guard='capture area' in (r.stdout+r.stderr).lower() or 'Select and save Text only' in r.stderr
            assert count==0 and policy_guard,(label,r.returncode,r.stdout,r.stderr)
            if args[0]=='capture':assert r.returncode==0 and 'Invalid capture area' in r.stdout,(label,r.returncode,r.stdout,r.stderr)
            else:assert r.returncode==1 and r.stderr.startswith('OSwind: '),(label,r.returncode,r.stdout,r.stderr)
        else:
            assert r.returncode==1 and r.stdout=='' and r.stderr.startswith('OSwind: '),(label,r.returncode,r.stdout,r.stderr)
            assert before==after,(label,'Malformed request touched its owned library/vault roots',sorted(set(after)-set(before)))
            assert not list(root.rglob('memory.sqlite')),(label,'Malformed request opened history')
        return {'case':label,'arguments':arguments,'explicitDataPrefix':prefix_data,'expected':'configured-policy-refusal' if valid else 'preflight-refusal-without-filesystem-change','exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr,'wallSeconds':elapsed,'filesystemUnchanged':before==after,'capturedMemories':0}

rows=[]
common=[('missing-target',['--app-bundle']),('empty-target',['--app-bundle','']),('whitespace-target',['--app-bundle',' ']),('flag-as-target',['--app-bundle','--other']),('duplicate-target',['--app-bundle','com.oswind.fixture.one','--app-bundle','com.oswind.fixture.two']),('unknown-option',['--unknown']),('stray-argument',['extra']),('oversized-target',['--app-bundle','x'*1025]),('multibyte-oversized-target',['--app-bundle','é'*600]),('control-in-target',['--app-bundle','com.oswind.\nfixture']),('leading-dash-target',['--app-bundle','-fixture']),('space-in-target',['--app-bundle','com.oswind fixture'])]
for command in ['capture','capture-text','capture-replay']:
    base=['--seconds','1'] if command=='capture-replay' else []
    for name,tail in common:rows.append(run(command+'/'+name,[command,*base,*tail]))
    for name,tail,prefix in [('missing-data',['--data'],False),('empty-data',['--data',''],False),('flag-as-data',['--data','--app-bundle'],False),('duplicate-data',['--data','{data}'],True),('missing-vault',['--vault'],False),('duplicate-vault',['--vault','{vault}','--vault','{vault}'],False),('conflicting-roots',['--vault','{vault}'],True),('oversized-data',['--data','x'*16385],False)]:
        rows.append(run(command+'/'+name,[command,*base,*tail],prefix_data=prefix))
for name,tail in [('missing-seconds',[]),('missing-seconds-value',['--seconds']),('empty-seconds',['--seconds','']),('duplicate-seconds',['--seconds','1','--seconds','2'])]+[(name,['--seconds',value]) for name,value in [('nan-seconds','NaN'),('infinite-seconds','inf'),('negative-infinite-seconds','-inf'),('zero-seconds','0'),('negative-seconds','-1'),('subsecond-duration','0.99'),('over-limit-duration','120.01'),('nonnumeric-duration','forever')]]:
    rows.append(run('capture-replay/'+name,['capture-replay',*tail]))
for command in ['capture','capture-text','capture-replay']:
    base=['--seconds','1'] if command=='capture-replay' else []
    rows.append(run(command+'/valid-current-request',[command,*base],valid=True))
    rows.append(run(command+'/valid-explicit-target',[command,*base,'--app-bundle','com.oswind.fixture-Mac_3'],valid=True))
    if command=='capture-replay':rows.append(run(command+'/valid-reordered-upper-bound',[command,'--app-bundle','com.oswind.fixture-Mac_3','--seconds','120'],valid=True))
compatibility=[]
for command in ['stats','config']:
    with tempfile.TemporaryDirectory(prefix='owned-capture-compatibility-') as directory:
        root=pathlib.Path(directory);(root/'settings.json').write_text(json.dumps(settings))
        r=subprocess.run([str(binary),'--data',str(root),command],cwd=root,env={**os.environ,'OSWIND_DATA_DIR':str(root)},stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=30)
        assert r.returncode==0,(command,r.stdout,r.stderr);value=json.loads(r.stdout)
        if command=='stats':assert value['count']==0
        else:assert value['captureOnLaunch'] is False and value['apiEnabled'] is False
        compatibility.append({'command':command,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
assert sha(binary)==binary_sha and sha(pathlib.Path(__file__).resolve())==harness_sha
output.parent.mkdir(parents=True,exist_ok=True)
result={'format':'OSwind CLI capture argument admission process receipt v1','binary':str(binary),'binarySHA256':binary_sha,'harnessSHA256':harness_sha,'scope':'Owned disabled snapshot policies only. Actual CLI rejects malformed capture/capture-text/capture-replay scope, duration and global-root flags before any filesystem change. Positive requests reach existing blocked capture/mode guards and save zero memories. No native pixel/AX/audio sampling, GUI/TCC, model/GPU, power, soak or competitor qualification.','passed':True,'malformedCases':sum(r['expected'].startswith('preflight') for r in rows),'positivePolicyControls':sum(r['expected'].startswith('configured') for r in rows),'nonCaptureCompatibility':compatibility,'rows':rows}
with output.open('x') as f:json.dump(result,f,indent=2);f.write('\n')
print(json.dumps({'receipt':str(output),'passed':True,'malformedCases':result['malformedCases'],'positivePolicyControls':result['positivePolicyControls'],'nonCaptureCompatibility':len(compatibility),'capturedMemories':0,'binarySHA256':binary_sha}))
