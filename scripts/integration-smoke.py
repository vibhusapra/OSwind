#!/usr/bin/env python3
"""Exercise the actual CLI, MCP subprocess, and authenticated loopback socket."""
import argparse,json,pathlib,subprocess,tempfile,time,urllib.request,urllib.error,sys,threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
parser=argparse.ArgumentParser()
parser.add_argument("binary",nargs="?",default=".build/debug/oswindctl")
parser.add_argument("--indexed",action="store_true")
options=parser.parse_args()
class LocalModelFixture(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def send_json(self,body):
        data=json.dumps(body).encode(); self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self): self.send_json({"models":[{"name":"fixture:latest","digest":"offline-fixture-v1","size":1}]})
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers.get("Content-Length",0))))
        self.send_json({"embeddings":[[1.0,0.0] for _ in body["input"]]})
runtime=ThreadingHTTPServer(("127.0.0.1",0),LocalModelFixture) if options.indexed else None
if runtime: threading.Thread(target=runtime.serve_forever,daemon=True).start()
binary=pathlib.Path(options.binary).resolve()
with tempfile.TemporaryDirectory(prefix='oswind-smoke-') as directory:
    prefix=[str(binary),'--data',directory]
    def cli(*args): return subprocess.check_output(prefix+list(args),text=True,timeout=30)
    identifier=cli('note','OSwind socket smoke marker').strip()
    mode='semantic' if runtime else 'keyword'
    if runtime:
        endpoint='http://127.0.0.1:'+str(runtime.server_port)
        cli('reindex','--model','fixture:latest','--endpoint',endpoint,'--use-model')
        cli('index-search','--model','fixture:latest','--endpoint',endpoint,'--use-index')
        indexed=json.loads(cli('search','--mode','semantic','--details','socket'))
        assert indexed['strategy']=='ann-exact-rerank' and not indexed['warnings']
    assert json.loads(cli('search','--mode','keyword','socket'))[0]['memory']['id']==identifier
    visual=json.loads(cli('search','--mode','visual','--details'))
    assert visual['hits']==[] and visual['strategy']=='visual-recent'
    missing_visual=subprocess.run(prefix+['search','--mode','visual','--details','a red window'],capture_output=True,text=True,timeout=30)
    assert missing_visual.returncode!=0 and 'visual memory' in missing_visual.stderr.lower()
    requests=[{'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-11-25'}},{'jsonrpc':'2.0','method':'notifications/initialized'},{'jsonrpc':'2.0','id':2,'method':'tools/list'},{'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'search_memory','arguments':{'query':'socket','mode':mode}}}]
    process=subprocess.run(prefix+['mcp'],input='\n'.join(json.dumps(r) for r in requests)+'\n',text=True,capture_output=True,timeout=30,check=True)
    responses=[json.loads(line) for line in process.stdout.splitlines()]
    assert len(responses)==3
    assert {tool['name'] for tool in responses[1]['result']['tools']}=={'search_memory','get_memory','memory_stats','memory_activity','memory_entities','entity_sources','memory_privacy_check'}
    visual_tool=next(tool for tool in responses[1]['result']['tools'] if tool['name']=='search_memory')
    assert 'visual' in visual_tool['inputSchema']['properties']['mode']['enum']
    assert identifier in responses[2]['result']['content'][0]['text']
    if runtime: assert json.loads(responses[2]['result']['content'][0]['text'])['strategy']=='ann-exact-rerank'
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
        status,hits=get('/v1/search?query=socket&mode='+mode); assert status==200 and hits['hits'][0]['memory']['id']==identifier
        if runtime: assert hits['strategy']=='ann-exact-rerank' and not hits['warnings']
        assert get('/v1/memories/'+identifier)[1]['text']=='OSwind socket smoke marker'
        status,privacy=get('/v1/memory-privacy-check?id='+identifier);assert status==200 and privacy['state']=='notRecorded' and privacy['privacyAcceptance'] is False
        assert get('/v1/memory-privacy-check?id='+identifier,authorized=False)[0]==401
        assert get('/v1/memory-privacy-check?id='+identifier+'&extra=x')[0]==400
        assert get('/health',authorized=False)[0]==401
        assert get('/health',extra={'Origin':'https://example.com'})[0]==403
        assert get('/health',extra={'Host':'evil.example'})[0]==403
    finally:
        server.terminate()
        try: server.wait(timeout=5)
        except subprocess.TimeoutExpired: server.kill(); server.wait()
    print('PASS: CLI durable note/search; MCP initialize/list/search; live HTTP health/stats/search/get; 401 auth and 403 origin/host boundaries')

if runtime: runtime.shutdown(); runtime.server_close()
