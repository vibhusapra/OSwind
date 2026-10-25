#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["coremltools==9.0", "torch==2.7.0", "transformers==4.57.1", "sentencepiece==0.2.1", "Pillow==11.3.0", "safetensors==0.6.2", "numpy==2.2.6"]
# ///
"""Private pinned native conversion and validation, never normal-history input."""
import pathlib,json,hashlib,time,sys,shutil
root=pathlib.Path.cwd();base=root/'.artifacts/entity-model-prototype-v1';source=base/'distilbert-source';out=base/'distilbert-coreml-fp16-v1';out.mkdir(mode=0o700,exist_ok=False);sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();manifest=json.loads((base/'distilbert-source-manifest.json').read_text())
for f in manifest['files']:assert sha(source/f['path'])==f['sha256']
plan=dict(recipe='oswind-distilbert-ner-256-fp16-v1',sourceManifestSHA256=sha(base/'distilbert-source-manifest.json'),scriptSHA256=sha(pathlib.Path(__file__)),input='input_ids and attention_mask int32[1,256]',output='logits float32[1,256,9]',precision='FP16 graph, FP32 output',minimumDeployment='macOS14',validation='Four authored sentences, CPU-only and CPU/GPU policies; before-quality numeric comparison to FP32 PyTorch CPU, maximum active logit difference<=0.1 and identical active argmax labels. Corpus validation remains separately measured. No test split, provider or product change.')
(out/'plan.json').write_text(json.dumps(plan,indent=2)+'\n')
import torch,transformers,numpy as np,coremltools as ct
tokenizer=transformers.AutoTokenizer.from_pretrained(source,local_files_only=True,trust_remote_code=False);model=transformers.AutoModelForTokenClassification.from_pretrained(source,local_files_only=True,trust_remote_code=False,attn_implementation='eager').eval()
class Wrapper(torch.nn.Module):
 def __init__(self,model):super().__init__();self.model=model
 def forward(self,input_ids,attention_mask):return self.model(input_ids=input_ids,attention_mask=attention_mask).logits
wrapper=Wrapper(model).eval();example=tokenizer('Maya Chen works at Apple in San Francisco.',return_tensors='pt',padding='max_length',max_length=256);inputs=tuple(example[k].to(torch.int32) for k in ['input_ids','attention_mask'])
start=time.monotonic()
with torch.no_grad():traced=torch.jit.trace(wrapper,inputs)
converted=ct.convert(traced,convert_to='mlprogram',inputs=[ct.TensorType(name=k,shape=(1,256),dtype=np.int32) for k in ['input_ids','attention_mask']],outputs=[ct.TensorType(name='logits',dtype=np.float32)],compute_precision=ct.precision.FLOAT16,minimum_deployment_target=ct.target.macOS14,skip_model_load=True)
package=out/'entity.mlpackage';converted.save(str(package));print('Saved new native model package',flush=True);compileStart=time.monotonic();compiled=ct.models.utils.compile_model(str(package),destination_path=str(out/'entity.mlmodelc'));print('Compiled new native model',flush=True)
texts=['Maya Chen works at Apple in San Francisco.','My name is Wolfgang and I live in Berlin.','The weather is clear today.','😀 Zoë visited Paris and met John Smith.'];observations=[]
for policy in [ct.ComputeUnit.CPU_ONLY,ct.ComputeUnit.CPU_AND_GPU]:
 native=ct.models.CompiledMLModel(compiled,compute_units=policy)
 for text in texts:
  encoding=tokenizer(text,return_tensors='pt',padding='max_length',max_length=256);tensors=tuple(encoding[k].to(torch.int32) for k in ['input_ids','attention_mask'])
  with torch.no_grad():expected=wrapper(*tensors).numpy()
  before=time.monotonic();actual=native.predict({k:v.numpy() for k,v in zip(['input_ids','attention_mask'],tensors)})['logits'];elapsed=time.monotonic()-before;active=encoding['attention_mask'][0].numpy().astype(bool);difference=float(np.max(np.abs(actual[0][active]-expected[0][active])));same=bool(np.array_equal(actual.argmax(-1)[0][active],expected.argmax(-1)[0][active]));observation=dict(computePolicy=policy.name,authoredTextSHA256=hashlib.sha256(text.encode()).hexdigest(),activeTokens=int(active.sum()),maximumActiveLogitDifference=difference,activeLabelsIdentical=same,seconds=elapsed);observations.append(observation);(out/'numeric-observations.json').write_text(json.dumps(observations,indent=2)+'\n');print(json.dumps(observation),flush=True)
  assert np.isfinite(actual).all() and difference<=.1 and same,'Native conversion failed declared numerical contract'
files=[dict(path=str(p.relative_to(out)),bytes=p.stat().st_size,sha256=sha(p)) for p in sorted((out/'entity.mlmodelc').rglob('*')) if p.is_file()]
report=dict(state='completed',plan=plan,planSHA256=sha(out/'plan.json'),conversionAndQualificationSeconds=time.monotonic()-start,compileStartOffsetSeconds=compileStart-start,coremltools=ct.__version__,torch=torch.__version__,transformers=transformers.__version__,files=files,numericObservations=observations,actualComputePlacementMeasured=False,scope='Pinned public model; authored numerical fixtures only. Compute policy permits GPU but does not establish actual per-operation placement. No product integration, held-out quality, installed app or normal history.')
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
