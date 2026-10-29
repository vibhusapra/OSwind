#!/usr/bin/env python3
"""Freeze explicit native runtime, binary and public validation inputs."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import pii_domain_quality as d
import pii_quality as q

ROOT=Path(__file__).resolve().parent.parent
CODE=['scripts/prepare-pii-eval.py','scripts/pii_quality.py','scripts/test-pii-quality.py','scripts/evaluate-pii-model.py','scripts/evaluate-pii-baseline.py',
      'scripts/pii_native_quality.py','scripts/test-pii-native-quality.py','scripts/pii_domain_quality.py','scripts/test-pii-domain-quality.py',
      'scripts/prepare-pii-domain-quality.py','scripts/prepare-pii-domain-eval.py','scripts/evaluate-pii-domain-quality.py','scripts/replay-pii-domain-admission.py',
      'benchmarks/prototypes/pii/gretel-validation-v1/source.json','benchmarks/prototypes/pii/gretel-validation-v1/requirements.lock',
      'benchmarks/prototypes/pii/gretel-validation-v1/manifest.json',
      'Sources/OSwindCore/PIIInspector.swift','Sources/OSwindCore/PIIDecoding.swift','Sources/OSwindCore/PIIDocument.swift','Sources/OSwindCore/PIITokenizer.swift',
      'Sources/OSwindCore/Privacy.swift','Sources/OSwindCLI/main.swift','Sources/OSwindCLI/NativeModelCLI.swift','Vendor/ONNXRuntime/PIIRuntime.cpp']


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['binary','corpus','source-admission','model-dir','runtime-library','output']:p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--binary-sha256',required=True);p.add_argument('--binary-source',required=True);a=p.parse_args()
    if a.output.exists():raise ValueError('Use a new plan directory')
    binary=a.binary.resolve(strict=True);model=a.model_dir.resolve(strict=True);runtime=a.runtime_library.resolve(strict=True)
    if not re.fullmatch('[0-9a-f]{40}',a.binary_source) or q.sha256(binary)!=a.binary_sha256:raise ValueError('Changed native binary identity')
    corpus=json.loads(a.corpus.read_text());audit=json.loads(a.source_admission.read_text());rows=corpus['rows']
    assert q.sha256(a.corpus)==audit['corpusSHA256'] and corpus['sourceFileSHA256']==audit['sourceFileSHA256']==d.PARQUET_SHA256
    assert corpus['sourceDataset']==audit['sourceDataset']==d.DATASET and corpus['sourceRevision']==audit['sourceRevision']==d.REVISION
    assert corpus['policySourceTypes']==d.POLICY_TYPES and corpus['excludedSourceTypes']==sorted(d.EXCLUDED_TYPES)
    assert audit['predictionsGenerated'] is False and audit['testSplitDownloaded'] is False and audit['selection']['modelOutputsConsulted'] is False
    assert audit['selectedSummary']==d.describe(rows) and len(rows)==153 and len({r['id'] for r in rows})==153
    assert all(r['split']=='validation' and r['sourceSHA256']==hashlib.sha256(r['text'].encode()).hexdigest() for r in rows)
    assert corpus['labels']==json.loads((ROOT/'benchmarks/prototypes/pii/native-hybrid-v1/validation.json').read_text())['labels']
    for name,digest in audit['codeSHA256'].items():assert q.sha256(ROOT/name)==digest
    assets=[dict(path=str(f),bytes=f.stat().st_size,sha256=q.sha256(f)) for f in sorted(model.rglob('*')) if f.is_file()]
    assets.append(dict(path=str(runtime),bytes=runtime.stat().st_size,sha256=q.sha256(runtime)))
    plan=dict(format='OSwind public domain native PII quality plan v1',frozenAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        harnessSource=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        corpusSHA256=q.sha256(a.corpus),sourceAdmissionSHA256=q.sha256(a.source_admission),validationCases=153,labels=corpus['labels'],
        validationIdentities=[dict(id=r['id'],sourceSHA256=r['sourceSHA256']) for r in rows],
        thresholdGrid=[.3,.5,.7],computes=['cpu','coreML'],plannedNativeCalls=918,maximumTextCharacters=4096,
        baselineCLI=dict(path=str(binary),sha256=a.binary_sha256,productSource=a.binary_source),
        nativeCLI=dict(path=str(binary),sha256=a.binary_sha256,productSource=a.binary_source),
        modelDirectory=str(model),runtimeLibrary=str(runtime),assets=assets,codeSHA256={name:q.sha256(ROOT/name) for name in CODE},
        sourceDataset=d.DATASET,sourceRevision=d.REVISION,selection=audit['selection'],selectedSummary=audit['selectedSummary'],
        scope=corpus['scope'],
        backendComparison='Record exact masks and quality separately. CPU512/CoreML128 window contexts can differ on longer sources; equality is measured, not assumed or required.',
        acceptance='No quality operating point or production admission accepted; no natural desktop, training-unseen, physical placement, speed, energy or competitor ranking claim.')
    a.output.mkdir(mode=0o700,parents=True,exist_ok=False)
    (a.output/'plan.json').write_text(json.dumps(plan,indent=2)+'\n')
    print(json.dumps(dict(state='frozen-no-inference',sources=153,goldValues=250,policyNegativeSources=45,plannedNativeCalls=918)),flush=True)


if __name__=='__main__':main()
