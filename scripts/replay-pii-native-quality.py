#!/usr/bin/env python3
"""Recompute public native PII quality receipts offline; no model or library.

This validates stored observations. It does not rerun native inference or claim
representative desktop privacy, physical device placement or release acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import pii_native_quality as n
import pii_quality as q

ROOT=Path(__file__).resolve().parent.parent


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt',type=Path,default=ROOT/'benchmarks/native-hybrid-pii-quality-v1.json')
    args=parser.parse_args();receipt=json.loads(args.receipt.read_text());base=ROOT/'benchmarks'
    assert receipt['state']=='completed' and receipt['actualNativeCalls']==432==receipt['unionChecks']
    assert receipt['distinctSources']==72 and receipt['reservedTestPredictionsOpened'] is False
    assert all(receipt['referenceChecks'].values())
    for key in ['qualityAcceptance','releaseAcceptance','competitiveRanking','productionLearnedRedactorSelected']:
        assert receipt[key] is False
    paths={}
    for artifact in receipt['artifacts']:
        relative=Path(artifact['path']);path=(base/relative).resolve()
        assert not relative.is_absolute() and '..' not in relative.parts and path.is_relative_to(base.resolve())
        assert artifact['path'] not in paths and path.stat().st_size==artifact['bytes'] and q.sha256(path)==artifact['sha256']
        paths[artifact['path']]=path
    assert len(paths)==16
    def read(name):return json.loads(paths['prototypes/pii/native-hybrid-v1/'+name].read_text())
    plan=read('plan.json');validation=read('validation.json');rows=validation['rows'];labels=validation['labels']
    assert len(rows)==72 and len({r['id'] for r in rows})==72 and len({r['text'] for r in rows})==72
    assert all(r['split']=='validation' for r in rows) and labels==plan['labels']
    assert validation['originalFullCorpusSHA256']==receipt['corpusSHA256']==plan['corpusSHA256']
    assert plan['originalPathBearingPlanSHA256']==receipt['originalPlanSHA256']
    assert plan['nativeCLI']['sha256']==receipt['binarySHA256'] and plan['nativeCLI']['productSource']==receipt['productSource']
    assert plan['nativeCLI']==plan['baselineCLI'] and plan['computes']==['cpu','coreML'] and plan['thresholdGrid']==[.3,.5,.7]
    identities=[dict(id=r['id'],sourceSHA256=hashlib.sha256(r['text'].encode()).hexdigest()) for r in rows]
    assert identities==plan['validationIdentities']
    admissions=read('pattern-admissions.json');by_id={r['id']:r for r in admissions}
    assert len(admissions)==72==len(by_id) and by_id.keys()=={r['id'] for r in rows}
    patterns=[]
    for row in rows:
        admission=by_id[row['id']];digest=hashlib.sha256(row['text'].encode()).hexdigest()
        assert admission['sourceSHA256']==digest
        patterns.append(dict(id=row['id'],sourceSHA256=digest,spans=q.legacy_mask(row['text'],admission['text'])))
    assert patterns==read('pattern-predictions.json')
    pattern_by_id={p['id']:p for p in patterns}
    def score(values,kind):
        measured=q.evaluate(rows,values,set(labels.values())|{kind})
        if kind!='typed':measured.pop('exactTypedSpans');measured.pop('perLabel')
        return measured
    pattern_metrics=score(patterns,'pattern_redaction')
    assert pattern_metrics==receipt['patternBaseline']['metrics']
    assert all(pattern_metrics[k]==v for k,v in plan['expectedPatternCounts'].items())
    def points(spans):return {i for span in spans for i in range(span['start'],span['end'])}
    calls=0;results={};operations=receipt['operations'];assert len(operations)==432
    assert len({(o['compute'],o['threshold'],o['id']) for o in operations})==432
    for compute in plan['computes']:
        for threshold in plan['thresholdGrid']:
            key=compute+'-'+str(threshold);raw=read(key+'-native.json');predictions={kind:[] for kind in ['model','hybrid','typed']}
            selected=[o for o in operations if o['compute']==compute and o['threshold']==threshold]
            assert len(raw)==72==len(selected) and [r['id'] for r in raw]==[r['id'] for r in rows]==[o['id'] for o in selected]
            for row,output,operation in zip(rows,raw,selected):
                data=output['stdout'].encode('utf-8')
                assert operation['exitCode']==0 and len(data)==operation['stdoutBytes'] and hashlib.sha256(data).hexdigest()==operation['stdoutSHA256']
                parsed=n.validate_native(row['text'],json.loads(data),compute,threshold,labels)
                assert points(parsed['hybrid'])==points(parsed['model'])|points(pattern_by_id[row['id']]['spans'])
                assert parsed['patternRedacted']==bool(pattern_by_id[row['id']]['spans'])
                for kind in predictions:predictions[kind].append(dict(id=row['id'],sourceSHA256=parsed['sourceSHA256'],spans=parsed[kind]))
                calls+=1
            assert predictions==read(key+'-predictions.json')
            measured={kind:score(values,'modelMasks' if kind=='model' else 'masks' if kind=='hybrid' else 'typed') for kind,values in predictions.items()}
            assert measured==receipt['results'][key]
            assert all(measured['model'][k]==v for k,v in plan['expectedModelOnlyValidationCounts'][str(threshold)].items())
            results[key]=predictions
    for threshold in plan['thresholdGrid']:
        for kind in ['model','hybrid']:assert results['cpu-'+str(threshold)][kind]==results['coreML-'+str(threshold)][kind]
    assert calls==432
    print(json.dumps(dict(state='verified-offline',actualStoredNativeCalls=calls,distinctSources=72,unionChecks=calls,publicArtifacts=len(paths),qualityAcceptance=False,reservedTestPredictionsOpened=False)),flush=True)


if __name__=='__main__':main()
