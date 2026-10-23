#!/usr/bin/env python3
"""Authored long-source semantic regression through isolated real CLI/MCP processes."""
import argparse, datetime, hashlib, json, math, pathlib, sqlite3, statistics, subprocess, tempfile, time
p=argparse.ArgumentParser(); p.add_argument('binary',nargs='?',default='.build/release/oswindctl'); p.add_argument('--provider',choices=['apple','ollama'],default='apple'); p.add_argument('--model',default='qwen3-embedding:0.6b'); p.add_argument('--output',type=pathlib.Path); p.add_argument('--require-recall',action='store_true'); p.add_argument('--answer-provider',choices=['apple','ollama']); p.add_argument('--answer-model',default='qwen3:4b-instruct-2507-q4_K_M'); o=p.parse_args()
binary=pathlib.Path(o.binary).resolve()
background=('Archive maintenance log. Routine filing, window layout and standard office inventory were reviewed without any release decision.\n'*150)
trailer=('General archive housekeeping continued. Empty folders were moved and index pages checked.\n'*75)
cases=[('warehouse','Elian Hart','Frostline operations decision: Elian Hart is responsible for replacing the warehouse signing keys. This depot authentication credential rotation must finish Thursday at noon. The accountable person is Elian Hart and the deadline is Thursday noon.','Who must replace the depot authentication certificates, and what is the due date?'),('accessibility','Val Rivera','Orchard accessibility decision: Val Rivera owns checking keyboard navigation and VoiceOver focus on the new account dialog. The screen reader verification must be completed by Monday. Val Rivera is the assigned reviewer.','Who is assigned to audit the account popup for assistive technology and when?'),('translation','Miriam Chen','Harbor localization decision: Miriam Chen owns verifying the German checkout translations. The linguistic review of the payment flow is due Wednesday afternoon. Miriam Chen is accountable for the German language quality check.','Who is in charge of the German payment translation review, and its deadline?')]
report={'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'script_sha256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),'schema':1,'fixture':'semantic-passages-long-v1','provider':o.provider,'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'scope':'Three authored fictional long records, three paraphrase queries plus one unrelated record. Before/after removes only passage vectors from the same isolated store; base vectors and model stay fixed. Process latencies include CLI startup/model HTTP/coverage/scoring. Not held out, competitor, capture, energy or broad language accuracy.'}
with tempfile.TemporaryDirectory(prefix='oswind-passages-') as d:
    root=pathlib.Path(d); prefix=[str(binary),'--data',str(root/'store')]
    def cli(*args):
        r=subprocess.run(prefix+list(args),capture_output=True,text=True,timeout=240); assert r.returncode==0,(args[0],r.stderr); return r.stdout
    ids=[cli('note','Synthetic seed '+str(i)).strip() for i in range(4)]
    fixture=root/'fixture.json'; cli('export',str(fixture)); rows=json.loads(fixture.read_text())
    byid={r['id']:r for r in rows}
    for i,(_,owner,fact,_) in enumerate(cases): byid[ids[i]].update(title='Archived office record',app='Notes',text=background+fact+'\n'+trailer)
    byid[ids[3]].update(title='Garden notebook',app='Notes',text=('Birdwatching and hiking near the coastal nature reserve. Seasonal flowers bloomed beside the walking trail.\n'*260))
    fixture.write_text(json.dumps(rows)); report['sources']=[{'label':label,'text_utf16_units':len(byid[ids[i]]['text'].encode('utf-16-le'))//2,'fact_offset':len(background),'sha256':hashlib.sha256(byid[ids[i]]['text'].encode()).hexdigest()} for i,(label,*_) in enumerate(cases)]
    cli('import',str(fixture)); start=time.perf_counter()
    if o.provider=='ollama':
        models=json.loads(cli('models','list')); report['model_metadata']=next((m for m in models if m['name']==o.model or m['name']==o.model+':latest'),None)
        cli('reindex','--model',o.model,'--use-model')
    else: cli('reindex','--provider','apple','--use-model')
    report['initial_index_seconds']=time.perf_counter()-start
    db=sqlite3.connect(root/'store/memory.sqlite'); identity=db.execute('select model from vector_keys where ordinal>0 order by model').fetchall(); report['model_ids']=sorted({r[0] for r in identity})
    selected=next(x for x in report['model_ids'] if x.startswith('ollama:')) if o.provider=='ollama' else 'apple-nl-sentence-en-v1'
    report['passages']=db.execute('select count(*) from semantic_passages where model=?',(selected,)).fetchone()[0]
    db.execute('delete from semantic_passages where model=?',(selected,)); db.execute('delete from passage_manifests where model=?',(selected,)); db.commit()
    def measure():
        trials=[]
        for i,(label,owner,fact,query) in enumerate(cases):
            start=time.perf_counter(); result=json.loads(cli('search','--details','--mode','semantic','--limit','3',query)); elapsed=(time.perf_counter()-start)*1000
            hits=result['hits']; rank=next((j+1 for j,h in enumerate(hits) if h['memory']['id']==ids[i]),None)
            found=next((h for h in hits if h['memory']['id']==ids[i]),None); passage=found.get('passage') if found else None
            text=byid[ids[i]]['text']; body=text.encode('utf-16-le')[2*passage['start']:2*(passage['start']+passage['length'])].decode('utf-16-le') if passage else ''
            trials.append({'case':label,'query':query,'rank':rank,'milliseconds':elapsed,'passage':passage,'passage_contains_owner':owner in body,'excerpt':body if owner in body else None,'strategy':result.get('strategy'),'warnings':result['warnings']})
        values=[t['milliseconds'] for t in trials]
        return {'trials':trials,'recall_at_3':sum(t['rank'] is not None for t in trials)/len(trials),'mrr':sum(1/t['rank'] if t['rank'] else 0 for t in trials)/len(trials),'p50_ms':statistics.median(values),'p95_ms':sorted(values)[math.ceil(.95*len(values))-1]}
    report['base_only']=measure(); start=time.perf_counter(); cli('reindex','--provider',o.provider,*(['--model',o.model] if o.provider=='ollama' else [])); report['passage_rebuild_seconds']=time.perf_counter()-start; report['with_passages']=measure()
    request={'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'search_memory','arguments':{'query':cases[0][3],'mode':'semantic','limit':3}}}
    rpc=subprocess.run(prefix+['mcp'],input=json.dumps(request)+'\n',text=True,capture_output=True,timeout=120); assert rpc.returncode==0,rpc.stderr
    response=json.loads(rpc.stdout); content=json.loads(response['result']['content'][0]['text']); report['mcp_passage_returned']=any(h.get('passage') for h in content['hits'])
    if o.answer_provider:
        answers=[]
        for i,(label,owner,fact,query) in enumerate(cases):
            evidence=json.loads(cli('ask','--provider','evidence',query))
            answer=json.loads(cli('ask','--provider',o.answer_provider,*(['--model',o.answer_model] if o.answer_provider=='ollama' else []),query))
            day=['Thursday','Monday','Wednesday'][i]
            answers.append({'context':evidence['text'],'context_has_owner_and_day':owner in evidence['text'] and day in evidence['text'],'case':label,'text':answer['text'],'provider':answer['provider'],'seconds':answer['duration'],'warnings':answer['warnings'],'correct_owner_and_day':owner.split()[0] in answer['text'] and day in answer['text'],'has_citation':'[1]' in answer['text']})
        report['answers']=answers
    config=root/'store/settings.json'; previous=config.read_text(); settings=json.loads(previous); settings['search']['provider']='ollama'; settings['search']['endpoint']='http://127.0.0.1:1'; config.write_text(json.dumps(settings))
    offline_id=cli('note','Synthetic offline ingestion marker').strip(); config.write_text(previous)
    report['offline_note_saved']=db.execute('select count(*) from memories where id=?',(offline_id,)).fetchone()[0]==1; cli('delete',offline_id)
    report['checks']={'offline_note_saved':report['offline_note_saved'],'passages_created' :report['passages']>64,'all_top3':report['with_passages']['recall_at_3']==1,'all_matched_passages_include_owner':all(t['passage_contains_owner'] for t in report['with_passages']['trials']),'mcp_passage_returned':report['mcp_passage_returned']}
    if o.answer_provider: report['checks']['answers_owner_day_and_citations']=all(a['correct_owner_and_day'] and a['has_citation'] for a in report['answers'])
    if o.output: o.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ['provider','passages','initial_index_seconds','passage_rebuild_seconds','checks']},indent=2))
    assert all(report['checks'][key] for key in ['offline_note_saved','passages_created','mcp_passage_returned']), report['checks']
    if o.require_recall: assert all(report['checks'].values()),report['checks']
