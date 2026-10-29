import os
os.environ.update(HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',HF_HUB_DISABLE_IMPLICIT_TOKEN='1',TOKENIZERS_PARALLELISM='false')
import pathlib,json,time,hashlib,numpy as np,torch,onnxruntime as ort
from gliner import GLiNER
b=pathlib.Path('.artifacts/pii-model-evaluation-v1')
plan=json.loads((b/'plan-v3.json').read_text());model=b/'model'
assert hashlib.sha256((b/'authored-v1.json').read_bytes()).hexdigest()==plan['corpusSHA256']
for item in plan['modelFiles']:
    assert hashlib.sha256((model/item['path']).read_bytes()).hexdigest()==item['sha256']
torch.set_num_threads(4);torch.set_num_interop_threads(1)
start=time.monotonic()
reference=GLiNER.from_pretrained(str(model.resolve()),local_files_only=True,token=False,map_location='cpu',strict=True,_attn_implementation='eager')
loaded=time.monotonic()-start
options=ort.SessionOptions();options.intra_op_num_threads=4;options.inter_op_num_threads=1
session=ort.InferenceSession(str(model/'onnx/model.onnx'),sess_options=options,providers=['CPUExecutionProvider'])
rows=[x for x in json.loads((b/'authored-v1.json').read_text())['rows'] if x['split']=='validation']
labels=list(plan['labels']);observations=[];results=[]
for index in [0,4,8]:
    row=rows[index]
    prepared=reference.prepare_batch([row['text']],labels)
    batch=reference.collate_batch(prepared['input_x'],prepared['entity_types'],label_names=prepared['label_names'])
    feed={x.name:batch[x.name].detach().cpu().numpy() for x in session.get_inputs()}
    assert feed['input_ids'].shape[1]<=plan['maximumTokens']
    with torch.inference_mode():
        expected=reference.run_batch(batch).logits.detach().cpu().numpy()
    actual=session.run(None,feed)[0]
    observed={'id':row['id'],'referenceShape':list(expected.shape),'exportedShape':list(actual.shape)}
    observations.append(observed);(b/'observed-layout-v3.json').write_text(json.dumps(observations,indent=2)+'\n');print(json.dumps(observed),flush=True)
    assert actual.ndim==4
    if actual.shape==expected.shape:
        converted=actual;layout='position-last'
    elif actual.shape[0]==3 and np.transpose(actual,(1,2,3,0)).shape==expected.shape:
        converted=np.transpose(actual,(1,2,3,0));layout='position-first'
    else:
        raise ValueError('Unrecognized exported logit layout')
    maximum=float(np.max(np.abs(expected-converted)))
    mean=float(np.mean(np.abs(expected-converted)))
    item={**observed,'inputShape':list(feed['input_ids'].shape),'runtimeLayout':layout,'maximumAbsoluteLogitDifference':maximum,'meanAbsoluteLogitDifference':mean}
    results.append(item);np.savez(b/f'compatibility-{index}-v3.npz',**feed,logits=actual)
    (b/'compatibility-v3.json').write_text(json.dumps({'state':'running','loadSeconds':loaded,'rows':results},indent=2)+'\n');print(json.dumps(item),flush=True)
    assert np.isfinite(expected).all() and np.isfinite(actual).all() and maximum<=plan['compatibilityAbsoluteTolerance']
(b/'compatibility-v3.json').write_text(json.dumps({'state':'completed','loadSeconds':loaded,'rows':results,'providers':session.get_providers(),'scope':'Strict local-only PyTorch weight load versus exact pinned FP32 ONNX on three fixed validation inputs; runtime axes recorded and numerical agreement required. Not privacy or native application acceptance.'},indent=2)+'\n')
