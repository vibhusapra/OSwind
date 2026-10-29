#!/usr/bin/env python3
r"""Freeze validation-only logits and independent decoding/grapheme references.

Uses pinned local ONNX CPU, the actual GLiNER decoder and regex \X. Corpus JSON
contains both splits; only validation is inferred. No reserved test predictions,
normal history, network or provider credentials. Output directories are exclusive.
"""
import os
os.environ.update(HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',HF_HUB_DISABLE_IMPLICIT_TOKEN='1',TOKENIZERS_PARALLELISM='false')
import argparse,base64,hashlib,importlib.metadata,inspect,json,pathlib,struct
import pii_quality as q

ROOT=pathlib.Path(__file__).resolve().parents[1]
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--model',required=True,type=pathlib.Path);parser.add_argument('--corpus',required=True,type=pathlib.Path);parser.add_argument('--output',required=True,type=pathlib.Path);args=parser.parse_args()
    plan=q.verify_plan(ROOT/'benchmarks/prototypes/pii/plan-v6.json',args.corpus)
    for item in plan['modelFiles']:
        if q.sha256(args.model/item['path'])!=item['sha256']:raise ValueError('Model asset differs')
    for name,version in plan['runtimePins'].items():
        if importlib.metadata.version(name)!=version:raise ValueError('Reference runtime differs')
    args.output.mkdir(parents=True,mode=0o700,exist_ok=False)
    import numpy as np,torch,onnxruntime as ort,regex
    from gliner import GLiNER
    from gliner.decoding.decoder import TokenDecoder
    from gliner.data_processing.tokenizer import WhitespaceTokenSplitter
    torch.set_num_threads(4);torch.set_num_interop_threads(1)
    options=ort.SessionOptions();options.intra_op_num_threads=4;options.inter_op_num_threads=1
    model=GLiNER.from_pretrained(str(args.model.resolve()),local_files_only=True,token=False,runtime='onnxruntime',runtime_model_file='onnx/model.onnx',runtime_options={'session_options':options,'providers':['CPUExecutionProvider']})
    session=model.model.session;session.disable_fallback();decoder=TokenDecoder(model.config);splitter=WhitespaceTokenSplitter();labels=list(plan['labels']);mapping={i+1:label for i,label in enumerate(labels)}
    thresholds=[0.3,0.5,0.7];rows=[];feeds=[]
    def expect(text,words,logits,threshold):
        spans=decoder.decode([[x[0] for x in words]],mapping,model_output=torch.from_numpy(logits),flat_ner=True,multi_label=False,threshold=threshold)[0];predictions=[];masks=[]
        clusters=[m.span() for m in regex.finditer(r'\X',text)]
        for span in spans:
            start=words[span.start][1];end=words[span.end][2]
            predictions.append({'startWord':span.start,'endWord':span.end,'labelIndex':span.class_index,'confidence':float(span.score),'range':q.utf16_range(text,start,end),'text':text[start:end]})
            overlapping=[(a,b) for a,b in clusters if a<end and b>start]
            assert overlapping;masks.append((overlapping[0][0],overlapping[-1][1]))
        merged=[]
        for start,end in sorted(masks):
            if merged and start<=merged[-1][1]:merged[-1]=(merged[-1][0],max(end,merged[-1][1]))
            else:merged.append((start,end))
        masked=text
        for start,end in reversed(merged):masked=masked[:start]+'[REDACTED]'+masked[end:]
        return {'threshold':threshold,'spans':predictions,'redactionRanges':[q.utf16_range(text,a,b) for a,b in merged],'redactedText':masked}
    def row(id,text,logits,kind):
        words=list(splitter(text));assert logits.shape==(1,len(words),12,3) and np.isfinite(logits).all()
        values=np.ascontiguousarray(logits,dtype='<f4')
        return {'id':id,'kind':kind,'text':text,'sourceSHA256':hashlib.sha256(text.encode()).hexdigest(),'shape':list(logits.shape),'logitsBase64':base64.b64encode(values.tobytes()).decode(),'expectations':[expect(text,words,logits,t) for t in thresholds]}
    validation=[r for r in json.loads(args.corpus.read_text())['rows'] if r['split']=='validation'];assert len(validation)==72
    for example in validation:
        prepared=model.prepare_batch([example['text']],labels);batch=model.collate_batch(prepared['input_x'],prepared['entity_types'],label_names=prepared['label_names'])
        feed={x.name:batch[x.name].detach().cpu().numpy() for x in session.get_inputs()};assert feed['input_ids'].shape[1]<=512
        logits=session.run(None,feed)[0];rows.append(row(example['id'],example['text'],logits,'model-validation'));feeds.append((feed,logits))
    # Compare the direct decoder path against previously frozen full-pipeline
    # predictions without changing labels, thresholds, model or corpus.
    for threshold in thresholds:
        frozen=json.loads((ROOT/f'benchmarks/prototypes/pii/observations/onnx-cpu-predictions-{threshold}.json').read_text());by_id={r['id']:r for r in frozen}
        for item in rows:
            actual=next(e for e in item['expectations'] if e['threshold']==threshold)['spans'];gold=by_id[item['id']]['spans']
            assert len(actual)==len(gold)
            for a,g in zip(actual,gold):
                assert a['range']==g['utf16'] and labels[a['labelIndex']]==g['promptLabel'] and abs(a['confidence']-g['score'])<=1e-6
    def authored(name,text,assign):
        words=list(splitter(text));logits=np.full((1,len(words),12,3),-20,dtype=np.float32)
        for word,label,channel,value in assign:logits[0,word,label,channel]=value
        rows.append(row('authored-'+name,text,logits,'authored-logits'))
    def entity(start,end,label=0,start_score=8,end_score=8,inside=8):
        return [(start,label,0,start_score),(end,label,1,end_score)]+[(i,label,2,inside) for i in range(start,end+1)]
    authored('none','Public release note.',[])
    authored('single','owned@example.test',entity(0,0))
    authored('inside-at-half','alpha beta gamma',entity(0,2,inside=0))
    authored('start-at-half','alpha beta',entity(0,1,start_score=0))
    authored('end-at-half','alpha beta',entity(0,1,end_score=0))
    authored('weak-inside','alpha beta',entity(0,1,inside=-0.01))
    authored('class-tie','alpha',entity(0,0,0)+entity(0,0,1))
    authored('end-tie','alpha beta',entity(0,1)+entity(0,0))
    authored('overlap-confidence','alpha beta gamma',entity(0,1,0,start_score=4,end_score=4,inside=4)+entity(1,2,1,start_score=8,end_score=8,inside=8))
    authored('adjacent','alpha beta',entity(0,0,0)+entity(1,1,1))
    authored('longer-than-max-width',' '.join('word'+str(i) for i in range(13)),entity(0,12))
    authored('emoji-union','before 👩🏽‍💻 after',entity(2,2,10)+entity(4,4,10))
    authored('combining','before Cafe\u0301 after',entity(1,1,2))
    authored('variation-selector','before ✈️ after',entity(2,2,10))
    authored('bom','\ufeffprivate value',entity(0,0,10))
    authored('carriage-return','alpha\r\nbeta',entity(0,1,10))
    authored('literal-marker','literal [REDACTED] placeholder',[])
    authored('supplementary-letter','𠀀secret unchanged',entity(0,0,10))
    authored('empty','',[])
    authored('whitespace',' \t\r\n',[])
    # Three source slots per native probe, two repeats each; all72 distinct
    # validation tensors are exported. No source text in the binary fixtures.
    names=['input_ids','attention_mask','words_mask','text_lengths']
    for group in range(24):
        path=args.output/f'native-inputs-{group:02d}.bin'
        with path.open('xb') as output:
            output.write(b'OSWPII01'+struct.pack('<I',3))
            for feed,logits in feeds[group*3:group*3+3]:
                for name,array in [(name,feed[name]) for name in names]+[('logits',logits)]:
                    data=np.ascontiguousarray(array,dtype='<f4' if name=='logits' else '<i8');output.write(struct.pack('<I',data.ndim)+struct.pack('<'+'Q'*data.ndim,*data.shape)+struct.pack('<Q',data.size)+data.tobytes())
    payload={'format':'OSwind native PII decoder reference v1','sourceModelRevision':plan['modelRevision'],'corpusSHA256':plan['corpusSHA256'],'generatorSHA256':q.sha256(pathlib.Path(__file__)),'decoderSourceSHA256':q.sha256(pathlib.Path(inspect.getfile(TokenDecoder))),'runtimePins':plan['runtimePins'],'regexVersion':importlib.metadata.version('regex'),'thresholds':thresholds,'confidenceAbsoluteTolerance':1e-6,'scope':'72 authored validation inputs and20 constructed logit cases. Raw model outputs from ONNX CPU; expected spans actual GLiNER flat/single-label decoder, masks independent regex grapheme expansion. No reserved test inference, representative privacy or application integration acceptance.','rows':rows}
    encoded=(json.dumps(payload,ensure_ascii=False,separators=(',',':'))+'\n').encode();(args.output/'reference-python-v1.json').write_bytes(encoded);print(json.dumps({'rows':len(rows),'SHA256':hashlib.sha256(encoded).hexdigest(),'modelInference':True,'validation':72,'authored':len(rows)-72}),flush=True)
if __name__=='__main__':main()
