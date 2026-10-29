#!/usr/bin/env python3
"""Evaluate pinned local GLiNER on validation contracts; never downloads weights.

Requires the separately locked experimental Python environment. These authored
fixtures are not natural-data, privacy, power or shipped-application acceptance.
"""
import os
os.environ.update(HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',HF_HUB_DISABLE_IMPLICIT_TOKEN='1',TOKENIZERS_PARALLELISM='false',PYTORCH_ENABLE_MPS_FALLBACK='0')
import argparse,json,pathlib,time,resource,platform,sys,importlib.metadata,statistics
import pii_quality as q

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--plan',required=True,type=pathlib.Path);p.add_argument('--corpus',required=True,type=pathlib.Path);p.add_argument('--model',required=True,type=pathlib.Path)
    p.add_argument('--runtime',required=True,choices=['torch-cpu','torch-mps','onnx-cpu','onnx-coreml']);p.add_argument('--format',choices=['fp32','fp16','quint8'],default='fp32');p.add_argument('--output',required=True,type=pathlib.Path)
    a=p.parse_args();plan=q.verify_plan(a.plan,a.corpus);a.output.mkdir(mode=0o700,parents=True,exist_ok=False);corpus=json.loads(a.corpus.read_text())
    assert q.sha256(a.corpus)==plan['corpusSHA256'] and platform.system()=='Darwin'
    for item in plan['modelFiles']:assert q.sha256(a.model/item['path'])==item['sha256']
    rows=[x for x in corpus['rows'] if x['split']=='validation'];assert len(rows)==plan['validationCases']
    labels=list(plan['labels']);categories=sorted(set(plan['labels'].values()));thresholds=[plan['initialThreshold']]+[x for x in plan['thresholdGrid'] if x!=plan['initialThreshold']]
    report={'state':'running','runtime':a.runtime,'format':a.format,'corpusSHA256':q.sha256(a.corpus),'planSHA256':q.sha256(a.plan),'harnessSHA256':q.sha256(__file__),'split':'validation','reservedTestOpened':False,'examples':len(rows),'platform':platform.platform(),'limits':['Authored template contract set, not natural desktop or training-independent quality acceptance','Python reference pipeline includes imports/tokenization/decoding; not native app latency or memory','Provider requests do not prove GPU/ANE placement; no energy claim','MPS CPU fallback is disabled; ordinary CPU tokenization/decoding remains','Uncontrolled host/framework/cache state; all timings retained'],'metrics':{}}
    def save(): (a.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    save();started=time.monotonic();wall=time.time()
    try:
        import numpy as np,torch,onnxruntime as ort
        from gliner import GLiNER
        for name,version in plan['runtimePins'].items():assert importlib.metadata.version(name)==version
        torch.set_num_threads(4);torch.set_num_interop_threads(1);report['runtimeVersions']={k:importlib.metadata.version(k) for k in plan['runtimePins']}
        load=time.monotonic()
        if a.runtime.startswith('torch'):
            assert a.format=='fp32'
            model=GLiNER.from_pretrained(str(a.model.resolve()),local_files_only=True,token=False,map_location='cpu',strict=True,_attn_implementation='eager')
            if a.runtime=='torch-mps':
                assert torch.backends.mps.is_available();model=model.to('mps');assert all(x.device.type=='mps' for x in model.parameters())
                report['modelTensorDevice']='mps';report['CPUFallbackEnabled']=False
        else:
            options=ort.SessionOptions();options.intra_op_num_threads=4;options.inter_op_num_threads=1
            providers=['CPUExecutionProvider']
            if a.runtime=='onnx-coreml':
                assert 'CoreMLExecutionProvider' in ort.get_available_providers()
                providers=[('CoreMLExecutionProvider',{'ModelFormat':'MLProgram','MLComputeUnits':'CPUAndGPU','RequireStaticInputShapes':'0','EnableOnSubgraphs':'0'}),'CPUExecutionProvider']
            filename={'fp32':'model.onnx','fp16':'model_fp16.onnx','quint8':'model_quint8.onnx'}[a.format]
            model=GLiNER.from_pretrained(str(a.model.resolve()),local_files_only=True,token=False,runtime='onnxruntime',runtime_model_file='onnx/'+filename,runtime_options={'session_options':options,'providers':providers})
            model.model.session.disable_fallback();report['providers']=model.model.session.get_providers();report['providerOptions']=model.model.session.get_provider_options()
        report['loadSeconds']=time.monotonic()-load
        results={str(t):[] for t in thresholds};timings=[]
        for index,row in enumerate(rows):
            prepared=model.prepare_batch([row['text']],labels);batch=model.collate_batch(prepared['input_x'],prepared['entity_types'],label_names=prepared['label_names'])
            tokens=int(batch['input_ids'].shape[1]);assert tokens<=plan['maximumTokens'] and len(row['text'])<=plan['maximumTextCharacters']
            # Refuse truncation before inference; the fixture splitter owns every
            # non-space character and this short contract set fits the bound.
            assert len(prepared['valid_texts'])==1 and prepared['valid_texts'][0]==row['text']
            for threshold in thresholds:
                if a.runtime=='torch-mps':torch.mps.synchronize()
                before=time.monotonic();system=time.time()
                entities=model.predict_entities(row['text'],labels,threshold=threshold,flat_ner=True,multi_label=False)
                if a.runtime=='torch-mps':torch.mps.synchronize()
                elapsed=time.monotonic()-before;system_elapsed=time.time()-system;spans=[]
                for entity in entities:
                    assert entity['label'] in plan['labels'];start,end=int(entity['start']),int(entity['end']);assert entity['text']==row['text'][start:end]
                    span={'start':start,'end':end,'label':plan['labels'][entity['label']],'promptLabel':entity['label'],'text':entity['text'],'score':float(entity['score']),'utf16':q.utf16_range(row['text'],start,end)}
                    q.validate_span(row['text'],span,categories);spans.append(span)
                results[str(threshold)].append({'id':row['id'],'sourceSHA256':__import__('hashlib').sha256(row['text'].encode()).hexdigest(),'spans':spans})
                timings.append({'id':row['id'],'threshold':threshold,'tokens':tokens,'awakeSeconds':elapsed,'systemSeconds':system_elapsed})
            if (index+1)%12==0:report['completedExamples']=index+1;save();print(json.dumps({'completed':index+1,'total':len(rows)}),flush=True)
        for threshold,values in results.items():
            report['metrics'][threshold]=q.evaluate(rows,values,categories)
            (a.output/('predictions-'+threshold+'.json')).write_text(json.dumps(values,ensure_ascii=False,indent=2)+'\n')
        primary=[x['awakeSeconds'] for x in timings if x['threshold']==plan['initialThreshold']];warm=sorted(primary[1:])
        report['timing']={'firstPredictionSeconds':primary[0],'warmMedianSeconds':statistics.median(warm),'warmP95Seconds':warm[min(len(warm)-1,int(len(warm)*0.95))],'totalAwakeSeconds':time.monotonic()-started,'totalSystemSeconds':time.time()-wall,'samples':len(primary),'scope':'Threshold0.5 first per case; all72 examples including negatives; initial case excluded from warm summaries, no timed samples removed'}
        report['peakRSSBytes']=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        if a.runtime=='torch-mps':report['MPSMemory']={'currentAllocatedBytes':torch.mps.current_allocated_memory(),'driverAllocatedBytes':torch.mps.driver_allocated_memory()}
        (a.output/'timings.json').write_text(json.dumps(timings,indent=2)+'\n');report['state']='completed';save();print(json.dumps(report['metrics']),flush=True)
    except BaseException as error:
        report['state']='failed';report['errorType']=type(error).__name__;save();raise
if __name__=='__main__':main()
