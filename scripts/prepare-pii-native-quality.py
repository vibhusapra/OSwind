#!/usr/bin/env python3
"""Freeze explicit native hybrid quality inputs before any inference."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import pii_quality as q

ROOT=Path(__file__).resolve().parent.parent
CODE=['scripts/prepare-pii-eval.py','scripts/pii_quality.py','scripts/test-pii-quality.py','scripts/evaluate-pii-model.py','scripts/evaluate-pii-baseline.py',
      'scripts/pii_native_quality.py','scripts/test-pii-native-quality.py','scripts/prepare-pii-native-quality.py','scripts/evaluate-pii-native-quality.py',
      'Sources/OSwindCore/PIIInspector.swift','Sources/OSwindCore/PIIDecoding.swift','Sources/OSwindCore/PIIDocument.swift','Sources/OSwindCore/PIITokenizer.swift',
      'Sources/OSwindCore/Privacy.swift','Sources/OSwindCLI/main.swift','Sources/OSwindCLI/NativeModelCLI.swift','Vendor/ONNXRuntime/PIIRuntime.cpp']


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['binary','corpus','model-dir','runtime-library','output']:p.add_argument('--'+name,required=True,type=Path)
    p.add_argument('--binary-sha256',required=True);p.add_argument('--binary-source',required=True)
    a=p.parse_args();binary=a.binary.resolve(strict=True);model=a.model_dir.resolve(strict=True);runtime=a.runtime_library.resolve(strict=True)
    if not re.fullmatch('[0-9a-f]{40}',a.binary_source) or q.sha256(binary)!=a.binary_sha256:raise ValueError('Unbound native CLI bytes/source')
    data=json.loads(a.corpus.read_text());rows=[r for r in data['rows'] if r['split']=='validation'];reserved=[r for r in data['rows'] if r['split']=='test']
    assert len(rows)==72 and len(reserved)==144 and len({r['id'] for r in rows})==72 and len({r['text'] for r in rows})==72
    assets=[dict(path=str(f),bytes=f.stat().st_size,sha256=q.sha256(f)) for f in sorted(model.rglob('*')) if f.is_file()]
    assets.append(dict(path=str(runtime),bytes=runtime.stat().st_size,sha256=q.sha256(runtime)))
    plan=dict(format='OSwind native hybrid PII quality plan v1',frozenAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
              harnessSource=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
              corpusSHA256=q.sha256(a.corpus),validationCases=72,reservedTestCases=144,labels=data['labels'],
              validationIdentities=[dict(id=r['id'],sourceSHA256=hashlib.sha256(r['text'].encode()).hexdigest()) for r in rows],
              thresholdGrid=[.3,.5,.7],computes=['cpu','coreML'],maximumTextCharacters=4096,
              baselineCLI=dict(path=str(binary),sha256=a.binary_sha256,productSource=a.binary_source),
              nativeCLI=dict(path=str(binary),sha256=a.binary_sha256,productSource=a.binary_source),
              modelDirectory=str(model),runtimeLibrary=str(runtime),assets=assets,
              codeSHA256={name:q.sha256(ROOT/name) for name in CODE},
              expectedModelOnlyValidationCounts={'0.3':dict(fullyCoveredValues=45,negativeExamplesWithPrediction=20),'0.5':dict(fullyCoveredValues=42,negativeExamplesWithPrediction=8),'0.7':dict(fullyCoveredValues=29,negativeExamplesWithPrediction=0)},
              expectedPatternCounts=dict(fullyCoveredValues=14,negativeExamplesWithPrediction=0),
              scope='Actual immutable CLI model-only and model+pattern masks, same72 already-opened authored validation sources;144 reserved predictions unopened. No representative desktop, training-unseen, production admission, quality acceptance, physical GPU, speed, energy or ranking claim.')
    a.output.mkdir(mode=0o700,parents=True,exist_ok=False)
    (a.output/'plan.json').write_text(json.dumps(plan,indent=2)+'\n');print(json.dumps(dict(validationCases=72,reservedPredictionsOpened=False,plannedNativeCalls=432,assets=len(assets))),flush=True)


if __name__=='__main__':main()
