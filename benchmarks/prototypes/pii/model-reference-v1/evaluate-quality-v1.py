"""Frozen local GLiNER candidate comparison; no raw source/entity text output.

Python reference pipelines are experimental. They are not installed product
backends, production privacy, physical power or whole-competitor acceptance.
"""
import os
os.environ.update(HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',HF_HUB_DISABLE_IMPLICIT_TOKEN='1',TOKENIZERS_PARALLELISM='false',PYTORCH_ENABLE_MPS_FALLBACK='0')
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import resource
import sys
import time

ROOT=Path.cwd().resolve();assert (ROOT/'Package.swift').is_file()
sys.path.insert(0,str(ROOT/'scripts'))
import pii_quality as q


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--plan',type=Path,required=True);p.add_argument('--model',choices=['edge','small','base'],required=True)
    p.add_argument('--runtime',choices=['onnx-cpu','torch-mps'],required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    plan=json.loads(a.plan.read_text());model_plan=plan['models'][a.model];directory=Path(model_plan['directory']);corpus_path=Path(plan['corpusPath'])
    def verify():
        for name,digest in plan['codeSHA256'].items():assert q.sha256(ROOT/name)==digest
        assert q.sha256(corpus_path)==plan['corpusSHA256']
        assert q.sha256(Path(plan['patternPredictionsPath']))==plan['patternPredictionsSHA256']
        for entry in model_plan['files']:assert (directory/entry['path']).stat().st_size==entry['bytes'] and q.sha256(directory/entry['path'])==entry['sha256']
    verify();data=json.loads(corpus_path.read_text());rows=data['rows'];assert len(rows)==153 and data['labels']==plan['labels']
    assert plan['thresholdGrid']==[.3,.5,.7] and plan['initialThreshold']==.5
    baseline=json.loads(Path(plan['patternPredictionsPath']).read_text());patterns={r['id']:r for r in baseline};assert len(patterns)==153 and patterns.keys()=={r['id'] for r in rows}
    for name,version in plan['runtimePins'].items():assert importlib.metadata.version(name)==version
    a.output.mkdir(mode=0o700,parents=True,exist_ok=False)
    report=dict(state='loading',model=a.model,modelRepository=model_plan['repository'],modelRevision=model_plan['revision'],runtime=a.runtime,
        planSHA256=q.sha256(a.plan),corpusSHA256=plan['corpusSHA256'],sources=153,goldValues=250,policyNegativeSources=45,
        scope=plan['scope'],limits=plan['limits'],timings=[],results={},modelOutputsValidated=0,
        sourceTextPublished=False,rawEntityTextPersisted=False,qualityAcceptance=False,productionBackendSelected=False)
    def save():(a.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    save()
    try:
        import numpy as np
        import onnxruntime as ort
        import regex
        import torch
        from gliner import GLiNER
        torch.set_num_threads(4);torch.set_num_interop_threads(1)
        before=time.monotonic()
        if a.runtime=='onnx-cpu':
            options=ort.SessionOptions();options.intra_op_num_threads=4;options.inter_op_num_threads=1
            model=GLiNER.from_pretrained(str(directory),local_files_only=True,token=False,runtime='onnxruntime',runtime_model_file='onnx/model.onnx',runtime_options={'session_options':options,'providers':['CPUExecutionProvider']})
            model.model.session.disable_fallback();assert model.model.session.get_providers()==['CPUExecutionProvider'];report['providers']=model.model.session.get_providers()
        else:
            assert torch.backends.mps.is_available()
            model=GLiNER.from_pretrained(str(directory),local_files_only=True,token=False,map_location='cpu',strict=True,_attn_implementation='eager').eval().to('mps')
            assert all(value.device.type=='mps' for value in model.parameters());report.update(modelTensorDevice='mps',CPUFallbackEnabled=False)
        report['loadSeconds']=time.monotonic()-before
        original=model.run_batch
        def checked(*args,**kwargs):
            output=original(*args,**kwargs);logits=output.logits
            if isinstance(logits,torch.Tensor):
                if a.runtime=='torch-mps':assert logits.device.type=='mps'
                assert bool(torch.isfinite(logits).all().item());shape=list(logits.shape)
            else:
                assert a.runtime=='onnx-cpu' and np.issubdtype(logits.dtype,np.floating) and np.isfinite(logits).all();shape=list(logits.shape)
            assert len(shape) in [3,4] and all(type(n) is int and n>0 for n in shape)
            report['modelOutputsValidated']+=1;report.setdefault('firstOutputShape',shape)
            return output
        model.run_batch=checked
        results={str(t):{kind:[] for kind in ['model','hybrid','typed']} for t in plan['thresholdGrid']}
        def masks(text,spans,label):
            # Unicode graphemes from the pinned reference regex package. Native
            # grapheme behavior remains a separate qualification, not assumed.
            intervals=[(m.start(),m.end()) for m in regex.finditer(r'\X',text)];points={i for s in spans for start,end in intervals if s['start']<end and start<s['end'] for i in range(start,end)}
            merged=[]
            for point in sorted(points):
                if merged and merged[-1]['end']==point:merged[-1]['end']+=1
                else:merged.append(dict(start=point,end=point+1,label=label))
            return merged
        order=[.5,.3,.7];report['state']='running';save()
        for index,row in enumerate(rows):
            digest=hashlib.sha256(row['text'].encode()).hexdigest();assert digest==patterns[row['id']]['sourceSHA256']
            prepared=model.prepare_batch([row['text']],list(plan['labels']));batch=model.collate_batch(prepared['input_x'],prepared['entity_types'],label_names=prepared['label_names'])
            tokens=int(batch['input_ids'].shape[1]);assert tokens<=512 and prepared['valid_texts']==[row['text']]
            for threshold in order:
                if a.runtime=='torch-mps':torch.mps.synchronize()
                start=time.monotonic();entities=model.predict_entities(row['text'],list(plan['labels']),threshold=threshold,flat_ner=True,multi_label=False)
                if a.runtime=='torch-mps':torch.mps.synchronize()
                elapsed=time.monotonic()-start;typed=[]
                for entity in entities:
                    assert type(entity['start']) is int and type(entity['end']) is int and entity['label'] in plan['labels']
                    begin,end=entity['start'],entity['end'];assert entity['text']==row['text'][begin:end]
                    span=dict(start=begin,end=end,label=plan['labels'][entity['label']],score=float(entity['score']))
                    q.validate_span(row['text'],span,set(plan['labels'].values()));typed.append(span)
                model_masks=masks(row['text'],typed,'modelMasks');hybrid=masks(row['text'],model_masks+patterns[row['id']]['spans'],'masks')
                for kind,spans in [('typed',typed),('model',model_masks),('hybrid',hybrid)]:results[str(threshold)][kind].append(dict(id=row['id'],sourceSHA256=digest,spans=spans))
                report['timings'].append(dict(id=row['id'],threshold=threshold,tokens=tokens,elapsedSeconds=elapsed))
            if (index+1)%12==0:report['completedSources']=index+1;save();print(json.dumps(dict(model=a.model,runtime=a.runtime,completed=index+1,total=153)),flush=True)
        assert report['modelOutputsValidated']==459
        for threshold,predictions in results.items():
            measured={}
            for kind,values in predictions.items():
                label='modelMasks' if kind=='model' else 'masks' if kind=='hybrid' else 'typed'
                metric=q.evaluate(rows,values,set(plan['labels'].values())|{label})
                if kind!='typed':metric.pop('exactTypedSpans');metric.pop('perLabel')
                measured[kind]=metric
            report['results'][threshold]=measured
            (a.output/('predictions-'+threshold+'.json')).write_text(json.dumps(predictions,indent=2)+'\n')
        verify();report.update(state='completed',completedSources=153,peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
        if a.runtime=='torch-mps':report['MPSMemory']=dict(currentAllocatedBytes=torch.mps.current_allocated_memory(),driverAllocatedBytes=torch.mps.driver_allocated_memory())
        save();print(json.dumps(dict(state='completed',model=a.model,runtime=a.runtime,quality={t:dict(values=v['hybrid']['fullyCoveredValues'],negativeFlags=v['hybrid']['negativeExamplesWithPrediction']) for t,v in report['results'].items()})),flush=True)
    except BaseException as error:
        report.update(state='failed',errorType=type(error).__name__);save();raise


if __name__=='__main__':main()
