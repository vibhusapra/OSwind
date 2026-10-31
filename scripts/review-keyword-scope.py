#!/usr/bin/env python3
"""Independent raw-response, source-preservation and quantile review."""
import argparse,hashlib,json,math,pathlib,sqlite3,statistics,struct,contextlib

p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=pathlib.Path);p.add_argument('--archive',required=True,type=pathlib.Path);p.add_argument('--baseline',required=True,type=pathlib.Path);p.add_argument('--candidate',required=True,type=pathlib.Path);a=p.parse_args()
base=a.root.resolve();r=json.loads((base/'report.json').read_text());marker=json.loads((base/'owned-fixture.json').read_text())
assert r['state']=='completed' and marker['format']=='OSwind paired keyword constraint fixture v1' and marker['normalHistory'] is False and marker['rows']==r['rows']
n=r['rows'];rounds=r['repetitions'];assert n in [1000,100000,1000000] and 1<=rounds<=15
def digest(path):
    with path.open('rb') as handle:return hashlib.file_digest(handle,'sha256').hexdigest()
assert (a.archive/'owned-fixture').read_text()=='OSwind authored capture scale fixture v1'
assert digest(a.archive/'library/memory.sqlite')==r['archiveDatabaseSHA256']==marker['sourceSHA256']
assert digest(a.archive/'report.json')==r['archiveReceiptSHA256']
assert {k:digest(path.resolve()) for k,path in [('baseline',a.baseline),('candidate',a.candidate)]}==r['binaries']
assert r['binaries']['baseline']!=r['binaries']['candidate']
assert digest(pathlib.Path(__file__).with_name('benchmark-keyword-scope.py'))==r['harnessSHA256']
cases=['required','boolean','soft-cue','scoped','rare-phrase','rare-prefix','empty-scope','hybrid-empty-model']
expectedSequence=[]
for label in cases:
    expectedSequence.extend([(label,k,-1,True) for k in ['baseline','candidate']])
    for step in range(rounds):expectedSequence.extend((label,k,step,False) for k in (['baseline','candidate'] if step%2==0 else ['candidate','baseline']))
assert [(v['case'],v['profile'],v['round'],v['warmup']) for v in r['records']]==expectedSequence
responses={};verified=0
for i,record in enumerate(r['records']):
    assert record['returncode']==0 and record['stdout']==f'{i:03}.stdout.json' and record['stderr']==f'{i:03}.stderr'
    assert digest(base/record['stdout'])==record['stdoutSHA256'] and digest(base/record['stderr'])==record['stderrSHA256']
    value=json.loads((base/record['stdout']).read_bytes());hits=value['hits'];label=record['case']
    if label=='empty-scope':expected=[]
    elif label in ['rare-phrase','rare-prefix']:expected=[n-1]
    elif label=='boolean':expected=[v for v in range(1,102) if v!=7]
    elif label=='soft-cue':expected=[n-1,*range(1,100)]
    else:expected=list(range(1,101))
    assert [h['memory']['id'] for h in hits]==['scale-'+str(v) for v in expected],(label,record['profile'])
    for position,(hit,number) in enumerate(zip(hits,expected)):
        memory=hit['memory'];assert memory['text']=='Owned source '+str(number) and memory['app']=='Owned capture scale' and memory['title']=='Scale record' and memory['kind']=='note' and memory['favorite'] is False
        assert hit['match']=='keyword' and math.isclose(hit['score'],1/(60+position),rel_tol=0,abs_tol=1e-14)
    semantic={k:value.get(k) for k in ['hits','warnings','modelID','strategy','resolution']}
    encoded=json.dumps(semantic,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode();assert hashlib.sha256(encoded).hexdigest()==record['resultSignature']
    responses[(label,record['round'],record['profile'])]=semantic
    assert isinstance(value['duration'],(int,float)) and math.isfinite(value['duration']) and value['duration']>=0
    assert math.isclose(record['searchMS'],value['duration']*1000,rel_tol=0,abs_tol=1e-12)
    assert math.isfinite(record['processWallMS']) and record['processWallMS']>0 and record['searchMS']<=record['processWallMS']+10
    verified+=1
for label in cases:
    for step in range(-1,rounds):assert responses[(label,step,'baseline')]==responses[(label,step,'candidate')]
    for profile in ['baseline','candidate']:
        for metric in ['processWallMS','searchMS']:
            values=[v[metric] for v in r['records'] if v['case']==label and v['profile']==profile and not v['warmup']];summary=r['summary'][label][profile][metric]
            assert len(values)==summary['observations']==rounds and values==summary['rawMS']
            assert math.isclose(summary['medianMS'],statistics.median(values),rel_tol=0,abs_tol=1e-12)
            assert math.isclose(summary['p95MS'],sorted(values)[math.ceil(.95*len(values))-1],rel_tol=0,abs_tol=1e-12)

def original(library):
    result=hashlib.sha256();count=0
    with contextlib.closing(sqlite3.connect('file:'+str(library/'memory.sqlite')+'?mode=ro',uri=True)) as db:
        db.execute('PRAGMA trusted_schema=OFF')
        for row in db.execute('SELECT id,timestamp,kind,app,title,url,text,favorite,payload,embedding,embedding_model FROM memories ORDER BY id COLLATE BINARY'):
            identifier,stamp,kind,app,title,url,text,favorite,payload,embedding,model=row;number=int(identifier[6:])
            assert 1<=number<=n and identifier=='scale-'+str(number) and text=='Owned source '+str(number) and stamp==1700000000 and kind=='note' and app=='Owned capture scale' and title=='Scale record' and url is None and favorite==0 and embedding is None and model is None
            data=json.loads(payload);assert data==dict(tags=[],timestamp=721692800,bundleID='',kind='note',text=text,favorite=False,regions=[],id=identifier,title='Scale record',app='Owned capture scale') and data['favorite'] is False
            for cell in row:
                tag=b'N' if cell is None else b'B' if isinstance(cell,bytes) else b'T' if isinstance(cell,str) else b'I' if isinstance(cell,int) else b'R'
                body=b'' if cell is None else cell if isinstance(cell,bytes) else cell.encode() if isinstance(cell,str) else struct.pack('<q',cell) if isinstance(cell,int) else struct.pack('<d',cell)
                result.update(struct.pack('<Q',1+len(body)));result.update(tag);result.update(body)
            count+=1
    assert count==n;return result.hexdigest()
originals={k:original(base/k/'library') for k in ['baseline','candidate']};assert originals==r['originalPayloadSHA256Before']==r['originalPayloadSHA256After']
assert original(a.archive/'library')==originals['baseline']==originals['candidate']
review=dict(state='completed',rows=n,records=verified,pairedObservations=verified//2,reportSHA256=digest(base/'report.json'),originalPayloadSHA256=originals,allExactOrderedMembershipAndRRFVerified=True,allPairedReturnedSourcesScoresWarningsAndScopesEqual=True,allRawResponseAndStderrHashesVerified=True,allSearchDurationsMatchActualResponses=True,allQuantilesRecomputed=True,sourceArchiveAndOriginalTypedRowsUnchanged=True,scope='Separate reviewer does not import the benchmark implementation. Actual stdout/stderr hashes, exact authored top100/rare/negative/empty memberships, RRF scores, paired complete results/scopes, response search durations, summary arithmetic and all original typed rows/payloads are checked. Process-wall raw measurements are retained and their quantiles recomputed; this is not an independent clock, cold-cache, power or competitor audit.')
(base/'independent-review.json').write_text(json.dumps(review,indent=2)+'\n');print(json.dumps({k:v for k,v in review.items() if k!='originalPayloadSHA256'}))
