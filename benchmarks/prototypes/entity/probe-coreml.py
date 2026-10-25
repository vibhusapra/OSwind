#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["coremltools==9.0", "torch==2.7.0", "transformers==4.57.1", "sentencepiece==0.2.1", "Pillow==11.3.0", "safetensors==0.6.2", "numpy==2.2.6"]
# ///
"""Private validation-only model experiment, never product acceptance."""
import pathlib,json,hashlib,sys,time,resource,os
root=pathlib.Path.cwd();base=root/'.artifacts/entity-model-prototype-v1';modelRoot=base/'distilbert-source';output=base/'distilbert-coreml-validation-v1';output.mkdir(mode=0o700,exist_ok=False)
sys.path.insert(0,str(root/'scripts'));from entity_quality import gold_memberships,score,canonical,utf16_length
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();manifest=json.loads((base/'distilbert-source-manifest.json').read_text())
for item in manifest['files']:assert sha(modelRoot/item['path'])==item['sha256']
selected=root/'.artifacts/entity-quality-v1/corpus/validation-selected.json';frozen=json.loads((root/'benchmarks/entity-membership-plan-v1.json').read_text());assert sha(selected)==frozen['files']['validation']['selectedSHA256'];records=json.loads(selected.read_text());assert len(records)==256
plan=dict(model=manifest['repository'],revision=manifest['revision'],sourceManifestSHA256=sha(base/'distilbert-source-manifest.json'),validationSHA256=sha(selected),scorerSHA256=sha(root/'scripts/entity_quality.py'),scriptSHA256=sha(pathlib.Path(__file__)),runtime='CoreML compiled FP16 graph; CPU_AND_GPU compute policy; actual per-operation placement unmeasured',labels='Pretrained config argmax BIO; PER→person, ORG→organization, LOC→place; MISC ignored',window=256,overlap=64,decode='Group subword pieces by tokenizer word ID, applying the first piece tag to the full word. Adjacent same-kind I words continue a span; B starts a new span. O, different kind and special tokens close a span. Keep exact source slice. Deduplicate typed normalized name per source using first occurrence; cap256.',scope='Validation only. No test inference, product changes, source training, provider, normal history or desktop capture.')
(output/'plan.json').write_text(json.dumps(plan,indent=2)+'\n')
import transformers,coremltools as ct,numpy as np
conversion=base/'distilbert-coreml-fp16-v1';converted=json.loads((conversion/'report.json').read_text());assert converted['state']=='completed'
for item in converted['files']:assert sha(conversion/item['path'])==item['sha256']
start=time.monotonic();tokenizer=transformers.AutoTokenizer.from_pretrained(modelRoot,local_files_only=True,trust_remote_code=False);model=ct.models.CompiledMLModel(str(conversion/'entity.mlmodelc'),compute_units=ct.ComputeUnit.CPU_AND_GPU);loadSeconds=time.monotonic()-start
labels={int(k):v for k,v in json.loads((modelRoot/'config.json').read_text())['id2label'].items()};predictions=[];timings=[];windows=0;limited=0;started=time.monotonic()
for number,record in enumerate(records):
 text,_=gold_memberships(record);encoded=tokenizer(text,return_offsets_mapping=True,return_overflowing_tokens=True,truncation=True,max_length=256,stride=64,padding='max_length',return_tensors='np');offsets=encoded['offset_mapping'].tolist();found={}
 for window,ranges in enumerate(offsets):
  inputs={k:encoded[k][window:window+1].astype(np.int32) for k in ['input_ids','attention_mask']};t=time.monotonic();logits=model.predict(inputs)['logits'];assert logits.shape==(1,256,9) and np.isfinite(logits).all();ids=logits.argmax(-1)[0].tolist();timings.append(time.monotonic()-t);windows+=1;current=None
  def finish():
   global current
   if current is None:return
   kind,a,b=current;surface=text[a:b];key=(kind,canonical(surface))
   if key not in found and len(found)<256:found[key]=dict(source=record['id'],kind=kind,surface=surface,start=utf16_length(text[:a]),length=utf16_length(surface))
   current=None
  words=[];word=None
  for labelID,(a,b),wordID in zip(ids,ranges,encoded.word_ids(batch_index=window)):
   if wordID is None:
    if word is not None:words.append(word);word=None
   elif word is not None and word[0]==wordID:word=(wordID,word[1],word[2],b)
   else:
    if word is not None:words.append(word)
    word=(wordID,labelID,a,b)
  if word is not None:words.append(word)
  for _,labelID,a,b in words:
   label=labels[labelID];kind={'PER':'person','ORG':'organization','LOC':'place'}.get(label.split('-')[-1])
   if a==b or kind is None:finish();continue
   if current and label.startswith('I-') and current[0]==kind:current=(kind,current[1],b)
   else:finish();current=(kind,a,b)
  finish()
 if len(found)>=256:limited+=1
 predictions.extend(found.values())
 if (number+1)%64==0:print(json.dumps(dict(completed=number+1,windows=windows)),flush=True)
elapsed=time.monotonic()-started;predictionPath=output/'predictions.json';predictionPath.write_text(json.dumps(predictions,ensure_ascii=False,indent=2)+'\n')
report=dict(state='completed',plan=plan,planSHA256=sha(output/'plan.json'),runtime=dict(coremltools=ct.__version__,transformers=transformers.__version__,computePolicy='CPU_AND_GPU',actualPerOperationPlacementMeasured=False,loadSeconds=loadSeconds,validationWallSeconds=elapsed,windowInferenceSeconds=timings,windows=windows,processPeakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss),sources=len(records),limitedSources=limited,predictionsSHA256=sha(predictionPath),metrics=score(records,predictions),scope=plan['scope'])
(output/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k not in ['plan','runtime']},indent=2))
