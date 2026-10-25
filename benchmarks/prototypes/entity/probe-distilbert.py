#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["coremltools==9.0", "torch==2.7.0", "transformers==4.57.1", "sentencepiece==0.2.1", "Pillow==11.3.0", "safetensors==0.6.2", "numpy==2.2.6"]
# ///
"""Private validation-only model experiment, never product acceptance."""
import pathlib,json,hashlib,sys,time,resource,os
root=pathlib.Path.cwd();base=root/'.artifacts/entity-model-prototype-v1';modelRoot=base/'distilbert-source';output=base/'distilbert-mps-validation-v1';output.mkdir(mode=0o700,exist_ok=False)
sys.path.insert(0,str(root/'scripts'));from entity_quality import gold_memberships,score,canonical,utf16_length
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();manifest=json.loads((base/'distilbert-source-manifest.json').read_text())
for item in manifest['files']:assert sha(modelRoot/item['path'])==item['sha256']
selected=root/'.artifacts/entity-quality-v1/corpus/validation-selected.json';frozen=json.loads((root/'benchmarks/entity-membership-plan-v1.json').read_text());assert sha(selected)==frozen['files']['validation']['selectedSHA256'];records=json.loads(selected.read_text());assert len(records)==256
plan=dict(model=manifest['repository'],revision=manifest['revision'],sourceManifestSHA256=sha(base/'distilbert-source-manifest.json'),validationSHA256=sha(selected),scorerSHA256=sha(root/'scripts/entity_quality.py'),scriptSHA256=sha(pathlib.Path(__file__)),runtime='PyTorch2.7.0 float32 MPS; fallback disabled',labels='Pretrained config argmax BIO; PER→person, ORG→organization, LOC→place; MISC ignored',window=256,overlap=64,decode='Adjacent same-kind I tokens continue a span; B starts a new span. O, different kind and special tokens close a span. Keep exact source slice. Deduplicate typed normalized name per source using first occurrence; cap256.',scope='Validation only. No test inference, product changes, source training, provider, normal history or desktop capture.')
(output/'plan.json').write_text(json.dumps(plan,indent=2)+'\n')
import torch,transformers
assert torch.backends.mps.is_available() and os.environ.get('PYTORCH_ENABLE_MPS_FALLBACK')=='0'
start=time.monotonic();tokenizer=transformers.AutoTokenizer.from_pretrained(modelRoot,local_files_only=True,trust_remote_code=False);model=transformers.AutoModelForTokenClassification.from_pretrained(modelRoot,local_files_only=True,trust_remote_code=False,attn_implementation='eager',torch_dtype=torch.float32).eval().to('mps');torch.mps.synchronize();loadSeconds=time.monotonic()-start
assert all(p.device.type=='mps' for p in model.parameters());labels=model.config.id2label;predictions=[];timings=[];windows=0;limited=0;started=time.monotonic()
for number,record in enumerate(records):
 text,_=gold_memberships(record);encoded=tokenizer(text,return_offsets_mapping=True,return_overflowing_tokens=True,truncation=True,max_length=256,stride=64,padding='max_length',return_tensors='pt');offsets=encoded['offset_mapping'].tolist();found={}
 for window,ranges in enumerate(offsets):
  inputs={k:encoded[k][window:window+1].to('mps') for k in ['input_ids','attention_mask']};torch.mps.synchronize();t=time.monotonic()
  with torch.inference_mode():logits=model(**inputs).logits
  assert logits.device.type=='mps';ids=logits.argmax(-1).cpu().tolist()[0];torch.mps.synchronize();timings.append(time.monotonic()-t);windows+=1;current=None
  def finish():
   global current
   if current is None:return
   kind,a,b=current;surface=text[a:b];key=(kind,canonical(surface))
   if key not in found and len(found)<256:found[key]=dict(source=record['id'],kind=kind,surface=surface,start=utf16_length(text[:a]),length=utf16_length(surface))
   current=None
  for labelID,(a,b) in zip(ids,ranges):
   label=labels[labelID];kind={'PER':'person','ORG':'organization','LOC':'place'}.get(label.split('-')[-1])
   if a==b or kind is None:finish();continue
   if current and label.startswith('I-') and current[0]==kind:current=(kind,current[1],b)
   else:finish();current=(kind,a,b)
  finish()
 if len(found)>=256:limited+=1
 predictions.extend(found.values())
 if (number+1)%64==0:print(json.dumps(dict(completed=number+1,windows=windows)),flush=True)
elapsed=time.monotonic()-started;predictionPath=output/'predictions.json';predictionPath.write_text(json.dumps(predictions,ensure_ascii=False,indent=2)+'\n')
report=dict(state='completed',plan=plan,planSHA256=sha(output/'plan.json'),runtime=dict(torch=torch.__version__,transformers=transformers.__version__,actualParameterDevice='mps',actualLogitDevice='mps',fallbackEnabled=False,loadSeconds=loadSeconds,validationWallSeconds=elapsed,windowInferenceSeconds=timings,windows=windows,currentMPSBytes=torch.mps.current_allocated_memory(),driverMPSBytes=torch.mps.driver_allocated_memory(),processPeakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss),sources=len(records),limitedSources=limited,predictionsSHA256=sha(predictionPath),metrics=score(records,predictions),scope=plan['scope'])
(output/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k not in ['plan','runtime']},indent=2))
