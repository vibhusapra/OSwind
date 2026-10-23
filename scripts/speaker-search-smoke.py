#!/usr/bin/env python3
"""Deterministic CLI/HTTP/MCP speaker scopes and cross-process rename/erasure.
Authored transcript metadata only; no ASR, voice recognition or device claim.
"""
import argparse,json,pathlib,subprocess,tempfile,time,urllib.error,urllib.parse,urllib.request
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary');a=p.parse_args();binary=pathlib.Path(a.binary).resolve()
with tempfile.TemporaryDirectory(prefix='oswind-speaker-search-') as directory:
    root=pathlib.Path(directory);prefix=[str(binary),'--data',directory]
    def cli(*args):return subprocess.check_output(prefix+list(map(str,args)),text=True,timeout=60)
    identifier=cli('note','Synthetic speaker seed').strip();fixture=root/'fixture.json';cli('export',fixture)
    source=json.loads(fixture.read_text())[0];text='Capture tests ship Friday. Archive is local.'
    source.update(kind='audio',app='Imported audio',title='Authored speaker fixture',text=text,transcript={'text':text,'duration':6,'model':'deterministic-fixture','segments':[{'start':0,'end':2,'text':'Capture tests ship Friday.','speaker':'Máya Chen'},{'start':3,'end':5,'text':'Archive is local.','speaker':'Theo'}]})
    fixture.write_text(json.dumps([source]));cli('import',fixture)
    assert json.loads(cli('search','--mode','keyword','Maya'))[0]['memory']['id']==identifier
    requests=[{'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-11-25'}},{'jsonrpc':'2.0','method':'notifications/initialized'},{'jsonrpc':'2.0','id':2,'method':'tools/list'},{'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'search_memory','arguments':{'query':'archive','speaker':'MAYA CHEN','mode':'keyword'}}}]
    mcp=subprocess.run(prefix+['mcp'],input='\n'.join(map(json.dumps,requests))+'\n',text=True,capture_output=True,check=True,timeout=60)
    responses={r['id']:r for r in map(json.loads,mcp.stdout.splitlines())}
    schema=responses[2]['result']['tools'][0]['inputSchema']['properties'];assert 'speaker' in schema
    assert json.loads(responses[3]['result']['content'][0]['text'])['hits'][0]['memory']['id']==identifier
    server=subprocess.Popen(prefix+['serve'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        tokenpath=root/'api-token'
        for _ in range(100):
            if tokenpath.exists():break
            assert server.poll() is None,'Server exited';time.sleep(.05)
        token=tokenpath.read_text()
        def get(parameters):
            request=urllib.request.Request('http://127.0.0.1:47831/v1/search?'+parameters,headers={'Authorization':'Bearer '+token})
            try:
                with urllib.request.urlopen(request,timeout=10) as response:return response.status,json.load(response)
            except urllib.error.HTTPError as error:return error.code,json.load(error)
        def search(**args):return get(urllib.parse.urlencode({'mode':'keyword',**args}))
        for _ in range(100):
            try:status,hits=search(query='archive',speaker='MAYA CHEN');break
            except urllib.error.URLError:assert server.poll() is None;time.sleep(.05)
        assert status==200 and [h['memory']['id'] for h in hits['hits']]==[identifier]
        assert search(query='archive',speaker='Missing')[1]['hits']==[]
        assert get('mode=keyword&speaker=Maya&speaker=Theo')[0]==400
        cli('name-speaker',identifier,'--from','Máya Chen','--name','Robin')
        assert search(query='archive',speaker='MAYA CHEN')[1]['hits']==[]
        assert search(query='Robin')[1]['hits'][0]['memory']['id']==identifier
        cli('delete',identifier);assert search(query='Robin')[1]['hits']==[]
    finally:
        server.terminate()
        try:server.wait(timeout=5)
        except subprocess.TimeoutExpired:server.kill();server.wait()
print('PASS: actual CLI name index, MCP speaker schema/search, HTTP Unicode scope, unknown/duplicate filters, cross-process rename and erasure')
