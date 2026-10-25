#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["coremltools==9.0", "torch==2.7.0", "transformers==4.57.1", "sentencepiece==0.2.1", "Pillow==11.3.0", "safetensors==0.6.2", "numpy==2.2.6"]
# ///
import pathlib,json,hashlib,numpy as np,transformers,coremltools as ct
base=pathlib.Path('.artifacts/entity-model-prototype-v1');selected=pathlib.Path('.artifacts/entity-quality-v1/corpus/validation-selected.json');assert hashlib.sha256(selected.read_bytes()).hexdigest()=='4548cc513f36d7eef30c240169b0d83fa33a1da125037181666473f7e4a0484d'
model=ct.models.CompiledMLModel(str((base/'distilbert-coreml-fp16-v1/entity.mlmodelc').resolve()),compute_units=ct.ComputeUnit.CPU_AND_GPU);tokenizer=transformers.AutoTokenizer.from_pretrained(base/'distilbert-source',local_files_only=True);fixtures=[]
for row in json.loads(selected.read_text()):
 encoding=tokenizer(' '.join(row['tokens']),return_tensors='np',return_offsets_mapping=True,return_overflowing_tokens=True,padding='max_length',max_length=256,truncation=True,stride=64)
 for n,ids in enumerate(encoding['input_ids']):
  mask=encoding['attention_mask'][n];logits=model.predict(dict(input_ids=ids.reshape(1,256).astype(np.int32),attention_mask=mask.reshape(1,256).astype(np.int32)))['logits'];fixtures.append(dict(id=row['id']+'/'+str(n),ids=ids.tolist(),mask=mask.tolist(),expected=logits.argmax(-1)[0].tolist()))
out=base/'native-inputs-v1.json';assert not out.exists();out.write_text(json.dumps(fixtures,separators=(',',':'))+'\n');print(json.dumps(dict(windows=len(fixtures),sha256=hashlib.sha256(out.read_bytes()).hexdigest())))
