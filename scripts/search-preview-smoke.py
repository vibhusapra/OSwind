#!/usr/bin/env python3
"""Complete-by-default CLI/HTTP/MCP sources plus explicit lightweight previews.
Authored transcript metadata; no live capture, recognition or input interaction.
"""
import argparse,json,pathlib,subprocess,tempfile,time,urllib.error,urllib.request
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary');a=p.parse_args();binary=pathlib.Path(a.binary).resolve()
with tempfile.TemporaryDirectory(prefix='oswind-preview-contract-') as root:
    root=pathlib.Path(root);library=root/'library'
    def cli(*args,data=library,ok=True):
        result=subprocess.run([str(binary),'--data',str(data),*map(str,args)],capture_output=True,text=True,timeout=60)
        assert (result.returncode==0)==ok,(args,result.stderr)
        return result.stdout
    cli('benchmark-audio-search','--archive',library,'--prepare','--clips','2','--words','1000')
    full=json.loads(cli('search','--mode','keyword','token'));light=json.loads(cli('search','--preview','--mode','keyword','token'))
    assert [h['memory']['id'] for h in full]==[h['memory']['id'] for h in light]
    assert all(len(h['memory']['transcript']['segments'])==1000 and 'searchPreview' not in h['memory'] for h in full)
    assert all('transcript' not in h['memory'] and h['memory']['searchPreview']['transcript']['segmentCount']==1000 for h in light)
    identifier=light[0]['memory']['id']
    assert len(json.loads(cli('get',identifier))['transcript']['segments'])==1000
    cli('get','missing',ok=False);cli('get',ok=False);cli('get',identifier,'extra',ok=False)
    requests=[{'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-11-25'}},{'jsonrpc':'2.0','method':'notifications/initialized'},{'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':'search_memory','arguments':{'query':'token','mode':'keyword','detail':'preview'}}},{'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'get_memory','arguments':{'id':identifier}}}]
    process=subprocess.run([str(binary),'--data',str(library),'mcp'],input='\n'.join(map(json.dumps,requests))+'\n',text=True,capture_output=True,check=True,timeout=60)
    responses={r['id']:r for r in map(json.loads,process.stdout.splitlines())}
    assert 'searchPreview' in json.loads(responses[2]['result']['content'][0]['text'])['hits'][0]['memory']
    assert len(json.loads(responses[3]['result']['content'][0]['text'])['transcript']['segments'])==1000
    server=subprocess.Popen([str(binary),'--data',str(library),'serve'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        tokenpath=library/'api-token'
        for _ in range(100):
            if tokenpath.exists():break
            assert server.poll() is None;time.sleep(.05)
        token=tokenpath.read_text()
        def get(path):
            request=urllib.request.Request('http://127.0.0.1:47831'+path,headers={'Authorization':'Bearer '+token})
            try:
                with urllib.request.urlopen(request,timeout=10) as response:return response.status,json.load(response)
            except urllib.error.HTTPError as error:return error.code,json.load(error)
        for _ in range(100):
            try:status,result=get('/v1/search?mode=keyword&query=token&detail=preview');break
            except urllib.error.URLError:assert server.poll() is None;time.sleep(.05)
        assert status==200 and 'searchPreview' in result['hits'][0]['memory']
        assert len(get('/v1/search?mode=keyword&query=token')[1]['hits'][0]['memory']['transcript']['segments'])==1000
        assert len(get('/v1/memories/'+identifier)[1]['transcript']['segments'])==1000
        assert get('/v1/search?detail=other')[0]==400
        assert get('/v1/search?detail=preview&detail=full')[0]==400
        cli('name-speaker',identifier,'--from','Maya','--name','Robin')
        fresh=get('/v1/search?mode=keyword&query=Robin&detail=preview')[1]['hits'][0]['memory']
        assert 'Robin' in fresh['searchPreview']['transcript']['speakerLabels']
        assert fresh['searchPreview']['sourceRevision']!=light[0]['memory']['searchPreview']['sourceRevision']
    finally:
        server.terminate()
        try:server.wait(timeout=5)
        except subprocess.TimeoutExpired:server.kill();server.wait()
    invalid=root/'preview.json';invalid.write_text(json.dumps([h['memory'] for h in light]));cli('import',invalid,data=root/'reject',ok=False)
    exported=root/'complete.json';cli('export',exported);assert 'searchPreview' not in exported.read_text()
    package=root/'source.oswindbackup';cli('backup','create',package);restored=root/'restored';cli('backup','restore',package,'--to',restored)
    assert json.loads(cli('search','--preview','--mode','keyword','Robin',data=restored))[0]['memory']['searchPreview']['transcript']['segmentCount']==1000
    answer=json.loads(cli('ask','--provider','evidence','token'))
    assert all('searchPreview' not in h['memory'] and len(h['memory']['transcript']['segments'])==1000 for h in answer['sources'])
print('PASS: explicit preview CLI/HTTP/MCP, complete default/get/evidence/export, invalid detail rejection, atomic rename refresh, incomplete import refusal, rebuilt backup cache')
