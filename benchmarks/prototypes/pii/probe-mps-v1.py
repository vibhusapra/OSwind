import os
os.environ.update(HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',HF_HUB_DISABLE_IMPLICIT_TOKEN='1',TOKENIZERS_PARALLELISM='false',PYTORCH_ENABLE_MPS_FALLBACK='0')
import pathlib,json,time,torch,numpy as np
from gliner import GLiNER
b=pathlib.Path('.artifacts/pii-model-evaluation-v1');plan=json.loads((b/'plan-v5.json').read_text());rows=[r for r in json.loads((b/'authored-v1.json').read_text())['rows'] if r['split']=='validation'];labels=list(plan['labels'])
torch.set_num_threads(4);torch.set_num_interop_threads(1);assert torch.backends.mps.is_available()
model=GLiNER.from_pretrained(str((b/'model').resolve()),local_files_only=True,token=False,map_location='cpu',strict=True,_attn_implementation='eager').to('mps');assert all(x.device.type=='mps' for x in model.parameters());items=[]
for index in [0,4,8]:
    frozen=np.load(b/f'compatibility-{index}-v3.npz');row=rows[index];prepared=model.prepare_batch([row['text']],labels);batch=model.collate_batch(prepared['input_x'],prepared['entity_types'],label_names=prepared['label_names'])
    for key in ['input_ids','attention_mask','words_mask','text_lengths']:assert np.array_equal(batch[key].cpu().numpy(),frozen[key])
    torch.mps.synchronize();before=time.monotonic();wall=time.time()
    with torch.inference_mode():result=model.run_batch(batch).logits
    torch.mps.synchronize();elapsed=time.monotonic()-before;system=time.time()-wall;assert result.device.type=='mps';actual=result.cpu().numpy();expected=frozen['logits'];assert actual.shape==expected.shape
    difference=float(np.max(np.abs(actual-expected)));item={'id':row['id'],'outputDevice':str(result.device),'shape':list(actual.shape),'maximumAbsoluteLogitDifference':difference,'awakeSeconds':elapsed,'systemSeconds':system};items.append(item);print(json.dumps(item),flush=True)
    (b/'mps-probe-v1.json').write_text(json.dumps({'state':'running','rows':items,'CPUFallbackEnabled':False},indent=2)+'\n');assert np.isfinite(actual).all() and difference<=plan['compatibilityAbsoluteTolerance']
(b/'mps-probe-v1.json').write_text(json.dumps({'state':'completed','rows':items,'CPUFallbackEnabled':False,'modelTensorDevices':sorted({str(x.device) for x in model.parameters()}),'currentMPSAllocatedBytes':torch.mps.current_allocated_memory(),'MPSDriverAllocatedBytes':torch.mps.driver_allocated_memory(),'scope':'Three frozen validation inputs; neural tensors/output on MPS with automatic CPU fallback disabled. CPU tokenization/decoding remain. No native application or power acceptance.'},indent=2)+'\n')
