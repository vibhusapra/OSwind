#!/usr/bin/env python3
"""History-free PII setup CLI checks; public downloads require explicit opt-in."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary",type=Path)
    parser.add_argument("--root",type=Path,required=True)
    parser.add_argument("--prepared-cache",type=Path)
    parser.add_argument("--fresh-download",action="store_true")
    parser.add_argument("--interrupt-download",action="store_true")
    options=parser.parse_args()
    binary=options.binary.resolve(strict=True);root=options.root.absolute();root.mkdir(parents=True,exist_ok=False)
    history=root/"history-must-stay-absent";missing=root/"absent-cache"
    env=os.environ.copy();env["OSWIND_DATA_DIR"]=str(history);records=[]

    def run(name,args,data=b"",success=False):
        start=time.monotonic()
        result=subprocess.run([str(binary),"pii",*args],input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=1800)
        (root/(name+".stdout")).write_bytes(result.stdout);(root/(name+".stderr")).write_bytes(result.stderr)
        assert (result.returncode==0)==success,(name,result.returncode,result.stderr[-1000:])
        assert not history.exists(),name
        if not success:assert not result.stdout,(name,"refusal emitted a result")
        records.append(dict(name=name,exitCode=result.returncode,wallSeconds=time.monotonic()-start,stdoutSHA256=hashlib.sha256(result.stdout).hexdigest(),stderrBytes=len(result.stderr)))
        return json.loads(result.stdout) if success else None

    for action in ["verify","prepare"]:
        run(action+"-unknown",[action,"--cache-root",str(missing),"--unknown"])
        run(action+"-duplicate-cache",[action,"--cache-root",str(missing),"--cache-root",str(missing)])
        for flag in ["--data","--vault"]:run(action+flag,[action,flag,str(history),"--cache-root",str(missing)])
    run("verify-missing",["verify","--cache-root",str(missing)])
    run("inspect-missing",["inspect","--cache-root",str(missing),"--compute","cpu","--threshold","0.5","--stdin"],b"owned text")
    run("mixed-cache-paths",["inspect","--cache-root",str(missing),"--model-dir",str(missing),"--runtime-library",str(missing/"runtime.dylib"),"--compute","cpu","--threshold","0.5","--stdin"],b"owned text")
    assert not missing.exists()
    cache=options.prepared_cache.absolute() if options.prepared_cache else None
    if options.fresh_download:
        cache=root/"fresh-cache"
        result=run("fresh-prepare",["prepare","--cache-root",str(cache)],success=True)
        assert not result["reused"] and result["bytes"]==393488824 and result["downloadBytes"]==201963274
    if cache:
        verified=run("verify-ready",["verify","--cache-root",str(cache)],success=True)
        directory=Path(verified["directory"])
        before={str(p.relative_to(directory)):hashlib.sha256(p.read_bytes()).hexdigest() for p in directory.rglob('*') if p.is_file()}
        reused=run("prepare-reuse",["prepare","--cache-root",str(cache)],success=True)
        assert reused["reused"] and reused["buildID"]==verified["buildID"]
        assert verified["bytes"]==393488824 and len(before)==13
        for compute in ["cpu","coreML"]:
            data=b"Owned example: password=fixtureSetupSecret."
            result=run("inspect-"+compute,["inspect","--cache-root",str(cache),"--compute",compute,"--threshold","0.5","--stdin"],data,True)
            assert result["patternRedacted"] and result["suppressMedia"] and "fixtureSetupSecret" not in json.dumps(result)
        after={str(p.relative_to(directory)):hashlib.sha256(p.read_bytes()).hexdigest() for p in directory.rglob('*') if p.is_file()}
        assert before==after,"Ready installation changed during verification/reuse/inspection"
        corrupt=root/"corrupt-cache";destination=corrupt/directory.name;destination.mkdir(parents=True)
        sentinel=destination/"keep";sentinel.write_text("original owned file")
        for action in ["verify","prepare"]:run(action+"-corrupt",[action,"--cache-root",str(corrupt)])
        assert sentinel.read_text()=="original owned file" and list(destination.iterdir())==[sentinel]
    if options.interrupt_download:
        interrupted=root/"interrupt-cache";stderrPath=root/"interrupt.stderr"
        with stderrPath.open('wb') as err:
            process=subprocess.Popen([str(binary),"pii","prepare","--cache-root",str(interrupted)],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=err,env=env)
            try:
                deadline=time.monotonic()+90;observed=False
                while time.monotonic()<deadline and process.poll() is None:
                    if b"Downloading public PII models" in stderrPath.read_bytes():observed=True;break
                    time.sleep(0.02)
                assert observed and process.poll() is None,"No live download observed; no signal sent"
                # Popen retains ownership of this unreaped exact child PID.
                process.send_signal(signal.SIGINT);stdout,_=process.communicate(timeout=60)
                assert process.returncode==130 and stdout==b"",(process.returncode,stderrPath.read_bytes()[-1000:])
                assert list(interrupted.iterdir())==[interrupted/".pii-prepare.lock"],"Interrupted setup retained unpublished workspace"
                assert not history.exists()
                records.append(dict(name="interrupted-native-download",exitCode=130,expectedCancellation=True,unpublishedWorkspacesRemaining=0))
            finally:
                if process.poll() is None:process.terminate();process.communicate(timeout=60)
    report=dict(format="OSwind PII setup process smoke v1",binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),checks=records,historyDirectoryAbsent=not history.exists(),freshPublicDownload=options.fresh_download,interruptedPublicDownload=options.interrupt_download,
                limits=["Synthetic source text and owned caches only", "No native GUI clicks, production learned privacy, representative quality or physical GPU placement acceptance", "Prepared verification checks files and preparation receipt; does not rerun inference"])
    (root/"report.json").write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(checks=len(records),allPassed=True,report=str(root/"report.json"))))


if __name__=="__main__":main()
