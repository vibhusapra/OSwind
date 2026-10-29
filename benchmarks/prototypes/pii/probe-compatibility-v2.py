import os
os.environ['HF_HUB_OFFLINE']='1';os.environ['TRANSFORMERS_OFFLINE']='1';os.environ['HF_HUB_DISABLE_IMPLICIT_TOKEN']='1';os.environ['TOKENIZERS_PARALLELISM']='false'
import pathlib,json,time,hashlib,numpy as np,torch,onnxruntime as ort
from gliner import GLiNER
b=pathlib.Path('.artifacts/pii-model-evaluation-v1');plan=json.loads((b/'plan-v2.json').read_text());model=b/'model'
assert hashlib.sha256((b/'authored-v1.json').read_bytes()).hexdigest()==plan['corpusSHA256']
for f in plan['modelFiles']:assert hashlib.sha256((model/f['path']).read_bytes()).hexdigest()==f['sha256']
torch.set_num_threads(4);torch.set_num_interop_threads(1)
start=time.monotonic();reference=GLiNER.from_pretrained(str(model.resolve()),local_files_only=True,token=False,map_location='cpu',strict=True,_attn_implementation='eager');loaded=time.monotonic()-start
options=ort.SessionOptions();options.intra_op_num_threads=4;options.inter_op_num_threads=1
session=ort.InferenceSession(str(model/'onnx/model.onnx'),sess_options=options,providers=['CPUExecutionProvider'])
rows=[x for x in json.loads((b/'authored-v1.json').read_text())['rows'] if x['split']=='validation'];labels=list(plan['labels']);out=[]
for index in [0,4,8]:
 row=rows[index];prepared=reference.prepare_batch([row['text']],labels);batch=reference.collate_batch(prepared['input_x'],prepared['entity_types'],label_names=prepared['label_names'])
 feed={x.name:batch[x.name].detach().cpu().numpy() for x in session.get_inputs()}
 assert feed['input_ids'].shape[1]<=plan['maximumTokens']
 with torch.inference_mode():expected=reference.run_batch(batch).logits.detach().cpu().numpy()
 actual=session.run(None,feed)[0]
 assert actual.shape[0]==3 and actual.ndim==4
 converted=np.transpose(actual,(1,2,3,0));assert converted.shape==expected.shape
 maximum=float(np.max(np.abs(expected-converted)));mean=float(np.mean(np.abs(expected-converted)))
 item={'id':row['id'],'inputShape':list(feed['input_ids'].shape),'referenceShape':list(expected.shape),'exportedShape':list(actual.shape),'runtimeLayout':layout,'maximumAbsoluteLogitDifference':maximum,'meanAbsoluteLogitDifference':mean};out.append(item)
 np.savez(b/f'compatibility-{index}-v1.npz',**feed,logits=actual)
 (b/'compatibility-v2.json').write_text(json.dumps({'state':'running','loadSeconds':loaded,'rows':out},indent=2)+'\n');print(json.dumps(item),flush=True)
 assert np.isfinite(expected).all() and np.isfinite(actual).all() and maximum<=plan['compatibilityAbsoluteTolerance']
(b/'compatibility-v2.json').write_text(json.dumps({'state':'completed','loadSeconds':loaded,'rows':out,'providers':session.get_providers(),'scope':'Strict local-only PyTorch weight load versus exact pinned FP32 export on three fixed validation inputs; Actual output axes recorded and checked against current GLiNER; graph dimension names are not treated as shape authority. Not privacy acceptance.'},indent=2)+'\n')
