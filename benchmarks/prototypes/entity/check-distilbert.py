#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["coremltools==9.0", "torch==2.7.0", "transformers==4.57.1", "sentencepiece==0.2.1", "Pillow==11.3.0", "safetensors==0.6.2", "numpy==2.2.6"]
# ///
import pathlib,json,torch,transformers,sys
root=pathlib.Path.cwd();base=root/'.artifacts/entity-model-prototype-v1';path=base/'distilbert-source';tokenizer=transformers.AutoTokenizer.from_pretrained(path,local_files_only=True);model=transformers.AutoModelForTokenClassification.from_pretrained(path,local_files_only=True,attn_implementation='eager').eval()
texts=['Maya Chen works at Apple in San Francisco.','My name is Wolfgang and I live in Berlin.','The weather is clear today.','😀 Zoë visited Paris and met John Smith.']
for text in texts:
 inputs=tokenizer(text,return_tensors='pt',padding='max_length',max_length=256)
 with torch.no_grad():cpu=model(**inputs).logits
 model.to('mps')
 with torch.no_grad():gpu=model(**{k:v.to('mps') for k,v in inputs.items()}).logits.cpu()
 model.to('cpu');active=inputs['attention_mask'][0].bool();print(json.dumps(dict(text=text,maxAbsoluteLogitDifference=float((cpu-gpu).abs().max()),activeArgmaxEqual=bool(torch.equal(cpu.argmax(-1)[0][active],gpu.argmax(-1)[0][active])),tokens=[dict(token=tokenizer.convert_ids_to_tokens(int(i)),cpu=model.config.id2label[int(c)],gpu=model.config.id2label[int(g)]) for i,c,g,a in zip(inputs['input_ids'][0],cpu.argmax(-1)[0],gpu.argmax(-1)[0],inputs['attention_mask'][0]) if a]),ensure_ascii=False),flush=True)
for aggregation in ['simple','first']:
 pipe=transformers.pipeline('token-classification',model=model,tokenizer=tokenizer,aggregation_strategy=aggregation,device=-1)
 for text in texts:print(aggregation,text,[{k:(float(v) if k=='score' else v) for k,v in r.items()} for r in pipe(text)],flush=True)
