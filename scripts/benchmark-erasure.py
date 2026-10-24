#!/usr/bin/env python3
"""Generated source/media erasure scaling trial. Never opens an existing fixture/library."""
import argparse, hashlib, json, pathlib, re, sqlite3, subprocess, time
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary');p.add_argument('--root',required=True);p.add_argument('--records',type=int,default=20000);p.add_argument('--retention',action='store_true',help='Exercise age-based prune with alternating old/future captures');o=p.parse_args()
assert o.records>=2 and o.records%2==0
binary=pathlib.Path(o.binary).resolve();digest=hashlib.sha256(binary.read_bytes()).hexdigest();root=pathlib.Path(o.root).resolve();root.mkdir(mode=0o700);library=root/'library'
def run(label,*args):
    stdout=root/(label+'.json');stderr=root/(label+'.stderr');metrics=root/(label+'.time');start=time.perf_counter()
    with stdout.open('w') as output,stderr.open('w') as error:
        subprocess.run(['/usr/bin/time','-l','-o',str(metrics),str(binary),'--data',str(library),*map(str,args)],stdout=output,stderr=error,check=True,timeout=600)
    elapsed=time.perf_counter()-start;raw=metrics.read_text();match=re.search(r'(\d+)\s+maximum resident set size',raw)
    return json.loads(stdout.read_text()) if stdout.read_text().lstrip().startswith(('{','[')) else stdout.read_text().strip(),dict(wall_seconds=elapsed,peak_rss_bytes=int(match[1]) if match else None)
seed,_=run('seed','note','Owned generated erasure seed')
with sqlite3.connect(library/'memory.sqlite') as db:
    db.execute('PRAGMA foreign_keys=ON');template=json.loads(db.execute('SELECT payload FROM memories').fetchone()[0]);db.execute('DELETE FROM memories')
    for i in range(o.records):
        identifier='generated-'+str(i);domain='alpha.test' if i%2==0 else 'beta.test';captured=4070908800 if o.retention and i%2 else 1000;payload=dict(template,id=identifier,timestamp=captured-978307200,app='Safari',bundleID='com.oswind.generated',title='Generated '+str(i),kind='screen',url='https://'+domain+'/item',text='Owned generated text '+str(i),imagePath='images/pair-'+str(i//2))
        db.execute('INSERT INTO memories(id,timestamp,kind,app,title,url,text,favorite,payload) VALUES(?,?,?,?,?,?,?,?,?)',(identifier,captured,'screen','Safari',payload['title'],payload['url'],payload['text'],0,json.dumps(payload).encode()))
for i in range(o.records//2):(library/'images'/('pair-'+str(i))).write_bytes(('Owned generated media '+str(i)).encode())
measurements={}
for name,domain in [('shared','alpha.test'),('unique','beta.test')]:
    selectors=['--app','Safari','--domain',domain]
    if o.retention:
        if name=='unique':
            with sqlite3.connect(library/'memory.sqlite') as db:
                db.execute("UPDATE memories SET timestamp=1000,payload=json_set(CAST(payload AS TEXT),'$.timestamp',1000-978307200)")
        raw,measurement=run(name+'-apply','prune','--days','1','--json');result=raw['erasure'];measurement['retention']=raw
        assert raw['budgetMet'] and not raw['cancelled']
    else:
        preview,measurement=run(name+'-preview','erase','preview',*selectors);measurement['sources']=preview['sources'];measurements[name+'_preview']=measurement
        assert preview['sources']==o.records//2 and preview['mediaReferences']==o.records//2
        result,measurement=run(name+'-apply','erase','apply',*selectors,'--token',preview['token'])
    measurement['result']=result;measurements[name+'_apply']=measurement
    assert result['sources']==o.records//2 and result['pendingMedia']==0 and not result['warnings']
    assert result['sharedMedia']==(o.records//2 if name=='shared' else 0) and result['removedMedia']==(0 if name=='shared' else o.records//2)
    expected=o.records//2 if name=='shared' else 0
    assert {f.name for f in (library/'images').iterdir()}==({'pair-'+str(i) for i in range(o.records//2)} if name=='shared' else set())
    if name=='shared':
        for i in range(o.records//2):assert (library/'images'/('pair-'+str(i))).read_bytes()==('Owned generated media '+str(i)).encode()
    with sqlite3.connect(library/'memory.sqlite') as db:
        ids={row[0] for row in db.execute('SELECT id FROM memories')}
        assert ids==({'generated-'+str(i) for i in range(1,o.records,2)} if name=='shared' else set())
    stats,_=run(name+'-stats','stats');assert stats['count']==expected
with sqlite3.connect(library/'memory.sqlite') as db:
    assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok';assert not db.execute('PRAGMA foreign_key_check').fetchall();assert db.execute('SELECT COUNT(*) FROM erasure_assets').fetchone()[0]==0
assert hashlib.sha256(binary.read_bytes()).hexdigest()==digest,'Runner changed during evaluation'
report=dict(format='OSwind generated retention scaling v1' if o.retention else 'OSwind generated erasure scaling v1',records=o.records,media_files=o.records//2,binary_sha256=digest,measurements=measurements,sqlite_integrity_pass=True,all_media_identities_accounted=True,all_remaining_source_ids_verified=True,harness_sha256=hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),limits=['One generated cached trial on this Mac, concurrent background activity; not natural media, energy, durability or competitor evidence','Preview, transaction, queue and physical cleanup wall time included; peak RSS includes that individual CLI only'])
(root/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
