import pathlib,json,hashlib,datetime,struct
import numpy as np,onnx
root=pathlib.Path('.artifacts/pii-model-evaluation-v1');out=root/'native/static-diagnostic-v1';source=root/'model/onnx/model.onnx';frozen=np.load(root/'compatibility-0-v3.npz',allow_pickle=False)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
plan={'frozenAtUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'hypothesis':'One bounded diagnostic of static input/output metadata versus dynamic graph. A success would not establish dynamic/native tokenizer/decoder or actual GPU node placement. No operator/initializer transforms, one already-opened validation input repeated30 times.','sourceModelSHA256':sha(source),'fixtureSHA256':sha(root/'compatibility-0-v3.npz'),'binarySHA256':sha(root/'native/run-v2/native-probe'),'absoluteTolerance':0.001,'policiesInOrder':['cpu','coreml'],'repetitions':10}
model=onnx.load(source);math_before=hashlib.sha256(b''.join(x.SerializeToString() for x in [*model.graph.node,*model.graph.initializer])).hexdigest()
for value in model.graph.input:
 shape=frozen[value.name].shape;assert len(shape)==len(value.type.tensor_type.shape.dim)
 for dim,size in zip(value.type.tensor_type.shape.dim,shape):dim.ClearField('dim_param');dim.dim_value=size
for dim,size in zip(model.graph.output[0].type.tensor_type.shape.dim,frozen['logits'].shape):dim.ClearField('dim_param');dim.dim_value=size
assert math_before==hashlib.sha256(b''.join(x.SerializeToString() for x in [*model.graph.node,*model.graph.initializer])).hexdigest();onnx.checker.check_model(model);onnx.save(model,out/'static.onnx');plan['staticModelSHA256']=sha(out/'static.onnx');plan['unchangedNodeInitializerSHA256']=math_before
with (out/'fixture.bin').open('xb') as output:
 output.write(b'OSWPII01'+struct.pack('<I',3))
 for repeat in range(3):
  for name in ['input_ids','attention_mask','words_mask','text_lengths','logits']:
   a=np.ascontiguousarray(frozen[name],dtype='<f4' if name=='logits' else '<i8');output.write(struct.pack('<I',a.ndim)+struct.pack('<'+'Q'*a.ndim,*a.shape)+struct.pack('<Q',a.size)+a.tobytes())
plan['fixedInputShapes']={k:list(frozen[k].shape) for k in frozen.files};plan['nativeFixtureSHA256']=sha(out/'fixture.bin');plan['preparationScriptSHA256']=sha(out/'prepare.py');(out/'plan.json').write_text(json.dumps(plan,indent=2)+'\n');print(json.dumps(plan))
