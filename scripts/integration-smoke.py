#!/usr/bin/env python3
"""Exercise the actual CLI, MCP subprocess, and authenticated loopback socket."""
import json,pathlib,subprocess,tempfile,time,urllib.request,urllib.error,sys
binary=pathlib.Path(sys.argv[1] if len(sys.argv)>1 else '.build/debug/oswindctl').resolve()
with tempfile.TemporaryDirectory(prefix='oswind-smoke-') as directory:
    prefix=[str(binary),'--data',directory]
    def cli(*args): return subprocess.check_output(prefix+list(args),text=True,timeout=30)
    identifier=cli('note','OSwind socket smoke marker').strip()
    assert json.loads(cli('search','--mode','keyword','socket'))[0]['memory']['id']==identifier
    requests=[{'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-11-25'}},{'jsonrpc':'2.0','method':'notifications/initialized'},{'jsonrpc':'2.0','id':2,'method':'tools/list'},{'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'search_memory','arguments':{'query':'socket','mode':'keyword'}}}]
    process=subprocess.run(prefix+['mcp'],input='\n'.join(json.dumps(r) for r in requests)+'\n',text=True,capture_output=True,timeout=30,check=True)
    responses=[json.loads(line) for line in process.stdout.splitlines()]
    assert len(responses)==3
    assert len(responses[1]['result']['tools'])==3
    assert identifier in responses[2]['result']['content'][0]['text']
    server=subprocess.Popen(prefix+['serve'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        tokenpath=pathlib.Path(directory)/'api-token'
        for _ in range(100):
            if tokenpath.exists(): break
            if server.poll() is not None: raise RuntimeError(server.stderr.read())
            time.sleep(.05)
        token=tokenpath.read_text()
        def get(path,authorized=True,extra=None):
            headers=({'Authorization':'Bearer '+token} if authorized else {}) | (extra or {})
            request=urllib.request.Request('http://127.0.0.1:47831'+path,headers=headers)
            try:
                with urllib.request.urlopen(request,timeout=10) as response: return response.status,json.load(response)
            except urllib.error.HTTPError as error: return error.code,json.load(error)
        for _ in range(50):
            try: status,health=get('/health'); break
            except urllib.error.URLError: time.sleep(.1)
        assert status==200 and health['status']=='ok'
        assert get('/v1/stats')[1]['count']==1
        status,hits=get('/v1/search?query=socket&mode=keyword'); assert status==200 and hits['hits'][0]['memory']['id']==identifier
        assert get('/v1/memories/'+identifier)[1]['text']=='OSwind socket smoke marker'
        assert get('/health',authorized=False)[0]==401
        assert get('/health',extra={'Origin':'https://example.com'})[0]==403
        assert get('/health',extra={'Host':'evil.example'})[0]==403
    finally:
        server.terminate()
        try: server.wait(timeout=5)
        except subprocess.TimeoutExpired: server.kill(); server.wait()
    print('PASS: CLI durable note/search; MCP initialize/list/search; live HTTP health/stats/search/get; 401 auth and 403 origin/host boundaries')
