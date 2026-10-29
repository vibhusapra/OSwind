#!/usr/bin/env python3
"""Replay public coordinate metrics, optionally full original local outputs.

Public artifacts contain no raw source/entity/rendered text. Literal UTF16 and
rendering checks need both explicit local source and original native receipts.
No inference, download, history access or model package dependency.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import pii_coordinate_quality as c
import pii_native_quality as n
import pii_quality as q

ROOT=Path(__file__).resolve().parent.parent


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--corpus',type=Path);p.add_argument('--native-output',type=Path);a=p.parse_args()
    if bool(a.corpus)!=bool(a.native_output):p.error('Full local replay requires both --corpus and --native-output')
    receipt=json.loads((ROOT/'benchmarks/pii-domain-validation-v1.json').read_text());base=ROOT/'benchmarks';paths={}
    assert receipt['state']=='completed' and receipt['actualNativeCalls']==receipt['actualUnionChecks']==918
    for key in ['rawSourceOrEntityTextPublished','rawNativeOutputTextPublished','qualityAcceptance','releaseAcceptance','competitiveRanking','productionLearnedRedactorSelected']:
        assert receipt[key] is False
    for artifact in receipt['artifacts']:
        relative=Path(artifact['path']);path=(base/relative).resolve()
        assert not relative.is_absolute() and '..' not in relative.parts and path.is_relative_to(base.resolve())
        assert artifact['path'] not in paths and artifact['bytes']<=20*1024*1024 and path.stat().st_size==artifact['bytes'] and q.sha256(path)==artifact['sha256']
        paths[artifact['path']]=path
    assert len(paths)==10
    def read(name):return json.loads(paths['prototypes/pii/gretel-validation-v1/'+name].read_text())
    manifest=read('manifest.json');audit=read('source-admission.json');plan=read('observations-v1/plan.json');rows=manifest['rows']
    assert len(rows)==receipt['distinctSources']==153 and receipt['goldValues']==250 and receipt['policyNegativeSources']==45
    assert manifest['originalLocalCorpusSHA256']==audit['corpusSHA256']==receipt['corpusSHA256']==plan['corpusSHA256']
    assert q.sha256(paths['prototypes/pii/gretel-validation-v1/source-admission.json'])==receipt['sourceAdmissionSHA256']==plan['sourceAdmissionSHA256']
    assert plan['originalPathBearingPlanSHA256']==receipt['planSHA256']
    assert plan['nativeCLI']==plan['baselineCLI'] and plan['nativeCLI']['sha256']==receipt['binarySHA256'] and plan['nativeCLI']['productSource']==receipt['productSource']
    assert plan['labels']==manifest['labels'] and plan['computes']==['cpu','coreML'] and plan['thresholdGrid']==[.3,.5,.7]
    assert [dict(id=r['id'],sourceSHA256=r['sourceSHA256']) for r in rows]==plan['validationIdentities']
    patterns=read('observations-v1/pattern-predictions.json');pattern_by_id={r['id']:r for r in patterns}
    assert len(patterns)==len(pattern_by_id)==153
    def metric(values,kind):
        measured=c.evaluate(rows,values,set(plan['labels'].values())|{kind})
        if kind!='typed':measured.pop('exactTypedSpans');measured.pop('perLabel')
        return measured
    assert metric(patterns,'pattern_redaction')==receipt['patternBaseline']['metrics']
    def points(spans):return {i for s in spans for i in range(s['start'],s['end'])}
    local={}
    if a.corpus:
        assert q.sha256(a.corpus)==receipt['corpusSHA256']
        data=json.loads(a.corpus.read_text());local={r['id']:r for r in data['rows']};assert len(local)==153
        assert q.sha256(a.native_output/'baseline/input.json')==receipt['originalBaselineInputSHA256']
        assert q.sha256(a.native_output/'baseline/output.json')==receipt['originalBaselineExportSHA256']
        exported=json.loads((a.native_output/'baseline/output.json').read_text());exported_by_id={r['id']:r for r in exported};assert len(exported)==len(exported_by_id)==153
        for row in rows:
            assert q.legacy_mask(local[row['id']]['text'],exported_by_id[row['id']]['text'])==pattern_by_id[row['id']]['spans']
    calls=0;all_predictions={};operations=receipt['operations'];assert len(operations)==918
    assert len({(o['compute'],o['threshold'],o['id']) for o in operations})==918
    for compute in plan['computes']:
        for threshold in plan['thresholdGrid']:
            key=compute+'-'+str(threshold);projection=read('observations-v1/'+key+'-coordinates.json')
            selected=[o for o in operations if o['compute']==compute and o['threshold']==threshold]
            assert len(projection)==len(selected)==153 and [r['id'] for r in projection]==[r['id'] for r in rows]==[o['id'] for o in selected]
            predictions={kind:[] for kind in ['model','hybrid','typed']}
            for index,(row,value,operation) in enumerate(zip(rows,projection,selected)):
                assert 'text' not in value and value['sourceSHA256']==row['sourceSHA256']
                assert value['modelID']==n.MODEL_PREFIX+compute and value['compute']==compute and value['threshold']==threshold
                assert operation['exitCode']==0 and operation['stdoutBytes']<=4*1024*1024 and operation['stderrBytes']<=4*1024*1024
                assert value['originalStdoutSHA256']==operation['stdoutSHA256'] and re.fullmatch('[0-9a-f]{64}',value['renderedTextSHA256'])
                for field,limit in [('windowCount',256),('framedTokens',65536)]:assert type(value[field]) is int and 1<=value[field]<=limit
                for kind,label in [('model','modelMasks'),('hybrid','masks')]:
                    previous=-1
                    for span in value[kind]:
                        assert span['label']==label and type(span['start']) is int and type(span['end']) is int and span['start']>previous
                        previous=span['end']
                assert points(value['hybrid'])==points(value['model'])|points(pattern_by_id[row['id']]['spans'])
                assert points(value['typed'])<=points(value['model'])
                for field,expected in [('modelRedacted',bool(value['model'])),('patternRedacted',bool(pattern_by_id[row['id']]['spans'])),('redacted',bool(value['hybrid'])),('suppressMedia',bool(value['hybrid']))]:assert type(value[field]) is bool and value[field]==expected
                for kind in predictions:predictions[kind].append(dict(id=row['id'],sourceSHA256=row['sourceSHA256'],spans=value[kind]))
                if local:
                    output=a.native_output/key/f'{index:03d}.stdout';error=a.native_output/key/f'{index:03d}.stderr'
                    assert output.stat().st_size==operation['stdoutBytes'] and error.stat().st_size==operation['stderrBytes']
                    assert q.sha256(output)==operation['stdoutSHA256'] and q.sha256(error)==operation['stderrSHA256']
                    raw=json.loads(output.read_bytes());parsed=n.validate_native(local[row['id']]['text'],raw,compute,threshold,plan['labels'])
                    assert all(parsed[k]==value[k] for k in parsed) and hashlib.sha256(raw['text'].encode()).hexdigest()==value['renderedTextSHA256']
                calls+=1
            measured={kind:metric(values,'modelMasks' if kind=='model' else 'masks' if kind=='hybrid' else 'typed') for kind,values in predictions.items()}
            assert measured==receipt['results'][key];all_predictions[key]=predictions
            if local:
                for kind,values in predictions.items():
                    label='modelMasks' if kind=='model' else 'masks' if kind=='hybrid' else 'typed'
                    literal=q.evaluate(list(local.values()),values,set(plan['labels'].values())|{label})
                    if kind!='typed':literal.pop('exactTypedSpans');literal.pop('perLabel')
                    assert literal==measured[kind]
    agreement={str(t):{kind:sum(x==y for x,y in zip(all_predictions['cpu-'+str(t)][kind],all_predictions['coreML-'+str(t)][kind])) for kind in ['model','hybrid']} for t in plan['thresholdGrid']}
    assert agreement==receipt['sameMaskSourcesByThreshold'] and calls==918
    print(json.dumps(dict(state='verified-local-literals-and-public-metrics' if local else 'verified-public-coordinate-metrics',storedNativeCalls=918,distinctSources=153,unionChecks=918,artifacts=10,literalOutputChecksPerformed=bool(local),sourceTextPublished=False,qualityAcceptance=False)),flush=True)


if __name__=='__main__':main()
