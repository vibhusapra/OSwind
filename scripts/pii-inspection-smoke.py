#!/usr/bin/env python3
"""Exercise the actual history-free CLI; synthetic input, explicit local assets.

No download, account, capture, device setting, or normal-library access.
"""
import argparse
import hashlib
import json
import os
import signal
from pathlib import Path
import subprocess
import tempfile
import time
import uuid


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary",type=Path)
    parser.add_argument("--model-dir",type=Path,required=True)
    parser.add_argument("--runtime-library",type=Path,required=True)
    parser.add_argument("--root",type=Path,required=True)
    parser.add_argument("--real-model",action="store_true")
    options=parser.parse_args()
    binary=options.binary.resolve(strict=True);model=options.model_dir.resolve();runtime=options.runtime_library.absolute()
    root=options.root.absolute();root.mkdir(parents=True,exist_ok=False)
    history=root/"history-must-stay-absent";env=os.environ.copy();env["OSWIND_DATA_DIR"]=str(history)
    base=["pii","inspect","--model-dir",str(model),"--runtime-library",str(runtime),"--compute","cpu","--threshold","0.5","--stdin"]
    records=[];before={p.name for p in Path(tempfile.gettempdir()).glob("oswind-pii-runtime-*")}

    def run(name,arguments,data=b"Owned synthetic text",success=False):
        start=time.monotonic()
        process=subprocess.run([str(binary),*arguments],input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=180)
        (root/(name+".stdout")).write_bytes(process.stdout);(root/(name+".stderr")).write_bytes(process.stderr)
        assert (process.returncode==0)==success,(name,process.returncode,process.stderr[-1000:])
        assert not history.exists(),f"{name}: explicit history-free command created its data directory"
        if not success:assert process.stdout==b"",f"{name}: refusal emitted a result"
        record=dict(name=name,exitCode=process.returncode,wallSeconds=time.monotonic()-start,
                    stdoutBytes=len(process.stdout),stderrBytes=len(process.stderr),stdoutSHA256=hashlib.sha256(process.stdout).hexdigest())
        records.append(record)
        if success:
            value=json.loads(process.stdout)
            assert value["compute"] in ("cpu","coreML") and value["threshold"]==0.5
            assert value["modelID"].endswith(":"+value["compute"])
            assert value["sourceSHA256"]==hashlib.sha256(data).hexdigest()
            assert value["redacted"]==value["suppressMedia"]
            assert "fixtureSecret9731" not in process.stdout.decode() and b"fixtureSecret9731" not in process.stderr
            for span in value["spans"]:assert set(span)=={"startUTF16","lengthUTF16","label","category","confidence"}
            return value

    run("unknown-command",["pii","unknown"])
    run("missing-options",["pii","inspect","--stdin"])
    run("unknown-option",base+["--unknown"])
    run("duplicate-stdin",base+["--stdin"])
    run("duplicate-threshold",base+["--threshold","0.7"])
    run("explicit-data-refused",["--data",str(history),*base])
    run("vault-refused-before-inspection",["--vault",str(root/"missing-vault"),*base])
    run("invalid-utf8",base,b"\xff")
    run("oversized-bytes",base,b"a"*131073)
    run("empty",base,b"")
    run("whitespace",base,b" \n\t")
    run("oversized-scalars",base,b"a"*32769)
    run("oversized-word",base,b"a"*1025)
    for value in ["0","1","nan","inf","-1"]:
        arguments=base.copy();arguments[arguments.index("--threshold")+1]=value
        run("invalid-threshold-"+value,arguments)
    arguments=base.copy();arguments[arguments.index("--compute")+1]="automatic"
    run("implicit-compute-refused",arguments)
    if options.real_model:
        secret=b"Owned note: password=fixtureSecret9731. Phone +1 (415) 555-0119."
        cpu=run("cpu",base,secret,True);assert cpu["patternRedacted"] and cpu["redacted"]
        arguments=base.copy();arguments[arguments.index("--compute")+1]="coreML"
        coreml=run("coreml",arguments,secret,True);assert coreml["patternRedacted"] and coreml["redacted"]
        assert run("coreml-windowed",arguments,b"word "*128,True)["windowCount"]>1
        assert run("cpu-windowed",base,b"word "*500,True)["windowCount"]>1
        document=secret+b" "+b"Routine work continues. "*100+b" "+secret+b" "+b"Routine work continues. "*100+b" "+secret
        for compute in ["cpu","coreML"]:
            arguments=base.copy();arguments[arguments.index("--compute")+1]=compute
            value=run(compute+"-long-document",arguments,document,True)
            assert value["windowCount"]>1 and 0<value["framedTokens"]<=65536
            assert value["patternRedacted"] and value["text"].count("[REDACTED]")>=3
            # Observe only this exact child's mapped/retained native snapshot.
            # Foundation's user temporary directory can ignore TMPDIR on macOS.
            # This proves owned runtime preparation, not an inference instruction
            # in flight or physical GPU placement. Never inspect another PID.
            start=time.monotonic();process=subprocess.Popen([str(binary),*arguments],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
            observed=set();stdout=stderr=b""
            try:
                process.stdin.write(b"Routine work continues. "*1000);process.stdin.close();process.stdin=None
                deadline=time.monotonic()+30
                while time.monotonic()<deadline and process.poll() is None:
                    listing=subprocess.run(["/usr/sbin/lsof","-a","-p",str(process.pid),"-Fn"],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=2)
                    for line in listing.stdout.splitlines():
                        if not line.startswith("n/"):continue
                        path=Path(line[1:])
                        if path.name!="runtime.dylib" or not path.parent.name.startswith("oswind-pii-runtime-"):continue
                        try:uuid.UUID(path.parent.name.removeprefix("oswind-pii-runtime-"))
                        except ValueError:continue
                        if path.is_file():observed.add(path)
                    if observed:break
                    time.sleep(.01)
                assert observed,"Owned native runtime preparation was not observed before cancellation"
                process.send_signal(signal.SIGINT)
                stdout,stderr=process.communicate(timeout=180)
                (root/(compute+"-cancel.stdout")).write_bytes(stdout);(root/(compute+"-cancel.stderr")).write_bytes(stderr)
                assert process.returncode==130 and stdout==b"",(compute,process.returncode,stderr[-1000:])
                assert b"Stopping PII inspection" in stderr and b"Operation cancelled." in stderr
                assert all(not path.parent.exists() for path in observed),"Cancelled inspection left its observed native runtime snapshot"
                assert not history.exists()
                records.append(dict(name=compute+"-native-preparation-SIGINT",exitCode=process.returncode,wallSeconds=time.monotonic()-start,observedOwnedRuntimePreparation=True,stdoutBytes=0,stderrBytes=len(stderr),stdoutSHA256=hashlib.sha256(stdout).hexdigest(),newRuntimeSnapshotsRemaining=0))
            finally:
                if process.poll() is None:process.kill();stdout,stderr=process.communicate()
                elif not stdout and not stderr:stdout,stderr=process.communicate()
                (root/(compute+"-cancel.stdout")).write_bytes(stdout);(root/(compute+"-cancel.stderr")).write_bytes(stderr)
        bad=root/"wrong-runtime.dylib";bad.write_bytes(b"not a runtime")
        arguments=base.copy();arguments[arguments.index("--runtime-library")+1]=str(bad)
        run("runtime-hash",arguments)
        link=root/"symlink-runtime.dylib";link.symlink_to(runtime)
        arguments[arguments.index("--runtime-library")+1]=str(link)
        run("runtime-symlink",arguments)
        invalid=root/"invalid-model";(invalid/"onnx").mkdir(parents=True)
        for name in ["tokenizer.json","tokenizer_config.json"]:(invalid/name).write_bytes((model/name).read_bytes())
        (invalid/"onnx/model.onnx").write_bytes(b"not a graph")
        arguments=base.copy();arguments[arguments.index("--model-dir")+1]=str(invalid)
        run("graph-hash",arguments)
    after={p.name for p in Path(tempfile.gettempdir()).glob("oswind-pii-runtime-*")}
    assert not after-before,f"Runtime snapshot not removed after normal success/refusal: {after-before}"
    report=dict(format="OSwind PII CLI functional smoke v1",binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                realModel=options.real_model,checks=records,historyDirectoryAbsent=not history.exists(),newRuntimeSnapshotsRemaining=[],
                limitations=["Synthetic functional inputs; not a quality, latency or energy benchmark", "No capture, import, export, GUI or normal history qualification", "Abrupt process termination cleanup is not exercised"])
    (root/"report.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(dict(checks=len(records),allPassed=True,report=str(root/"report.json"))))


if __name__=="__main__":main()
