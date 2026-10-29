import pathlib,json,hashlib,datetime,struct,subprocess,time,collections,io
import numpy as np,onnx
root=pathlib.Path.cwd();base=root/'.artifacts/native-pii-decoding-v1';out=base/'coreml-bucket-v1';source=root/'.artifacts/pii-model-evaluation-v1/model/onnx/model.onnx';binary=base/'native/native-probe';library=root/'.local/pii-python-v1/lib/python3.12/site-packages/onnxruntime/capi/libonnxruntime.1.24.2.dylib'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
model=onnx.load(source);math_hash=hashlib.sha256(b''.join(x.SerializeToString() for x in [*model.graph.node,*model.graph.initializer])).hexdigest()
for value in model.graph.input:
 dims=[1,1] if value.name=='text_lengths' else [1,128]
 for dim,size in zip(value.type.tensor_type.shape.dim,dims):dim.ClearField('dim_param');dim.dim_value=size
for i,dim in enumerate(model.graph.output[0].type.tensor_type.shape.dim):
 dim.ClearField('dim_param');dim.ClearField('dim_value')
 if i==1:dim.dim_param='source_words'
 else:dim.dim_value={0:1,2:12,3:3}[i]
assert math_hash==hashlib.sha256(b''.join(x.SerializeToString() for x in [*model.graph.node,*model.graph.initializer])).hexdigest();onnx.checker.check_model(model);onnx.save(model,out/'bucket-128.onnx')
for group in range(24):
 raw=(base/f'reference-v2/native-inputs-{group:02d}.bin').read_bytes();stream=io.BytesIO(raw);assert stream.read(12)==b'OSWPII01'+struct.pack('<I',3)
 with (out/f'inputs-{group:02d}.bin').open('xb') as target:
  target.write(raw[:12])
  for case in range(3):
   for index in range(5):
    rank=struct.unpack('<I',stream.read(4))[0];shape=struct.unpack('<'+'Q'*rank,stream.read(8*rank));count=struct.unpack('<Q',stream.read(8))[0];dtype='<f4' if index==4 else '<i8';values=np.frombuffer(stream.read(count*(4 if index==4 else 8)),dtype=dtype).reshape(shape)
    if index<3:
     assert shape[0]==1 and shape[1]<=128
     values=np.pad(values,((0,0),(0,128-shape[1])),constant_values=50283 if index==0 else 0)
    target.write(struct.pack('<I',values.ndim)+struct.pack('<'+'Q'*values.ndim,*values.shape)+struct.pack('<Q',values.size)+values.tobytes())
 assert stream.read(1)==b''
files=[out/'bucket-128.onnx',binary,library,out/'diagnose.py']+[out/f'inputs-{i:02d}.bin' for i in range(24)]
plan={'frozenAtUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'hypothesis':'Fixed128 token inputs, dynamic output word count; metadata-only model change, exact operator/initializer bytes preserved. Masked pad IDs50283, attention/word masks0, actual text_lengths unchanged. Three-source CPU then CoreML smoke; continue72-source CoreML only if both first triplets meet unchanged1e-3 logit tolerance.','sourceModelSHA256':sha(source),'unchangedNodeInitializerSHA256':math_hash,'files':[{'path':str(p.relative_to(root)),'sha256':sha(p)} for p in files],'policy':'MLProgram CPUAndGPU+CPU; provider partition assignment is not physical per-operation GPU placement. No performance winner/new quality acceptance.','confidenceToleranceForLaterComparison':0.001};(out/'plan.json').write_text(json.dumps(plan,indent=2)+'\n');receipt={'state':'running','operations':[]}
def save():(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
def run(group,policy):
 for v in plan['files']:assert sha(root/v['path'])==v['sha256']
 before=time.monotonic();wall=time.time();prefix=policy+f'-{group:02d}'
 with (out/(prefix+'.stdout')).open('xb') as stdout,(out/(prefix+'.stderr')).open('xb') as stderr:p=subprocess.run([str(binary),str(library),str(out/'bucket-128.onnx'),str(out/f'inputs-{group:02d}.bin'),policy,str(out/(prefix+'-profile')),'2',str(out/(prefix+'-actual.bin'))],stdout=stdout,stderr=stderr,timeout=90)
 op={'group':group,'policy':policy,'exitCode':p.returncode,'awakeSeconds':time.monotonic()-before,'systemSeconds':time.time()-wall};receipt['operations'].append(op);save()
 if p.returncode:op['error']=(out/(prefix+'.stderr')).read_text()[-2500:];save();return False
 raw=(out/(prefix+'.stdout')).read_text();start=raw.index('{"state":"completed"');report,end=json.JSONDecoder().raw_decode(raw[start:]);assert not raw[start+end:].strip();op['report']=report;op['frameworkStdoutPrelude']=raw[:start];providers=collections.Counter()
 for profile in out.glob(prefix+'-profile*.json'):
  for node in json.loads(profile.read_text()):
   provider=node.get('args',{}).get('provider')
   if node.get('cat')=='Node' and provider:providers[provider]+=1
 op['profiledNodeInvocations']=dict(providers);save();print(json.dumps({'group':group,'policy':policy,'exitCode':p.returncode,'maxLogitDifference':report['maxAbsoluteLogitDifference'],'providers':dict(providers)}),flush=True);return True
save()
if not run(0,'cpu') or not run(0,'coreml'):receipt['state']='smoke-failed';save();raise SystemExit(1)
for group in range(1,24):
 if not run(group,'coreml'):receipt['state']='later-failed';save();raise SystemExit(1)
receipt['state']='completed';receipt['distinctCoreMLSources']=72;receipt['CoreMLForwardCalls']=144;save()
