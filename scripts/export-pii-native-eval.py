#!/usr/bin/env python3
"""Run the explicit native CPU probe on72 frozen validation tensors.

No model imports, network, normal history or provider calls. The caller must
compile the public C++ probe first and supply the explicit pinned1.24.2 dylib.
All original reference logits, native bytes, reports and profiles are retained.
"""
import argparse,base64,copy,hashlib,io,json,math,pathlib,struct,subprocess,time

ROOT=pathlib.Path(__file__).resolve().parents[1]
def sha(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def output_tensors(path,rows):
    data=path.read_bytes()
    if len(data)>12_000_000:raise ValueError('Native tensor fixture exceeds bound')
    stream=io.BytesIO(data)
    def read(n):
        value=stream.read(n)
        if len(value)!=n:raise ValueError('Truncated native output')
        return value
    if read(8)!=b'OSWPOUT1' or struct.unpack('<I',read(4))[0]!=3:raise ValueError('Native output header differs')
    result=[]
    for row in rows:
        if struct.unpack('<I',read(4))[0]!=4:raise ValueError('Native output rank differs')
        shape=list(struct.unpack('<QQQQ',read(32)));count=struct.unpack('<Q',read(8))[0]
        if shape!=row['shape'] or count!=math.prod(shape) or count>1_000_000:raise ValueError('Native output dimensions differ')
        actual=read(count*4);expected=base64.b64decode(row['logitsBase64'],validate=True);maximum=0
        if len(expected)!=count*4:raise ValueError('Reference tensor byte count differs')
        for (a,),(b,) in zip(struct.iter_unpack('<f',actual),struct.iter_unpack('<f',expected),strict=True):
            if not math.isfinite(a) or not math.isfinite(b):raise ValueError('Nonfinite native/reference output')
            maximum=max(maximum,abs(a-b))
        if maximum>0.001:raise ValueError('Native logit tolerance exceeded')
        result.append((actual,maximum))
    if stream.read(1):raise ValueError('Unexpected native output bytes')
    return result
def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['reference','binary','library','model','output']:p.add_argument('--'+name,required=True,type=pathlib.Path)
    a=p.parse_args();a.output.mkdir(mode=0o700,parents=True,exist_ok=False)
    reference=a.reference/'reference-python-v1.json';original=json.loads(reference.read_text());rows=[r for r in original['rows'] if r['kind']=='model-validation']
    if len(rows)!=72:raise ValueError('Expected72 authored validation tensors')
    manifest=json.loads((ROOT/'models/gliner-pii-edge-source.json').read_text());weight=next(x for x in manifest['modelFiles'] if x['path']=='onnx/model.onnx')
    previous=json.loads((ROOT/'benchmarks/prototypes/pii/observations/native-plan-v2.json').read_text());runtime=next(x for x in previous['inputs'] if x['path'].endswith('libonnxruntime.1.24.2.dylib'))
    if sha(a.model)!=weight['sha256'] or sha(a.library)!=runtime['sha256']:raise ValueError('Pinned model/runtime differs')
    inputs=[a.binary,a.library,a.model,reference,ROOT/'benchmarks/prototypes/pii/native-probe.cpp',pathlib.Path(__file__)]+[a.reference/f'native-inputs-{i:02d}.bin' for i in range(24)]
    pinned=[{'path':str(path.resolve()),'sha256':sha(path)} for path in inputs]
    plan={'format':'OSwind72-source native PII tensor export v1','inputs':pinned,'repetitionsPerInput':2,'distinctSources':72,'forwardCalls':144,'absoluteLogitTolerance':0.001,'scope':'Native CPU fixed tensors, independently matched native Swift input arrays; not a single-process app inference pipeline, power or competitor acceptance.'}
    (a.output/'plan.json').write_text(json.dumps(plan,indent=2)+'\n');receipt={'state':'running','operations':[]};updated=copy.deepcopy(original);updated_rows=[r for r in updated['rows'] if r['kind']=='model-validation'];max_difference=0
    def save():(a.output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    def unchanged():
        for item in pinned:
            if sha(pathlib.Path(item['path']))!=item['sha256']:raise ValueError('Native export input changed')
    save()
    try:
        for group in range(24):
            unchanged();before=time.monotonic();wall=time.time();actual=a.output/f'actual-{group:02d}.bin'
            with (a.output/f'report-{group:02d}.json').open('xb') as stdout,(a.output/f'stderr-{group:02d}.log').open('xb') as stderr:
                process=subprocess.run([str(a.binary.resolve()),str(a.library.resolve()),str(a.model.resolve()),str((a.reference/f'native-inputs-{group:02d}.bin').resolve()),'cpu',str((a.output/f'profile-{group:02d}').resolve()),'2',str(actual.resolve())],stdout=stdout,stderr=stderr,timeout=60)
            operation={'group':group,'exitCode':process.returncode,'awakeSeconds':time.monotonic()-before,'systemSeconds':time.time()-wall};receipt['operations'].append(operation);save();unchanged()
            if process.returncode:raise ValueError('Native probe failed; retained original logs')
            tensors=output_tensors(actual,rows[group*3:group*3+3]);operation['outputSHA256']=sha(actual)
            for index,(data,difference) in enumerate(tensors):
                max_difference=max(max_difference,difference);updated_rows[group*3+index]['logitsBase64']=base64.b64encode(data).decode()
            save();print(json.dumps(operation),flush=True)
        receipt.update(state='completed',distinctSources=72,forwardCalls=144,maximumAbsoluteLogitDifference=max_difference,inputsUnchanged=True)
        updated['nativeLogits']={'planSHA256':sha(a.output/'plan.json'),'originalReferenceSHA256':sha(reference),'nativeProbeSourceSHA256':sha(ROOT/'benchmarks/prototypes/pii/native-probe.cpp'),'binarySHA256':sha(a.binary),'distinctSources':72,'forwardCalls':144,'maximumAbsoluteLogitDifference':max_difference,'scope':plan['scope']}
        data=(json.dumps(updated,ensure_ascii=False,separators=(',',':'))+'\n').encode();(a.output/'reference-native-v1.json').write_bytes(data);receipt['referenceSHA256']=hashlib.sha256(data).hexdigest();save();print(json.dumps(receipt),flush=True)
    except BaseException as error:receipt.update(state='failed',errorType=type(error).__name__);save();raise
if __name__=='__main__':main()
