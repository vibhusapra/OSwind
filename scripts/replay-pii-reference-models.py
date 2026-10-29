#!/usr/bin/env python3
"""Recompute stored local-model coordinate metrics without model dependencies."""
import json
from pathlib import Path
import pii_coordinate_quality as c
import pii_quality as q

ROOT=Path(__file__).resolve().parent.parent


def main():
    base=ROOT/'benchmarks';receipt=json.loads((base/'pii-reference-models-v1.json').read_text());paths={}
    assert receipt['state']=='completed' and receipt['neuralOutputsValidated']==2754 and receipt['coordinateMetricGroupsRecomputed']==54
    for key in ['productionBackendSelected','qualityAcceptance','releaseAcceptance','competitiveRanking','rawSourceOrEntityTextPublished']:assert receipt[key] is False
    for item in receipt['artifacts']:
        relative=Path(item['path']);path=(base/relative).resolve()
        assert not relative.is_absolute() and '..' not in relative.parts and path.is_relative_to(base.resolve())
        assert item['path'] not in paths and item['bytes']<=20*1024*1024 and path.stat().st_size==item['bytes'] and q.sha256(path)==item['sha256']
        paths[item['path']]=path
    assert len(paths)==37
    def read(path):return json.loads(paths[path].read_text())
    prefix='prototypes/pii/model-reference-v1/'
    plan=read(prefix+'plan.json');manifest=read('prototypes/pii/gretel-validation-v1/manifest.json');rows=manifest['rows']
    patterns=read('prototypes/pii/gretel-validation-v1/observations-v1/pattern-predictions.json');by_id={r['id']:r for r in patterns}
    assert plan['originalPathBearingPlanSHA256']==receipt['originalPlanSHA256'] and plan['corpusSHA256']==receipt['corpusSHA256']==manifest['originalLocalCorpusSHA256']
    assert len(rows)==153 and len(patterns)==len(by_id)==153 and plan['labels']==manifest['labels'] and plan['thresholdGrid']==[.3,.5,.7]
    matrix=receipt['matrix'];assert matrix['state']=='completed' and len(matrix['operations'])==6 and all(o['exitCode']==0 and o['timeout'] is False for o in matrix['operations'])
    def points(spans):return {i for span in spans for i in range(span['start'],span['end'])}
    def measure(predictions,kind):
        label='modelMasks' if kind=='model' else 'masks' if kind=='hybrid' else 'typed'
        result=c.evaluate(rows,predictions,set(plan['labels'].values())|{label})
        if kind!='typed':result.pop('exactTypedSpans');result.pop('perLabel')
        return result
    predictions={};groups=0;outputs=0
    for model in ['edge','small','base']:
        for runtime in ['onnx-cpu','torch-mps']:
            name=model+'-'+runtime;report=read(prefix+name+'/report.json')
            assert report['state']=='completed' and report['modelOutputsValidated']==459 and report['completedSources']==153
            assert report['planSHA256']==receipt['originalPlanSHA256'] and report['corpusSHA256']==receipt['corpusSHA256']
            assert report['model']==model and report['runtime']==runtime and report['modelRepository']==plan['models'][model]['repository'] and report['modelRevision']==plan['models'][model]['revision']
            assert report['qualityAcceptance'] is False and report['productionBackendSelected'] is False and report['sourceTextPublished'] is False and report['rawEntityTextPersisted'] is False
            assert len(report['timings'])==459 and len({(t['id'],t['threshold']) for t in report['timings']})==459
            if runtime=='torch-mps':assert report['modelTensorDevice']=='mps' and report['CPUFallbackEnabled'] is False
            else:assert report['providers']==['CPUExecutionProvider']
            outputs+=report['modelOutputsValidated'];predictions[name]={}
            for threshold in ['0.3','0.5','0.7']:
                values=read(prefix+name+'/predictions-'+threshold+'.json');assert set(values)== {'model','hybrid','typed'}
                for kind in values:assert measure(values[kind],kind)==report['results'][threshold][kind];groups+=1
                assert [v['id'] for v in values['model']]==[v['id'] for v in rows]==[v['id'] for v in values['hybrid']]==[v['id'] for v in values['typed']]
                for model_mask,hybrid,typed in zip(values['model'],values['hybrid'],values['typed']):
                    assert points(hybrid['spans'])==points(model_mask['spans'])|points(by_id[model_mask['id']]['spans'])
                    assert points(typed['spans'])<=points(model_mask['spans'])
                predictions[name][threshold]=values
    agreement={}
    for model in ['edge','small','base']:
        pairs={}
        for threshold in ['0.3','0.5','0.7']:
            cpu=predictions[model+'-onnx-cpu'][threshold];gpu=predictions[model+'-torch-mps'][threshold];same={k:sum(x==y for x,y in zip(cpu[k],gpu[k])) for k in ['model','hybrid']};typed_same=0;maximum=0
            for aa,bb in zip(cpu['typed'],gpu['typed']):
                def mapped(value):
                    out={}
                    for span in value['spans']:
                        key=(span['label'],span['start'],span['end']);out[key]=max(out.get(key,0),span['score'])
                    return out
                left,right=mapped(aa),mapped(bb)
                if left.keys()==right.keys():
                    typed_same+=1
                    for k in left:maximum=max(maximum,abs(left[k]-right[k]))
            pairs[threshold]=dict(exactModelMasks=same['model'],exactCombinedMasks=same['hybrid'],sameTypedCategoriesAndCoordinates=typed_same,maxConfidenceDifferenceOnMatchingSpans=maximum)
        agreement[model]=pairs
    assert agreement==receipt['compatibility']['backendAgreement']
    native_agreement={}
    for threshold in ['0.3','0.5','0.7']:
        original=read('prototypes/pii/gretel-validation-v1/observations-v1/cpu-'+threshold+'-coordinates.json')
        projected={k:[dict(id=v['id'],sourceSHA256=v['sourceSHA256'],spans=v[k]) for v in original] for k in ['model','hybrid']}
        native_agreement[threshold]={k:sum(x==y for x,y in zip(projected[k],predictions['edge-onnx-cpu'][threshold][k])) for k in ['model','hybrid']}
    assert native_agreement==receipt['compatibility']['nativeCPUAndReferenceEdgeMaskAgreement'] and outputs==2754 and groups==54
    print(json.dumps(dict(state='verified-stored-reference-coordinates',storedNeuralOutputs=2754,distinctSources=153,models=3,metricGroups=54,artifacts=37,liveInferencePerformed=False,sourceTextPublished=False,qualityAcceptance=False)),flush=True)


if __name__=='__main__':main()
