#!/usr/bin/env python3
"""Owned process contracts for guarded selective history erasure; no capture/normal library."""
import argparse, concurrent.futures, json, pathlib, sqlite3, subprocess, tempfile
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary');o=p.parse_args();binary=pathlib.Path(o.binary).resolve()
with tempfile.TemporaryDirectory(prefix='oswind-erasure-contract-') as temporary:
    root=pathlib.Path(temporary);library=root/'library'
    def cli(*args,ok=True):
        r=subprocess.run([str(binary),'--data',str(library),*map(str,args)],capture_output=True,text=True,timeout=90)
        assert (r.returncode==0)==ok,(args,r.returncode,r.stdout,r.stderr)
        return json.loads(r.stdout) if r.returncode==0 and r.stdout.lstrip().startswith(('{','[')) else r.stdout
    def stamp(second):return f'2026-10-23T20:00:{second:02d}Z'
    records=[('a',15,25,'Safari','https://alpha.test/one','uniqueA'),('b',40,None,'Notes',None,'keepB'),('c',25,None,'Safari','https://www.alpha.test/two','uniqueC'),('end',30,None,'Safari','https://alpha.test/end','boundary'),('evil',25,None,'Safari','https://alpha.test.evil.test','lookalike'),('other',25,None,'Other','https://alpha.test','otherapp')]
    source=root/'input.json';source.write_text(json.dumps([dict(id=i,timestamp=stamp(start),**({'endTimestamp':stamp(end)} if end else {}),kind='screen',app=app,bundleID='com.oswind.'+app,title=i,url=url,text=text,favorite=False,tags=[],regions=[]) for i,start,end,app,url,text in records]));cli('import',source)
    (library/'images/shared').write_bytes(b'shared owned bytes');(library/'images/unique').write_bytes(b'unique owned bytes')
    # Owned fixture attaches media to imported sources; normal interchange deliberately strips raw paths.
    with sqlite3.connect(library/'memory.sqlite') as db:
        for identifier,path in [('a','images/shared'),('b','images/./shared'),('c','images/unique')]:
            payload=json.loads(db.execute('SELECT payload FROM memories WHERE id=?',(identifier,)).fetchone()[0]);payload['imagePath']=path;db.execute('UPDATE memories SET payload=? WHERE id=?',(json.dumps(payload).encode(),identifier))
    scope=['--from',stamp(20),'--to',stamp(30),'--app','Safari','--domain','ALPHA.test']
    preview=cli('erase','preview',*scope);assert preview['sources']==2 and {x['id'] for x in preview['samples']}=={'a','c'} and preview['mediaReferences']==2
    assert cli('stats')['count']==6
    chat=cli('chat','new');cli('chat','ask',chat['id'],'--provider','evidence','"uniqueA"')
    cli('erase','apply',*scope,'--token',preview['token'],ok=False)
    preview=cli('erase','preview',*scope);assert preview['conversationTurns']==1
    for args in [[],['--domain','https://alpha.test'],['--from','bad'],['--unknown','x'],['--kind','wat'],['--app','Safari','--app','Notes']]:cli('erase','preview',*args,ok=False)
    cli('erase','apply',*scope,ok=False);assert cli('stats')['count']==6
    result=cli('erase','apply',*scope,'--token',preview['token'])
    assert result['sources']==2 and result['conversationTurns']==1 and result['removedMedia']==1 and result['sharedMedia']==1 and result['pendingMedia']==0 and result['warnings']==[],result
    assert cli('stats')['count']==4 and cli('chat','show',chat['id'])['turns']==[]
    assert (library/'images/shared').read_bytes()==b'shared owned bytes' and not (library/'images/unique').exists()
    for identifier in ['a','c']:cli('get',identifier,ok=False)
    for identifier in ['b','end','evil','other']:assert cli('get',identifier)['id']==identifier
    cli('erase','apply',*scope,'--token',preview['token'],ok=False)
    # Same preview in eight independent writers: at most the single previewed deletion commits.
    preview=cli('erase','preview','--app','Notes')
    def apply(_):return subprocess.run([str(binary),'--data',str(library),'erase','apply','--app','Notes','--token',preview['token']],capture_output=True,text=True,timeout=90)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:results=list(pool.map(apply,range(8)))
    assert sum(r.returncode==0 for r in results)==1,[(r.returncode,r.stderr) for r in results]
    assert cli('stats')['count']==3 and not (library/'images/shared').exists()
    assert cli('erase','retry-media')['pendingMedia']==0
    with sqlite3.connect(library/'memory.sqlite') as db:
        assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok';assert not db.execute('PRAGMA foreign_key_check').fetchall()
        assert db.execute('SELECT COUNT(*) FROM erasure_assets').fetchone()[0]==0
    print('PASS: CLI preview, overlap/domain/app intersection, stale dependency token, invalid input, derived answers/media/shared references, 8-process single commit, retry and SQLite integrity')
