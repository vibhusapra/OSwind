#!/usr/bin/env python3
"""Score actual immutable native CLI learned and hybrid masks independently.

All native calls are history-free stdin inspections. A separate real CLI regex
baseline uses only a new explicit synthetic library. Never scores reserved test
predictions, replicates detectors or chooses masks from gold offsets.
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

ROOT=Path(__file__).resolve().parent.parent
REQUIRED={'scripts/pii_native_quality.py','scripts/test-pii-native-quality.py','scripts/prepare-pii-native-quality.py','scripts/evaluate-pii-native-quality.py'}


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--plan',required=True,type=Path);parser.add_argument('--corpus',required=True,type=Path);parser.add_argument('--output',required=True,type=Path);args=parser.parse_args()
    plan=q.verify_plan(args.plan,args.corpus);assert REQUIRED<=plan['codeSHA256'].keys()
    assert plan['format']=='OSwind native hybrid PII quality plan v1' and plan['thresholdGrid']==[.3,.5,.7] and plan['computes']==['cpu','coreML']
    data=json.loads(args.corpus.read_text());rows=[r for r in data['rows'] if r['split']=='validation']
    assert len(rows)==72==plan['validationCases'] and data['labels']==plan['labels']
    identities=[dict(id=r['id'],sourceSHA256=hashlib.sha256(r['text'].encode()).hexdigest()) for r in rows];assert identities==plan['validationIdentities']
    binary=Path(plan['nativeCLI']['path']);assert plan['nativeCLI']==plan['baselineCLI']
    def verify(assets=False):
        q.verify_plan(args.plan,args.corpus);assert q.sha256(binary)==plan['nativeCLI']['sha256']
        if assets:
            for entry in plan['assets']:
                p=Path(entry['path']);assert p.stat().st_size==entry['bytes'] and q.sha256(p)==entry['sha256']
    verify(True);args.output.mkdir(mode=0o700,parents=True,exist_ok=False)
    report=dict(format='OSwind actual native hybrid PII validation v1',state='running',planSHA256=q.sha256(args.plan),corpusSHA256=q.sha256(args.corpus),binarySHA256=q.sha256(binary),productSource=plan['nativeCLI']['productSource'],split='validation',distinctSources=72,reservedTestPredictionsOpened=False,operations=[],results={},scope=plan['scope'])
    def save():(args.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    def points(spans):return {i for s in spans for i in range(s['start'],s['end'])}
    def metrics(results,kind):
        out=q.evaluate(rows,results,set(plan['labels'].values())|{kind})
        if kind!='typed':out.pop('exactTypedSpans');out.pop('perLabel')
        return out
    all_predictions={};save()
    try:
        with (args.output/'baseline.log').open('xb') as log:
            result=subprocess.run([sys.executable,str(ROOT/'scripts/evaluate-pii-baseline.py'),'--binary',str(binary),'--plan',str(args.plan.resolve()),'--corpus',str(args.corpus.resolve()),'--output',str((args.output/'baseline').resolve())],stdout=log,stderr=subprocess.STDOUT,timeout=600)
        assert result.returncode==0,'Actual regex baseline failed; see retained baseline log'
        pattern=json.loads((args.output/'baseline/predictions.json').read_text());by_id={r['id']:r for r in pattern};assert set(by_id)=={r['id'] for r in rows}
        report['patternBaseline']=json.loads((args.output/'baseline/report.json').read_text())
        for compute in plan['computes']:
            for threshold in plan['thresholdGrid']:
                verify(True);key=compute+'-'+str(threshold);directory=args.output/key;directory.mkdir();predictions={'model':[],'hybrid':[],'typed':[]};receipts=[]
                for index,row in enumerate(rows):
                    verify();before=time.monotonic();wall=time.time()
                    command=[str(binary),'pii','inspect','--model-dir',plan['modelDirectory'],'--runtime-library',plan['runtimeLibrary'],'--compute',compute,'--threshold',str(threshold),'--stdin']
                    with (directory/f'{index:02d}.stdout').open('xb') as stdout,(directory/f'{index:02d}.stderr').open('xb') as stderr:
                        process=subprocess.run(command,input=row['text'].encode(),stdout=stdout,stderr=stderr,timeout=180)
                    out=directory/f'{index:02d}.stdout';err=directory/f'{index:02d}.stderr'
                    operation=dict(compute=compute,threshold=threshold,id=row['id'],exitCode=process.returncode,elapsedSeconds=time.monotonic()-before,wallSeconds=time.time()-wall,stdoutBytes=out.stat().st_size,stderrBytes=err.stat().st_size,stdoutSHA256=q.sha256(out),stderrSHA256=q.sha256(err));report['operations'].append(operation);save()
                    assert process.returncode==0 and out.stat().st_size<=4*1024*1024 and err.stat().st_size<=4*1024*1024,'Native call failed or exceeded output bound'
                    value=json.loads(out.read_bytes());parsed=n.validate_native(row['text'],value,compute,threshold,plan['labels'])
                    assert points(parsed['hybrid'])==points(parsed['model'])|points(by_id[row['id']]['spans']),'Actual hybrid differs from actual learned+shipping-pattern union'
                    assert parsed['patternRedacted']==bool(by_id[row['id']]['spans']),'Native and shipping pattern flags differ'
                    for kind in predictions:predictions[kind].append(dict(id=row['id'],sourceSHA256=parsed['sourceSHA256'],spans=parsed[kind]))
                    receipts.append(dict(id=row['id'],sourceSHA256=parsed['sourceSHA256'],windowCount=value['windowCount'],framedTokens=value['framedTokens'],modelMasks=parsed['model'],hybridMasks=parsed['hybrid'],typed=parsed['typed'],modelRedacted=parsed['modelRedacted'],patternRedacted=parsed['patternRedacted'],suppressMedia=parsed['suppressMedia']))
                measured={kind:metrics(values,'modelMasks' if kind=='model' else 'masks' if kind=='hybrid' else 'typed') for kind,values in predictions.items()}
                report['results'][key]=measured;all_predictions[key]=predictions
                (directory/'predictions.json').write_text(json.dumps(predictions,indent=2)+'\n');(directory/'validated-inspections.json').write_text(json.dumps(receipts,indent=2)+'\n');save()
                print(json.dumps(dict(compute=compute,threshold=threshold,modelValues=measured['model']['fullyCoveredValues'],hybridValues=measured['hybrid']['fullyCoveredValues'],negativeFlags=measured['hybrid']['negativeExamplesWithPrediction'])),flush=True)
        checks={}
        pattern_metrics=report['patternBaseline']['metrics'];checks['patternCounts']=all(pattern_metrics[k]==v for k,v in plan['expectedPatternCounts'].items())
        for threshold in plan['thresholdGrid']:
            cpu=report['results']['cpu-'+str(threshold)];core=report['results']['coreML-'+str(threshold)]
            checks['expectedModelCounts-'+str(threshold)]=all(cpu['model'][k]==v and core['model'][k]==v for k,v in plan['expectedModelOnlyValidationCounts'][str(threshold)].items())
            for kind in ['model','hybrid']:
                checks['sameMasks-'+kind+'-'+str(threshold)]=all_predictions['cpu-'+str(threshold)][kind]==all_predictions['coreML-'+str(threshold)][kind]
        verify(True);report.update(state='completed' if all(checks.values()) else 'reference-difference',referenceChecks=checks,actualNativeCalls=len(report['operations']),unionChecks=432,productionLearnedRedactorSelected=False,qualityAcceptance=False)
        save();assert all(checks.values()),'Native reference/mask differences retained; no automatic acceptance'
    except BaseException as error:
        if report['state']!='reference-difference':report['state']='failed'
        report['errorType']=type(error).__name__;save();raise


if __name__=='__main__':main()
