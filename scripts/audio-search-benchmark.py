#!/usr/bin/env python3
"""Paired full/preview long-transcript retrieval in separate fresh processes.
Same archive and binary; alternates order. File/OS caches remain uncontrolled.
"""
import argparse,datetime,hashlib,json,pathlib,statistics,subprocess,tempfile,time
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary');p.add_argument('--clips',type=int,default=32);p.add_argument('--words',type=int,default=10000);p.add_argument('--trials',type=int,default=3);p.add_argument('--repetitions',type=int,default=7);p.add_argument('--output',required=True);a=p.parse_args()
assert 1<=a.trials<=10
binary=pathlib.Path(a.binary).resolve()
def run(*args):
    result=subprocess.run([str(binary),'benchmark-audio-search',*map(str,args)],capture_output=True,text=True,timeout=600)
    assert result.returncode==0,(args,result.stderr)
    return json.loads(result.stdout)
with tempfile.TemporaryDirectory(prefix='oswind-audio-search-bench-') as root:
    archive=pathlib.Path(root)/'fixture'
    preparation=run('--archive',archive,'--prepare','--clips',a.clips,'--words',a.words)
    results=[]
    for trial in range(a.trials):
        for mode in (['full','preview'] if trial%2==0 else ['preview','full']):
            before=time.perf_counter();report=run('--archive',archive,'--detail',mode,'--repetitions',a.repetitions)
            report.update(trial=trial,process_wall_seconds=time.perf_counter()-before);results.append(report)
            print(json.dumps({'trial':trial,'mode':mode,'p50_ms':report['p50_ms'],'query_peak_rss_bytes':report['process_query_peak_rss_bytes'],'response_bytes':report['response_bytes']}),flush=True)
    assert len({r['ordered_id_sha256'] for r in results})==1,'Result ranking changed'
    for mode in ['full','preview']:
        assert all(r['build']=='release' for r in results if r['detail']==mode),'Use a release binary for published results'
    summaries={mode:{key:statistics.median(r[key] for r in results if r['detail']==mode) for key in ('p50_ms','p95_ms','process_query_peak_rss_bytes','response_bytes','response_encode_seconds','one_source_hydration_seconds')} for mode in ['full','preview']}
    report={'synthetic':True,'timestamp_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'binary_sha256':hashlib.file_digest(binary.open('rb'),'sha256').hexdigest(),'source_files_sha256':{str(f):hashlib.file_digest(f.open('rb'),'sha256').hexdigest() for f in sorted(pathlib.Path('Sources/OSwindCore').glob('*.swift')) if f.name in {'MemoryStore.swift','SearchPreview.swift','AudioSearchEvaluation.swift','Models.swift','Retrieval.swift','AI.swift'}},'hardware':subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),'macos':subprocess.check_output(['sw_vers','-productVersion'],text=True).strip(),'preparation':preparation,'runs':results,'median_of_process_trials':summaries,'checks':['Identical ordered source IDs across full/preview trials','Every returned source retains complete original text','Full results retain all timed segments; previews explicitly omit them and report counts/revision','Opening one selected result revalidates and returns every timed segment'],'limits':['Synthetic repeated token transcripts; unscoped keyword query only, not natural relevance or model quality','Same binary/archive, alternating order, separate process peaks; caches/background OS activity uncontrolled','Query peak is sampled before response encoding/one-source hydration; all stages reported separately','Raw text remains in previews; this optimizes timed transcript payloads, not arbitrary source length','No capture, power, natural-meeting, competitor or general all-query performance claim']}
    pathlib.Path(a.output).write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'summary':summaries,'output':a.output},indent=2))
