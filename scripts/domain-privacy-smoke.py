#!/usr/bin/env python3
"""Owned synthetic domain/app/title import filtering across CLI, HTTP and MCP.

This does not record a desktop or assert that capture exclusions erase/hide
previously recorded text. It verifies excluded inputs never enter this import.
Requires a NEW artifact root; raw responses and its API token stay private.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary',type=pathlib.Path)
parser.add_argument('--root',required=True,type=pathlib.Path)
args=parser.parse_args();binary=args.binary.resolve();root=args.root.resolve()
root.mkdir(mode=0o700,parents=False,exist_ok=False);library=root/'library';library.mkdir(mode=0o700)
policy=dict(excludedApps=['org.fixture.private'],excludedDomains=[' Private.Example. ','bücher.example'],excludedTitles=['Excluded fixture'],
            redactSecrets=True,retainImages=True,retentionDays=30,maxStorageGB=20,requireBrowserContext=True)
settings=library/'settings.json';settings.write_text(json.dumps({'privacy':policy}));settings.chmod(0o600)
cases=[('public','https://public.example/','org.fixture.browser','Owned'),
       ('lookalike','https://private.example.evil.test/','org.fixture.browser','Owned'),
       ('native',None,'org.fixture.native','Owned'),
       ('plain-private','https://private.example/','org.fixture.browser','Owned'),
       ('root-dot','https://private.example./','org.fixture.browser','Owned'),
       ('sub-root-dot','https://sub.private.example./','org.fixture.browser','Owned'),
       ('encoded','https://pr%69vate.example/','org.fixture.browser','Owned'),
       ('idna','https://xn--bcher-kva.example./','org.fixture.browser','Owned'),
       ('app','https://public.example/','ORG.FIXTURE.PRIVATE','Owned'),
       ('title','https://public.example/','org.fixture.browser','An EXCLUDED FIXTURE note')]
source=root/'input.json';source.write_text(json.dumps([dict(id=id,timestamp='2026-10-24T12:00:00Z',kind='note',app='Owned fixture',bundleID=bundle,title=title,text='DomainGuardFixture owned source',url=url,favorite=False,tags=[],regions=[]) for id,url,bundle,title in cases]))
prefix=[str(binary),'--data',str(library)]
def cli(*arguments):
    p=subprocess.run(prefix+list(map(str,arguments)),capture_output=True,check=True,timeout=90)
    return json.loads(p.stdout)
def ids(result):return {hit['memory']['id'] for hit in result['hits']}
expected={'public','lookalike','native'};blocked={row[0] for row in cases}-expected
imported=cli('import',source,'--json');(root/'import.json').write_text(json.dumps(imported,indent=2)+'\n')
assert imported['imported']==3 and imported['excluded']==7,imported
assert ids(cli('search','--mode','keyword','--details','--literal','DomainGuardFixture'))==expected
calls=[{'name':'search_memory','arguments':{'query':'DomainGuardFixture','mode':'keyword','literal':True}}]
calls += [{'name':'get_memory','arguments':{'id':id}} for id in sorted(expected|blocked)]
wire=''.join(json.dumps({'jsonrpc':'2.0','id':i,'method':'tools/call','params':call})+'\n' for i,call in enumerate(calls,1))
p=subprocess.run(prefix+['mcp'],input=wire,text=True,capture_output=True,check=True,timeout=90)
(root/'mcp.jsonl').write_text(p.stdout);responses=[json.loads(line)['result'] for line in p.stdout.splitlines()]
assert ids(json.loads(responses[0]['content'][0]['text']))==expected
for call,result in zip(calls[1:],responses[1:]):assert result.get('isError',False)==(call['arguments']['id'] in blocked)
server=subprocess.Popen(prefix+['serve'],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
try:
    tokenfile=library/'api-token'
    for _ in range(200):
        if tokenfile.exists():break
        assert server.poll() is None;time.sleep(.05)
    token=tokenfile.read_text()
    def http(path,authorized=True):
        request=urllib.request.Request('http://127.0.0.1:47831'+path,headers={'Authorization':'Bearer '+token} if authorized else {})
        try:
            with urllib.request.urlopen(request,timeout=20) as response:return response.status,json.load(response)
        except urllib.error.HTTPError as error:return error.code,json.load(error)
    for _ in range(200):
        try:
            status,_=http('/health');assert status==200;break
        except urllib.error.URLError:
            assert server.poll() is None;time.sleep(.05)
    else:raise AssertionError('Owned API did not listen')
    status,result=http('/v1/search?'+urllib.parse.urlencode(dict(query='DomainGuardFixture',mode='keyword',literal='true')))
    assert status==200 and ids(result)==expected
    for id in expected|blocked:
        status,_=http('/v1/memories/'+id);assert (status==200)==(id in expected)
    assert http('/v1/stats')[1]['count']==3
    assert http('/v1/search',authorized=False)[0]==401
finally:
    server.terminate()
    try:server.wait(timeout=10)
    except subprocess.TimeoutExpired:server.kill();server.wait()
    server.stderr.close()
report=dict(scope='Synthetic imported notes; domain/app/title filtering before admission and resulting CLI/HTTP/MCP consistency. No capture/device, retrospective text hiding or energy claim.',
            binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),imported=3,excluded=7,
            checks=['root-dot, encoded, IDNA and configured domain spelling','case-insensitive app and title exclusions','CLI/HTTP/MCP search agree','excluded imports absent by direct HTTP/MCP id','owned stats preserve admission counts','HTTP token required'],passed=True)
(root/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
