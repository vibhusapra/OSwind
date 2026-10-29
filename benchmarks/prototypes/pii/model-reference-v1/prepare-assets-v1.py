import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import time
import urllib.request

root=Path(__file__).resolve().parent
plan_path=root/'asset-plan-v2.json';plan=json.loads(plan_path.read_text())
assert shutil.disk_usage(root).free>6*1024**3
target=root/'assets-v1';target.mkdir(mode=0o700,exist_ok=False)
receipt=dict(state='preparing',startedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    planSHA256=hashlib.sha256(plan_path.read_bytes()).hexdigest(),files=[],
    concurrentWork='Existing signed native edge-model domain evaluation may be active; these are asset downloads only. No isolated timing or energy claim.',
    predictionsGenerated=False,installedIntoProduct=False)
def save():(root/'asset-receipt-v1.json').write_text(json.dumps(receipt,indent=2)+'\n')
save()
try:
    for model in plan['models']:
        for item in model['files']:
            relative=Path(model['repository'].split('/')[-1])/item['path'];output=target/relative
            assert not output.exists() and '..' not in relative.parts
            output.parent.mkdir(mode=0o700,parents=True,exist_ok=True);partial=output.with_name(output.name+'.partial')
            count=0;sha=hashlib.sha256();git=hashlib.sha1(('blob '+str(item['bytes'])+'\0').encode());before=time.monotonic()
            try:
                with urllib.request.urlopen(item['url'],timeout=60) as response,partial.open('xb') as file:
                    os.chmod(partial,0o600)
                    while True:
                        chunk=response.read(1024*1024)
                        if not chunk:break
                        count+=len(chunk)
                        assert count<=item['bytes'],'Download exceeds pinned size'
                        sha.update(chunk);git.update(chunk);file.write(chunk)
                assert count==item['bytes']
                if item['sha256']:assert sha.hexdigest()==item['sha256']
                else:assert git.hexdigest()==item['gitBlobSHA1']
                partial.rename(output)
            except BaseException:
                partial.unlink(missing_ok=True);raise
            receipt['files'].append(dict(repository=model['repository'],revision=model['revision'],path=str(relative),bytes=count,sha256=sha.hexdigest(),elapsedSeconds=time.monotonic()-before));save()
            print(json.dumps(dict(completedFiles=len(receipt['files']),plannedFiles=14,bytes=count)),flush=True)
    receipt.update(state='prepared',finishedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat());save()
except BaseException as error:
    receipt.update(state='failed',errorType=type(error).__name__);save();raise
