import json
from pathlib import Path
import subprocess
import sys
import time

root=Path(__file__).resolve().parent;repo=root.parents[1]
plan=root/'comparison-plan-v1.json';matrix=root/'matrix-v1';matrix.mkdir(mode=0o700,exist_ok=False)
report=dict(state='running',operations=[],scope='Six sequential experimental reference processes, no automatic retry or installed product change. All failures remain retained.')
def save():(matrix/'report.json').write_text(json.dumps(report,indent=2)+'\n')
save()
for model in ['edge','small','base']:
    for runtime in ['onnx-cpu','torch-mps']:
        name=model+'-'+runtime;before=time.monotonic()
        command=[str(repo/'.local/pii-python-v1/bin/python'),str(root/'evaluate-quality-v1.py'),'--plan',str(plan),'--model',model,'--runtime',runtime,'--output',str(matrix/name)]
        timeout=False
        with (matrix/(name+'.log')).open('xb') as log:
            try:result=subprocess.run(command,cwd=repo,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,timeout=600);code=result.returncode
            except subprocess.TimeoutExpired:timeout=True;code=None
        report['operations'].append(dict(model=model,runtime=runtime,exitCode=code,timeout=timeout,elapsedSeconds=time.monotonic()-before));save()
        print(json.dumps(report['operations'][-1]),flush=True)
report['state']='completed' if all(o['exitCode']==0 for o in report['operations']) else 'completed-with-refusals';save()
sys.exit(0 if report['state']=='completed' else 1)
