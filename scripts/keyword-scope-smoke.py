#!/usr/bin/env python3
"""Paired query semantics on fresh authored source/speaker fixtures only."""
import argparse,hashlib,json,pathlib,sqlite3,subprocess,math,time,contextlib

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('candidate',type=pathlib.Path);p.add_argument('--baseline',required=True,type=pathlib.Path);p.add_argument('--root',required=True,type=pathlib.Path)
a=p.parse_args();base=a.root.resolve();base.mkdir(mode=0o700,parents=True,exist_ok=False)
binaries={'baseline':a.baseline.resolve(),'candidate':a.candidate.resolve()}
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
pins={k:sha(v) for k,v in binaries.items()};operations=[]
specs=[('text-a','Maya Chen leads archive launch',None,'Notes','Plan'),('audio-a','archive review approved',['Maya Chen'],'Meetings','Review'),('audio-b','archive review deferred',['Theo Chen'],'Meetings','Review'),('audio-both','Unrelated transcript',['Maya Chen','Theo Chen'],'Meetings','Conversation'),('other-app','archive review',None,'Other','Other'),('title-a','Unrelated body',None,'Notes','Archive launch'),('frame-21','Frame 21 launches Friday',None,'Notes','Frame'),('frame-210','Frame 210 launches Friday',None,'Notes','Frame'),('frame-gap','Frame number 21 launches Friday',None,'Notes','Frame'),('unicode-key','Café résumé approved',None,'Notes','Unicode'),('absent','Different material',None,'Other','Other')]
rows=[]
for i,(identifier,text,labels,app,title) in enumerate(specs):
    row=dict(id=identifier,timestamp=f'2026-10-30T12:{i:02d}:00Z',kind='audio' if labels else 'note',app=app,bundleID='org.oswind.owned-scope',title=title,text=text,favorite=i%2==0,tags=['work' if i%2==0 else 'other'],regions=[])
    if labels:row['transcript']=dict(text=text,duration=len(labels),model='owned-fixture',segments=[dict(start=j,end=j+1,text=text if j==0 else '',speaker=label) for j,label in enumerate(labels)])
    rows.append(row)
source=base/'sources.json';source.write_text(json.dumps(rows,ensure_ascii=False))
def command(profile,*argv,ok=True):
    assert sha(binaries[profile])==pins[profile]
    result=subprocess.run([str(binaries[profile]),'--data',str(base/profile/'library'),*map(str,argv)],capture_output=True,text=True,timeout=120)
    assert (result.returncode==0)==ok,(profile,argv,result.returncode,result.stderr)
    operations.append(dict(profile=profile,args=list(map(str,argv)),returncode=result.returncode,stdoutSHA256=hashlib.sha256(result.stdout.encode()).hexdigest()))
    return json.loads(result.stdout) if ok else result.stderr
def originals(profile):
    with contextlib.closing(sqlite3.connect('file:'+str(base/profile/'library/memory.sqlite')+'?mode=ro',uri=True)) as db:
        values=db.execute('SELECT id,text,payload FROM memories ORDER BY id COLLATE BINARY').fetchall()
        assert len(values)==len(rows) and {v[0]:v[1] for v in values}=={r['id']:r['text'] for r in rows}
        h=hashlib.sha256()
        for values in values:
            for item in values:
                data=item if isinstance(item,bytes) else item.encode();h.update(len(data).to_bytes(8,'little'));h.update(data)
        return h.hexdigest()
for profile in binaries:assert command(profile,'import',source,'--json')['imported']==len(rows)
before={k:originals(k) for k in binaries}
cases=[('soft','archive launch',[],None),('required','"archive launch"',[],{'text-a','title-a'}),('mixed-speaker','"Maya Chen" AND archive',[],{'text-a','audio-a'}),('speaker-only','"Theo Chen"',[],{'audio-b','audio-both'}),('cross-label','"Maya Chen" "Theo Chen"',[],{'audio-both'}),('negative','archive AND NOT "Maya Chen"',[],{'audio-b','other-app','title-a'}),('precedence','("Maya Chen" OR archive) AND NOT deferred',[],None),('exact-digit','"Frame 21"',[],{'frame-21'}),('prefix-digit','Frame AND 21',[],{'frame-21','frame-210','frame-gap'}),('unicode','"cafe resume"',[],{'unicode-key'}),('literal','"Frame 21"',['--literal'],None),('application','archive',['--app','Meetings'],{'audio-a','audio-b'}),('kind','archive',['--kind','audio'],{'audio-a','audio-b'}),('favorites','archive',['--favorites'],{'text-a','audio-b','other-app'}),('tag','archive',['--tag','work'],{'text-a','audio-b','other-app'}),('speaker-scope','archive',['--speaker','Maya Chen'],{'audio-a'}),('time','archive',['--from','2026-10-30T12:00:00Z','--to','2026-10-30T12:03:00Z'],{'text-a','audio-a','audio-b'}),('absent','nonexistentownedtoken',[],set())]
observations=[]
for label,query,flags,expected in cases:
    for mode in ['keyword','hybrid']:
        pair={k:command(k,'search','--mode',mode,'--details','--limit','100',*flags,query) for k in binaries}
        left,right=(pair[k] for k in ['baseline','candidate']);lh,rh=left['hits'],right['hits']
        assert [h['memory']['id'] for h in lh]==[h['memory']['id'] for h in rh],(label,mode,lh,rh)
        for l,r in zip(lh,rh):
            assert l['memory']==r['memory'] and l.get('match')==r.get('match') and l.get('passage')==r.get('passage'),(label,mode)
            assert math.isclose(l['score'],r['score'],rel_tol=1e-12,abs_tol=1e-12),(label,mode,l['score'],r['score'])
        assert left['warnings']==right['warnings'] and left.get('strategy')==right.get('strategy') and left.get('modelID')==right.get('modelID'),(label,mode)
        if expected is not None and mode=='keyword':assert {h['memory']['id'] for h in rh}==expected,(label,rh,expected)
        observations.append(dict(case=label,mode=mode,ids=[h['memory']['id'] for h in rh],orderedHitsScoresSourcesAndWarningsEqual=True,explicitMembershipChecked=expected is not None and mode=='keyword'))
for query in ['archive AND','NOT archive','"unclosed']:
    for profile in binaries:command(profile,'search','--mode','keyword',query,ok=False)
after={k:originals(k) for k in binaries};assert before==after
report=dict(format='OSwind paired keyword scope semantics',state='completed',binaries=pins,sameBinaryControl=pins['baseline']==pins['candidate'],sources=len(rows),sourceSHA256=sha(source),harnessSHA256=sha(pathlib.Path(__file__)),observations=observations,operations=operations,originalPayloadSHA256Before=before,originalPayloadSHA256After=after,scope='Authored fresh text and labeled-transcript fixtures, actual CLI keyword and local hybrid paths. Exact ordered hits/scores/source payloads/match/passage/warnings compare to the baseline; explicit keyword memberships and invalid syntax checked. No normal history, media capture, provider request, power or competitor measurement.')
(base/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(dict(state='completed',sources=len(rows),observations=len(observations),invalidSyntaxRefusals=6,originalPayloadsPreserved=True)))
