#!/usr/bin/env python3
"""Compile the actual Foundation-only parser with its owned contract driver."""
from pathlib import Path
import argparse,hashlib,json,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);a=p.parse_args();output=a.output.resolve();assert not output.exists()
source=root/'Sources/OSwindCLI/CaptureRequestCLI.swift';driver=root/'Tests/Fixtures/CaptureRequestParserContract.swift';sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();before={str(p.relative_to(root)):sha(p) for p in [source,driver,Path(__file__).resolve()]}
with tempfile.TemporaryDirectory(prefix='owned-capture-parser-contract-') as directory:
 binary=Path(directory)/'contract'
 built=subprocess.run(['swiftc','-parse-as-library',str(source),str(driver),'-o',str(binary)],capture_output=True,text=True,timeout=120)
 assert built.returncode==0,built.stderr
 ran=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30);assert ran.returncode==0,(ran.stdout,ran.stderr)
 result=json.loads(ran.stdout);assert result['passed'] and len(result['checks'])==len(set(result['checks']))==46
 assert all(sha(root/p)==h for p,h in before.items())
 result.update({'inputFiles':before,'compilerStderr':built.stderr,'runtimeStderr':ran.stderr,'binarySHA256':sha(binary),'scope':'Actual Foundation-only production parser compiled unchanged with an owned contract entry point. Exact target bytes/current-window intent/duration bounds/global paths/non-capture semantics. No Core, native capture, library, model, credential or user setting access.'})
 output.parent.mkdir(parents=True,exist_ok=True)
 with output.open('x') as f:json.dump(result,f,indent=2);f.write('\n')
 print(json.dumps({'receipt':str(output),'passed':True,'checks':len(result['checks'])}))
