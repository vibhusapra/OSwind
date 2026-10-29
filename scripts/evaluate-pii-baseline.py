#!/usr/bin/env python3
"""Score actual staged OSwind regex admission on authored validation fixtures.

Uses fresh explicit owned roots and real CLI import/export; no normal library,
provider key, vendor corpus or replicated regex implementation. Timing includes
Apple embeddings/SQLite/process startup and is not sanitizer-only latency.
"""
import argparse,json,pathlib,subprocess,time,hashlib
import pii_quality as q

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',required=True,type=pathlib.Path);p.add_argument('--plan',required=True,type=pathlib.Path);p.add_argument('--corpus',required=True,type=pathlib.Path);p.add_argument('--output',required=True,type=pathlib.Path);a=p.parse_args()
    plan=q.verify_plan(a.plan,a.corpus);a.output.mkdir(mode=0o700,parents=True,exist_ok=False);binary=a.binary.resolve();data=json.loads(a.corpus.read_text());assert q.sha256(a.corpus)==plan['corpusSHA256'] and q.sha256(binary)==plan['baselineCLI']['sha256']
    rows=[r for r in data['rows'] if r['split']=='validation'];assert len(rows)==plan['validationCases'];library=(a.output/'library').resolve()
    payload=[dict(id=r['id'],timestamp='2026-10-28T12:00:00Z',kind='note',app='Owned fixture',bundleID='org.oswind.owned-pii',title='Owned PII contract',text=r['text'],favorite=False,tags=[],regions=[]) for r in rows]
    source=(a.output/'input.json').resolve();export=(a.output/'output.json').resolve();source.write_text(json.dumps(payload,ensure_ascii=False)+'\n');operations=[];report={'state':'running','binarySHA256':q.sha256(binary),'corpusSHA256':q.sha256(a.corpus),'planSHA256':q.sha256(a.plan),'harnessSHA256':q.sha256(__file__),'split':'validation','reservedTestOpened':False,'operations':operations}
    def save():(a.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    def run(name,args):
        assert q.sha256(binary)==report['binarySHA256'];before=time.monotonic();wall=time.time()
        with (a.output/(name+'.stdout')).open('wb') as out,(a.output/(name+'.stderr')).open('wb') as err:result=subprocess.run([str(binary),'--data',str(library),*map(str,args)],stdout=out,stderr=err,timeout=180)
        operations.append({'name':name,'exitCode':result.returncode,'awakeSeconds':time.monotonic()-before,'systemSeconds':time.time()-wall});save();assert result.returncode==0 and q.sha256(binary)==report['binarySHA256']
    save()
    try:
        run('import',['import',source]);run('export',['export',export]);admitted=json.loads(export.read_text());assert len(admitted)==len(rows)
        by_id={x['id']:x for x in admitted};assert len(by_id)==len(rows) and by_id.keys()=={x['id'] for x in rows};results=[]
        for row in rows:
            spans=q.legacy_mask(row['text'],by_id[row['id']]['text']);results.append({'id':row['id'],'sourceSHA256':hashlib.sha256(row['text'].encode()).hexdigest(),'spans':spans})
        metrics=q.evaluate(rows,results,set(plan['labels'].values())|{'pattern_redaction'});metrics.pop('exactTypedSpans');metrics.pop('perLabel')
        report.update(state='completed',metrics=metrics,scope='Actual immutable shipping CLI admission; only unique source/output mask reconstruction accepted. Baseline has no typed spans. Untyped character precision counts removed non-secret context as over-redaction. Operation timing includes embeddings/SQLite/startup, not comparable to model-only latency.')
        (a.output/'predictions.json').write_text(json.dumps(results,indent=2)+'\n');save();print(json.dumps(metrics),flush=True)
    except BaseException as error:report.update(state='failed',errorType=type(error).__name__);save();raise
if __name__=='__main__':main()
