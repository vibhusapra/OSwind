#!/usr/bin/env python3
"""Score the frozen public validation subset through the actual signed CLI.

Separate original-source learned/combined masks, actual shipping-rule baseline,
explicit local assets and no representative/training-unseen acceptance claim.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
import pii_quality as q
import pii_native_quality as n
import pii_domain_quality as d

ROOT=Path(__file__).resolve().parent.parent


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['plan','corpus','source-admission','output']:p.add_argument('--'+name,type=Path,required=True)
    a=p.parse_args();plan=q.verify_plan(a.plan,a.corpus);data=json.loads(a.corpus.read_text());rows=data['rows']
    audit=json.loads(a.source_admission.read_text())
    assert plan['format']=='OSwind public domain native PII quality plan v1' and len(rows)==plan['validationCases']==153
    assert q.sha256(a.source_admission)==plan['sourceAdmissionSHA256'] and audit['corpusSHA256']==q.sha256(a.corpus)
    assert plan['computes']==['cpu','coreML'] and plan['thresholdGrid']==[.3,.5,.7] and plan['plannedNativeCalls']==918
    assert data['labels']==plan['labels'] and data['sourceFileSHA256']==d.PARQUET_SHA256 and plan['selectedSummary']==d.describe(rows)
    assert [dict(id=r['id'],sourceSHA256=hashlib.sha256(r['text'].encode()).hexdigest()) for r in rows]==plan['validationIdentities']
    assert all(r['split']=='validation' for r in rows) and plan['nativeCLI']==plan['baselineCLI']
    binary=Path(plan['nativeCLI']['path'])
    def verify(assets=False):
        q.verify_plan(a.plan,a.corpus);assert q.sha256(a.source_admission)==plan['sourceAdmissionSHA256'] and q.sha256(binary)==plan['nativeCLI']['sha256']
        if assets:
            for item in plan['assets']:
                path=Path(item['path']);assert path.stat().st_size==item['bytes'] and q.sha256(path)==item['sha256']
    verify(True);a.output.mkdir(mode=0o700,parents=True,exist_ok=False)
    report=dict(format='OSwind actual native public domain PII validation v1',state='running',planSHA256=q.sha256(a.plan),
        corpusSHA256=q.sha256(a.corpus),sourceAdmissionSHA256=q.sha256(a.source_admission),binarySHA256=q.sha256(binary),
        productSource=plan['nativeCLI']['productSource'],harnessSource=plan['harnessSource'],split='validation',
        distinctSources=153,goldValues=250,policyNegativeSources=45,sourceDataset=d.DATASET,sourceRevision=d.REVISION,
        publicTestSplitDownloaded=False,authoredReservedTestPredictionsOpened=False,modelTrainingOverlap='unknown',
        selectedSummary=plan['selectedSummary'],operations=[],results={},scope=plan['scope'],acceptance=plan['acceptance'])
    def save():(a.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    def points(spans):return {i for s in spans for i in range(s['start'],s['end'])}
    def metrics(predictions,kind):
        result=q.evaluate(rows,predictions,set(plan['labels'].values())|{kind})
        if kind!='typed':result.pop('exactTypedSpans');result.pop('perLabel')
        return result
    all_predictions={};save()
    try:
        with (a.output/'baseline.log').open('xb') as log:
            result=subprocess.run([sys.executable,str(ROOT/'scripts/evaluate-pii-baseline.py'),'--binary',str(binary),'--plan',str(a.plan.resolve()),'--corpus',str(a.corpus.resolve()),'--output',str((a.output/'baseline').resolve())],stdout=log,stderr=subprocess.STDOUT,timeout=600)
        assert result.returncode==0,'Actual shipping-rule baseline failed; original log retained'
        baseline=json.loads((a.output/'baseline/predictions.json').read_text());by_id={r['id']:r for r in baseline}
        assert len(baseline)==len(by_id)==153 and by_id.keys()=={r['id'] for r in rows}
        report['patternBaseline']=json.loads((a.output/'baseline/report.json').read_text());save()
        for compute in plan['computes']:
            for threshold in plan['thresholdGrid']:
                verify(True);key=compute+'-'+str(threshold);directory=a.output/key;directory.mkdir();predictions={kind:[] for kind in ['model','hybrid','typed']};inspections=[]
                for index,row in enumerate(rows):
                    verify();before=time.monotonic();wall=time.time()
                    command=[str(binary),'pii','inspect','--model-dir',plan['modelDirectory'],'--runtime-library',plan['runtimeLibrary'],'--compute',compute,'--threshold',str(threshold),'--stdin']
                    out=directory/f'{index:03d}.stdout';err=directory/f'{index:03d}.stderr'
                    with out.open('xb') as stdout,err.open('xb') as stderr:
                        process=subprocess.run(command,input=row['text'].encode(),stdout=stdout,stderr=stderr,timeout=180)
                    report['operations'].append(dict(compute=compute,threshold=threshold,id=row['id'],exitCode=process.returncode,elapsedSeconds=time.monotonic()-before,wallSeconds=time.time()-wall,stdoutBytes=out.stat().st_size,stderrBytes=err.stat().st_size,stdoutSHA256=q.sha256(out),stderrSHA256=q.sha256(err)));save()
                    assert process.returncode==0 and out.stat().st_size<=4*1024*1024 and err.stat().st_size<=4*1024*1024,'Native call failed or output budget exceeded; original output retained'
                    value=json.loads(out.read_bytes());parsed=n.validate_native(row['text'],value,compute,threshold,plan['labels'])
                    assert points(parsed['hybrid'])==points(parsed['model'])|points(by_id[row['id']]['spans']),'Actual learned/shipping-pattern union differs'
                    assert parsed['patternRedacted']==bool(by_id[row['id']]['spans'])
                    for kind in predictions:predictions[kind].append(dict(id=row['id'],sourceSHA256=parsed['sourceSHA256'],spans=parsed[kind]))
                    inspections.append(dict(id=row['id'],windowCount=value['windowCount'],framedTokens=value['framedTokens'],**parsed))
                measured={kind:metrics(predictions[kind],'modelMasks' if kind=='model' else 'masks' if kind=='hybrid' else 'typed') for kind in predictions}
                report['results'][key]=measured;all_predictions[key]=predictions
                (directory/'predictions.json').write_text(json.dumps(predictions,indent=2)+'\n');(directory/'validated-inspections.json').write_text(json.dumps(inspections,indent=2)+'\n');save()
                print(json.dumps(dict(compute=compute,threshold=threshold,modelValues=measured['model']['fullyCoveredValues'],hybridValues=measured['hybrid']['fullyCoveredValues'],negativeFlags=measured['hybrid']['negativeExamplesWithPrediction'])),flush=True)
        agreement={}
        for threshold in plan['thresholdGrid']:
            agreement[str(threshold)]={kind:sum(left==right for left,right in zip(all_predictions['cpu-'+str(threshold)][kind],all_predictions['coreML-'+str(threshold)][kind])) for kind in ['model','hybrid']}
        verify(True);assert len(report['operations'])==918
        report.update(state='completed',actualNativeCalls=918,actualUnionChecks=918,sameMaskSourcesByThreshold=agreement,
            backendComparison=plan['backendComparison'],productionLearnedRedactorSelected=False,qualityAcceptance=False,releaseAcceptance=False,competitiveRanking=False)
        save()
    except BaseException as error:
        report.update(state='failed',errorType=type(error).__name__);save();raise


if __name__=='__main__':main()
