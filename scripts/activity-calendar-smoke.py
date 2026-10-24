#!/usr/bin/env python3
"""Owned imports: complete civil-time counts across CLI, live HTTP and MCP.

Requires a NEW artifact root. No desktop capture, normal history or credentials.
Raw synthetic responses and the temporary API token remain inside that root.
"""
import argparse,hashlib,json,pathlib,subprocess,time,urllib.error,urllib.parse,urllib.request

p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary',type=pathlib.Path);p.add_argument('--root',type=pathlib.Path,required=True);a=p.parse_args()
binary=a.binary.resolve();root=a.root.resolve();root.mkdir(mode=0o700,parents=False,exist_ok=False);library=root/'library'
prefix=[str(binary),'--data',str(library)]
def cli(*args,valid=True):
    result=subprocess.run(prefix+list(map(str,args)),capture_output=True,text=True,timeout=90)
    assert (result.returncode==0)==valid,(args,result.stderr)
    return json.loads(result.stdout) if valid else None
rows=[dict(id=f'owned-{i}',timestamp='2024-11-03T01:30:00-04:00' if i<300 else '2024-11-03T01:30:00-05:00',kind='note',app='Owned Calendar',bundleID='org.oswind.owned-fixture',title='Owned',text='Owned synthetic calendar source',favorite=i%2==0,tags=['release' if i%3==0 else 'other'],regions=[]) for i in range(600)]
source=root/'input.json';source.write_text(json.dumps(rows));assert cli('import',source,'--json')['imported']==600
base=dict(month='2024-11',day='2024-11-03',timeZone='America/New_York',firstWeekday=2)
cases=[({},600),({'app':'Owned Calendar','kind':'note','favorites':True,'tag':'release'},100),({'start':'2024-11-03T05:00:00Z','end':'2024-11-03T06:00:00Z'},300),({'app':'Missing'},0)]
def flags(values):
    names={'timeZone':'time-zone','firstWeekday':'first-weekday','start':'from','end':'to'};out=[]
    for key,value in values.items():
        if key=='favorites':
            if value:out.append('--favorites')
        else:out+=['--'+names.get(key,key),str(value)]
    return out
snapshots=[]
for scope,count in cases:
    value=cli('activity',*flags(base|scope));assert value['totalSources']==count and len(value['days'])==30 and len(value['hours'])==25
    assert sum(d['sources'] for d in value['days'])==count==sum(h['sources'] for h in value['hours'])
    assert value['leadingEmptyDays']==4
    snapshots.append(value)
repeated=[h for h in snapshots[0]['hours'] if h['hour']==1]
assert [h['utcOffsetSeconds'] for h in repeated]==[-14400,-18000] and [h['sources'] for h in repeated]==[300,300]
assert len(cli('activity','--month','2024-03','--day','2024-03-10','--time-zone','America/New_York')['hours'])==23
assert len(cli('activity','--month','2024-02','--time-zone','Asia/Kathmandu')['days'])==29
invalid=[base|{'query':'words'},base|{'limit':1},base|{'timeZone':'No/Zone'},base|{'day':'2024-12-01'},base|{'firstWeekday':True},base|{'month':'2024-2'}]
cli('activity','--month','2024-11','--query','words',valid=False)
calls=[base|scope for scope,_ in cases]+invalid
wire=''.join(json.dumps({'jsonrpc':'2.0','id':i,'method':'tools/call','params':{'name':'memory_activity','arguments':values}})+'\n' for i,values in enumerate(calls,1))
result=subprocess.run(prefix+['mcp'],input=wire,text=True,capture_output=True,check=True,timeout=90)
(root/'mcp.jsonl').write_text(result.stdout);responses=[json.loads(line)['result'] for line in result.stdout.splitlines()];assert len(responses)==len(calls)
for index,response in enumerate(responses):
    if index<len(cases):assert json.loads(response['content'][0]['text'])==snapshots[index]
    else:assert response.get('isError') is True
server=subprocess.Popen(prefix+['serve'],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
try:
    tokenfile=library/'api-token'
    for _ in range(200):
        if tokenfile.exists():break
        assert server.poll() is None;time.sleep(.05)
    token=tokenfile.read_text()
    def http(path,authorized=True,extra=None):
        request=urllib.request.Request('http://127.0.0.1:47831'+path,headers=({'Authorization':'Bearer '+token} if authorized else {})|(extra or {}))
        try:
            with urllib.request.urlopen(request,timeout=30) as response:return response.status,json.load(response)
        except urllib.error.HTTPError as error:return error.code,json.load(error)
    for _ in range(200):
        try:assert http('/health')[0]==200;break
        except urllib.error.URLError:assert server.poll() is None;time.sleep(.05)
    else:raise AssertionError('Owned API did not listen')
    def path(values):return '/v1/activity?'+urllib.parse.urlencode({k:str(v).lower() if isinstance(v,bool) else v for k,v in values.items()})
    for index,(scope,_) in enumerate(cases):assert http(path(base|scope))==(200,snapshots[index])
    for values in invalid:assert http(path(values))[0]==400
    assert http(path(base)+'&month=2024-11')[0]==400
    assert http(path(base),authorized=False)[0]==401
    assert http(path(base),extra={'Origin':'https://example.com'})[0]==403
    assert http(path(base),extra={'Host':'evil.example'})[0]==403
    changed=dict(rows[0],id='external',timestamp='2024-11-04T12:00:00Z');source.write_text(json.dumps([changed]));assert cli('import',source,'--json')['imported']==1
    refreshed=http(path(base));assert refreshed[0]==200 and refreshed[1]['totalSources']==601
    assert next(d for d in refreshed[1]['days'] if d['key']=='2024-11-04')['sources']==1
finally:
    server.terminate()
    try:server.wait(timeout=10)
    except subprocess.TimeoutExpired:server.kill();server.wait()
    server.stderr.close()
report=dict(scope='Owned synthetic imports and live CLI/HTTP/MCP counts; no capture, native input, energy or competitor claim.',binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),harnessSHA256=hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),sources=600,passed=True,checks=['complete counts exceed search caps','CLI HTTP MCP identical metadata scopes','repeated clock hour distinct UTC ranges','23 hour DST day and leap month','inclusive start exclusive end','invalid relevance and malformed parameters rejected','HTTP token origin host guards','external writer visible to persistent HTTP connection'])
(root/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
