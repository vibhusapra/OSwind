#!/usr/bin/env python3
"""Owned, offline packaged import contracts. Native positives/known negatives
require an explicitly prepared cache. No downloads, capture or default library.
"""
import argparse, hashlib, json, os, signal, subprocess, tempfile, time, uuid
from pathlib import Path

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser();p.add_argument('cli',type=Path);p.add_argument('--root',type=Path);p.add_argument('--cache-root',type=Path)
    a=p.parse_args();cli=a.cli.resolve();initial=sha(cli)
    base=a.root.resolve() if a.root else Path(tempfile.mkdtemp(prefix='oswind-pii-import-'))
    if a.root:base.mkdir(mode=0o700,parents=True,exist_ok=False)
    rows=[]
    phone='+1 (202) 555-0100';positive='Owned support note: my private phone number is '+phone+'. Keep this private.'
    email='maria@sample.example.com';negative='You can email me at '+email+' for the report.'
    def run(library,args,data=None,success=True):
        assert library.parent==base and library.name.startswith('library-')
        assert sha(cli)==initial
        start=time.monotonic()
        r=subprocess.run([str(cli),'--data',str(library),*args],input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=120)
        assert (r.returncode==0)==success,(args,r.returncode,r.stderr.decode(errors='replace')[-1200:])
        assert sha(cli)==initial
        index=len(rows);(base/f'{index:02d}.stdout').write_bytes(r.stdout);(base/f'{index:02d}.stderr').write_bytes(r.stderr)
        rows.append(dict(args=args,returncode=r.returncode,seconds=time.monotonic()-start,stdoutSHA256=hashlib.sha256(r.stdout).hexdigest(),stderrSHA256=hashlib.sha256(r.stderr).hexdigest()))
        return json.loads(r.stdout) if success and '--json' in args or success and args[0]=='collect' else r
    def count(library):return run(library,['stats','--json'])['count']
    def input_for(kind,text,label):
        if kind=='import':obj=[dict(id=str(uuid.uuid4()),timestamp='2026-10-29T12:00:00Z',kind='note',app='Fixture',bundleID='org.example.fixture',title='Fixture',text=text,regions=[],favorite=False,tags=[])]
        elif kind=='collect':obj=dict(format='OSwind collector batch',version=1,collectorID='org.example.fixture',records=[dict(key=label,timestamp='2026-10-29T12:00:00Z',app='Fixture',bundleID='org.example.fixture',title='Fixture',text=text)])
        else:obj=dict(data=dict(lifelogs=[dict(id=label,title='Fixture',markdown=text,startTime='2026-10-29T12:00:00Z',endTime='2026-10-29T12:01:00Z',isStarred=False,contents=[])]),meta=dict(lifelogs=dict(count=1,nextCursor=None)))
        raw=json.dumps(obj).encode()
        if kind=='collect':return [kind,'--stdin'],raw
        path=base/(label+'.json');path.write_bytes(raw);return [kind,str(path),'--json'],None
    for kind in ['import','collect','import-limitless']:
        args,data=input_for(kind,'Owned fixture','missing-'+kind);library=base/('library-missing-'+kind)
        run(library,args+['--pii','--pii-compute','cpu','--pii-threshold','0.5','--pii-cache-root',str(base/'missing-cache')],data,False)
        assert count(library)==0;assert not (base/'missing-cache').exists()
    # Invalid options cannot quietly select ordinary admission.
    args,data=input_for('import','Owned fixture','invalid-flags');library=base/'library-invalid-flags'
    for flags in [['--pii'],['--pii-threshold','0.5'],['--pii','--pii-compute','cpu','--pii-threshold','nan'],['--pii','--pii','--pii-compute','cpu','--pii-threshold','0.5']]:
        run(library,args+flags,data,False)
    assert count(library)==0
    # A malformed saved configuration must fail strict settings capture, not
    # reload permissive defaults through AppSettings.load.
    library=base/'library-invalid-settings';library.mkdir(mode=0o700)
    settings=library/'settings.json';settings.write_text(json.dumps(dict(piiImports=dict(enabled=True,compute='invalid',threshold=0.5,cacheRoot=''))));settings.chmod(0o600)
    run(library,args,success=False)
    native=[]
    if a.cache_root:
        cache=a.cache_root.resolve()
        for compute in ['cpu','coreML']:
            for kind in ['import','collect','import-limitless']:
                label=compute+'-'+kind;library=base/('library-'+label);args,data=input_for(kind,positive,label)
                result=run(library,args+['--pii','--pii-compute',compute,'--pii-threshold','0.5','--pii-cache-root',str(cache)],data)
                summary=result['learnedPrivacy'];assert summary['compute']==compute and summary['threshold']==0.5 and summary['sources']==1 and summary['redactedSources']==1
                exported=base/(label+'-export.json');run(library,['export',str(exported)]);records=json.loads(exported.read_text())
                assert len(records)==1 and phone not in records[0]['text'] and '[REDACTED]' in records[0]['text']
                assert all(records[0].get(k) is None for k in ['imagePath','audioPath','videoPath'])
                native.append(dict(compute=compute,kind=kind,case='authored-phone-positive',masked=True,summary=summary))
            label=compute+'-known-email-miss';library=base/('library-'+label);args,data=input_for('import',negative,label)
            result=run(library,args+['--pii','--pii-compute',compute,'--pii-threshold','0.5','--pii-cache-root',str(cache)],data)
            exported=base/(label+'-export.json');run(library,['export',str(exported)]);records=json.loads(exported.read_text())
            assert email in records[0]['text'],'Pinned known negative changed; reevaluate quality, do not silently rewrite the expectation'
            native.append(dict(compute=compute,kind='import',case='authored-email-known-miss',masked=False,summary=result['learnedPrivacy']))
        library=base/'library-saved-enabled';library.mkdir(mode=0o700)
        settings=library/'settings.json';settings.write_text(json.dumps(dict(piiImports=dict(enabled=True,compute='cpu',threshold=0.5,cacheRoot=str(cache)))));settings.chmod(0o600)
        args,data=input_for('import',positive,'saved-enabled');result=run(library,args,data);assert result['learnedPrivacy']['sources']==1
    # Collector input remains cancellable with scanning selected, before EOF.
    library=base/'library-cancel-stdin'
    with (base/'cancel.stdout').open('wb') as out,(base/'cancel.stderr').open('wb') as err:
        child=subprocess.Popen([str(cli),'--data',str(library),'collect','--stdin','--pii','--pii-compute','cpu','--pii-threshold','0.5','--pii-cache-root',str(base/'missing-cache')],stdin=subprocess.PIPE,stdout=out,stderr=err)
        try:
            deadline=time.monotonic()+10
            while not (library/'.media-admission.lock').exists() and time.monotonic()<deadline:time.sleep(0.01)
            assert child.poll() is None;time.sleep(0.2);child.send_signal(signal.SIGINT);status=child.wait(timeout=10);assert status==130,status
        finally:
            if child.poll() is None:child.terminate();child.wait(timeout=10)
            child.stdin.close()
    assert count(library)==0;assert sha(cli)==initial
    result=dict(format='OSwind experimental PII import process contracts',version=1,cliSHA256=initial,operations=rows,native=native,cancelBeforeEOF=True,privacyAcceptance=False)
    (base/'report.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(operations=len(rows),nativeCases=len(native),cancelBeforeEOF=True,privacyAcceptance=False,report=str(base/'report.json'))))
if __name__=='__main__':main()
