#!/usr/bin/env python3
"""Paired OSwind releases on cloned, explicitly authored archive fixtures."""
import argparse,contextlib,datetime,hashlib,json,math,pathlib,platform,sqlite3,statistics,struct,subprocess,time

def sha(path):
    with pathlib.Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def quantiles(values):
    if not values or any(not isinstance(v,(int,float)) or not math.isfinite(v) or v<0 for v in values):raise ValueError('Invalid measured timings')
    ordered=sorted(values)
    return dict(observations=len(values),medianMS=statistics.median(values),p95MS=ordered[math.ceil(.95*len(values))-1],rawMS=values)

def signature(result):
    if not isinstance(result,dict) or not isinstance(result.get('hits'),list):raise ValueError('Missing actual retrieval results')
    for hit in result['hits']:
        if not isinstance(hit,dict) or not isinstance(hit.get('memory',{}).get('id'),str) or type(hit.get('score')) not in (int,float) or not math.isfinite(hit['score']):raise ValueError('Invalid result identity/score')
    semantic={k:result.get(k) for k in ['hits','warnings','modelID','strategy','resolution']}
    return hashlib.sha256(json.dumps(semantic,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()

def same_results(left,right):
    if signature(left)!=signature(right):raise ValueError('Paired ordered hits/scores/source payloads/warnings differ')

def validate_hits(result,count,label):
    signature(result)
    ids=[]
    for hit in result['hits']:
        memory=hit['memory'];identifier=memory['id']
        if not identifier.startswith('scale-') or not identifier[6:].isdigit():raise ValueError('Unexpected source identity')
        n=int(identifier[6:])
        if identifier!='scale-'+str(n) or not 1<=n<=count or memory.get('text')!='Owned source '+str(n):raise ValueError('Returned source is not an original authored row')
        ids.append(identifier)
    if len(ids)!=len(set(ids)):raise ValueError('Duplicate returned source')
    if label=='empty-scope':
        if ids:raise ValueError('Empty metadata scope returned sources')
    elif label in ['rare-phrase','rare-prefix']:
        if ids!=['scale-'+str(count-1)]:raise ValueError('Rare lookup membership differs')
    elif len(ids)!=100:raise ValueError('Broad query returned incomplete top100')
    if label=='boolean' and 'scale-7' in ids:raise ValueError('Negative phrase was ignored')
    if label=='soft-cue' and ids[0]!='scale-'+str(count-1):raise ValueError('Soft ranking cue did not lead')

def archive_input(path):
    path=path.resolve()
    if (path/'owned-fixture').read_text()!='OSwind authored capture scale fixture v1':raise ValueError('Not the explicit authored scale fixture')
    metadata=json.loads((path/'report.json').read_text())
    if metadata.get('format')!='OSwind owned canonical capture scale component v1' or metadata.get('state')!='completed' or metadata.get('rows') not in [1000,100000,1000000]:raise ValueError('Invalid completed archive receipt')
    database=path/'library/memory.sqlite'
    if database.is_symlink() or not database.is_file():raise ValueError('Archive database must be a regular owned file')
    for suffix in ['-wal','-journal']:
        p=pathlib.Path(str(database)+suffix)
        if p.exists() and p.stat().st_size:raise ValueError('Authored source must have no live journal')
    return database,metadata

def original_rows(library,count):
    digest=hashlib.sha256();rows=0
    with contextlib.closing(sqlite3.connect('file:'+str(library/'memory.sqlite')+'?mode=ro',uri=True)) as db:
        db.execute('PRAGMA trusted_schema=OFF')
        for row in db.execute('SELECT id,timestamp,kind,app,title,url,text,favorite,payload,embedding,embedding_model FROM memories ORDER BY id COLLATE BINARY'):
            identifier,stamp,kind,app,title,url,text,favorite,payload,embedding,model=row
            number=int(identifier.removeprefix('scale-'))
            if not (1<=number<=count and identifier=='scale-'+str(number) and text=='Owned source '+str(number) and stamp==1700000000 and kind=='note' and app=='Owned capture scale' and title=='Scale record' and url is None and favorite==0 and embedding is None and model is None):raise ValueError('Original authored membership/cells differ')
            expected=dict(tags=[],timestamp=721692800,bundleID='',kind='note',text=text,favorite=False,regions=[],id=identifier,title='Scale record',app='Owned capture scale')
            decoded=json.loads(payload)
            if decoded!=expected or decoded.get('favorite') is not False:raise ValueError('Source payload differs from the declared authored fixture')
            for cell in row:
                if cell is None:data=b'N'
                elif isinstance(cell,bytes):data=b'B'+cell
                elif isinstance(cell,str):data=b'T'+cell.encode()
                elif isinstance(cell,int):data=b'I'+struct.pack('<q',cell)
                else:data=b'R'+struct.pack('<d',cell)
                digest.update(struct.pack('<Q',len(data)));digest.update(data)
            rows+=1
        if rows!=count:raise ValueError('Original source count differs')
    return digest.hexdigest()

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('candidate',type=pathlib.Path);p.add_argument('--baseline',required=True,type=pathlib.Path);p.add_argument('--baseline-sha256',required=True);p.add_argument('--archive',required=True,type=pathlib.Path);p.add_argument('--root',required=True,type=pathlib.Path);p.add_argument('--repetitions',type=int,default=5);a=p.parse_args()
    if not 1<=a.repetitions<=15:p.error('Use1..15 paired rounds')
    source,metadata=archive_input(a.archive);count=metadata['rows'];base=a.root.resolve()
    if a.archive.resolve() in base.parents or base in a.archive.resolve().parents:p.error('Output must be separate from the retained archive')
    binaries={'baseline':a.baseline.resolve(),'candidate':a.candidate.resolve()};pins={k:sha(v) for k,v in binaries.items()}
    if pins['baseline']!=a.baseline_sha256 or pins['baseline']==pins['candidate']:p.error('Require the pinned baseline and a distinct candidate binary')
    base.mkdir(mode=0o700,parents=True,exist_ok=False);sourceSHA=sha(source)
    report=dict(format='OSwind paired keyword constraint scale',state='running',rows=count,repetitions=a.repetitions,startedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),hardware=dict(architecture=platform.machine(),macOS=platform.mac_ver()[0]),binaries=pins,archiveDatabaseSHA256=sourceSHA,archiveReceiptSHA256=sha(a.archive/'report.json'),harnessSHA256=sha(__file__),records=[])
    def save():(base/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    save()
    try:
        sourceTruth=original_rows(source.parent,count)
        for profile in binaries:
            library=base/profile/'library';library.mkdir(mode=0o700,parents=True)
            subprocess.run(['cp','-c',str(source),str(library/'memory.sqlite')],check=True);(library/'memory.sqlite').chmod(0o600)
        (base/'owned-fixture.json').write_text(json.dumps(dict(format='OSwind paired keyword constraint fixture v1',normalHistory=False,rows=count,sourceSHA256=sourceSHA),indent=2)+'\n')
        before={k:original_rows(base/k/'library',count) for k in binaries};assert set(before.values())=={sourceTruth}
        cases=[('required','"Owned source"',[],'keyword'),('boolean','"Owned source" AND NOT "7"',[],'keyword'),('soft-cue','"Owned source" '+str(count-1),[],'keyword'),('scoped','"Owned source"',['--app','Owned capture scale'],'keyword'),('rare-phrase','"'+str(count-1)+'"',[],'keyword'),('rare-prefix',str(count-1),[],'keyword'),('empty-scope','"Owned source"',['--app','No matching authored app'],'keyword'),('hybrid-empty-model','"Owned source"',[],'hybrid')]
        def execute(profile,label,query,flags,mode,round,warmup):
            if any(sha(binaries[k])!=pins[k] for k in binaries):raise ValueError('Measured executable changed')
            argv=[str(binaries[profile]),'--data',str(base/profile/'library'),'search','--mode',mode,'--details','--limit','100',*flags,query]
            begin=time.perf_counter();run=subprocess.run(argv,capture_output=True,timeout=120);wall=(time.perf_counter()-begin)*1000
            index=len(report['records']);out=base/f'{index:03}.stdout.json';err=base/f'{index:03}.stderr';out.write_bytes(run.stdout);err.write_bytes(run.stderr)
            record=dict(profile=profile,case=label,mode=mode,round=round,warmup=warmup,processWallMS=wall,returncode=run.returncode,stdout=out.name,stdoutSHA256=sha(out),stderr=err.name,stderrSHA256=sha(err));report['records'].append(record);save()
            if run.returncode:raise ValueError('Actual query failed: '+label+' '+profile)
            result=json.loads(run.stdout);validate_hits(result,count,label)
            duration=result['duration']*1000
            if not math.isfinite(duration) or duration<0 or duration>wall+10:raise ValueError('Invalid reported search duration')
            record.update(searchMS=duration,resultSignature=signature(result),ids=[h['memory']['id'] for h in result['hits']]);save();return result
        for label,query,flags,mode in cases:
            warm={k:execute(k,label,query,flags,mode,-1,True) for k in binaries};same_results(warm['baseline'],warm['candidate'])
            for round in range(a.repetitions):
                pair={k:execute(k,label,query,flags,mode,round,False) for k in (['baseline','candidate'] if round%2==0 else ['candidate','baseline'])};same_results(pair['baseline'],pair['candidate'])
            print(label+' pairs passed',flush=True)
        after={k:original_rows(base/k/'library',count) for k in binaries}
        if before!=after or sha(source)!=sourceSHA:raise ValueError('Original source/archive bytes changed')
        summary={}
        for label,_,_,_ in cases:
            summary[label]={k:{metric:quantiles([r[metric] for r in report['records'] if r['case']==label and r['profile']==k and not r['warmup']]) for metric in ['processWallMS','searchMS']} for k in binaries}
        report.update(state='completed',summary=summary,originalPayloadSHA256Before=before,originalPayloadSHA256After=after,sourceArchiveUnchanged=True,allPairedResultsEqual=True,scope='Alternating paired actual CLI processes on two APFS clones of the same authored archive, one warmup per case/profile. Matched signatures cover ordered hits, scores, complete returned sources, match/passage, warnings/model/strategy/resolution; only elapsed duration is excluded. Separate CLI wall and reported search duration; all raw records retained. Same-device uncontrolled caches/background activity and small samples; no controlled cold-cache, capture/ingestion/GPU/energy/transport throughput or competitor ranking evidence.')
    except BaseException as error:report.update(state='failed',errorType=type(error).__name__,error=str(error)[:1000]);raise
    finally:report['finishedAtUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat();save()
    print(json.dumps(dict(state=report['state'],rows=count,records=len(report['records']),allPairedResultsEqual=True)))

if __name__=='__main__':main()
