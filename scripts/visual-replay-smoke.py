#!/usr/bin/env python3
"""Synthetic replay CLI/HTTP/MCP, portability and erasure contracts. No device capture."""
import argparse, hashlib, json, pathlib, subprocess, tempfile, time, urllib.error, urllib.request
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('binary');options=parser.parse_args();binary=pathlib.Path(options.binary).resolve()
with tempfile.TemporaryDirectory(prefix='oswind-visual-contract-') as temporary:
    root=pathlib.Path(temporary);probe=root/'probe';library=probe/'library'
    def cli(*args,data=library,ok=True):
        result=subprocess.run([str(binary),'--data',str(data),*map(str,args)],capture_output=True,text=True,timeout=60)
        assert (result.returncode==0)==ok,(args,result.stderr)
        return result.stdout
    report=json.loads(cli('probe-visual-replay','--output',probe,'--frames','2','--software'))
    assert report['input_frames']==report['stored_frames']==report['decoded_frames']==report['ocr_checks_passed']==report['decoded_ocr_checks_passed']==report['decoded_frame_identity_checks_passed']==2
    original=hashlib.sha256((probe/'report.json').read_bytes()).hexdigest()
    cli('probe-visual-replay','--output',probe,'--frames','2','--software',ok=False)
    assert hashlib.sha256((probe/'report.json').read_bytes()).hexdigest()==original
    hits=json.loads(cli('search','--mode','keyword','archive'));assert len(hits)==1
    source=hits[0]['memory'];identifier=source['id'];assert len(source['visualRecording']['frames'])==2
    assert json.loads(cli('get',identifier))['visualRecording']==source['visualRecording']
    requests=[{'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-11-25'}},{'jsonrpc':'2.0','method':'notifications/initialized'},{'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':'search_memory','arguments':{'query':'archive','mode':'keyword'}}},{'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'get_memory','arguments':{'id':identifier}}}]
    process=subprocess.run([str(binary),'--data',str(library),'mcp'],input='\n'.join(map(json.dumps,requests))+'\n',text=True,capture_output=True,check=True,timeout=60)
    responses={row['id']:row for row in map(json.loads,process.stdout.splitlines())}
    assert json.loads(responses[2]['result']['content'][0]['text'])['hits'][0]['memory']['visualRecording']==source['visualRecording']
    assert json.loads(responses[3]['result']['content'][0]['text'])['visualRecording']==source['visualRecording']
    server=subprocess.Popen([str(binary),'--data',str(library),'serve'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        tokenpath=library/'api-token'
        for _ in range(100):
            if tokenpath.exists():break
            assert server.poll() is None;time.sleep(.05)
        token=tokenpath.read_text()
        def get(path):
            request=urllib.request.Request('http://127.0.0.1:47831'+path,headers={'Authorization':'Bearer '+token})
            with urllib.request.urlopen(request,timeout=10) as response:return json.load(response)
        for _ in range(100):
            try:result=get('/v1/search?mode=keyword&query=archive');break
            except urllib.error.URLError:assert server.poll() is None;time.sleep(.05)
        assert result['hits'][0]['memory']['visualRecording']==source['visualRecording']
        assert get('/v1/memories/'+identifier)['videoPath']==source['videoPath']
    finally:
        server.terminate()
        try:server.wait(timeout=5)
        except subprocess.TimeoutExpired:server.kill();server.wait()
        server.stdout.close();server.stderr.close()
    answer=json.loads(cli('ask','--provider','evidence','Who owns archive?'))
    assert answer['sources'][0]['memory']['visualRecording']==source['visualRecording']
    package=root/'visual.oswindbackup';cli('backup','create',package);cli('backup','inspect',package)
    restored=root/'restored';cli('backup','restore',package,'--to',restored)
    copy=json.loads(cli('get',identifier,data=restored));assert copy['visualRecording']==source['visualRecording']
    assert (restored/copy['videoPath']).read_bytes()==(library/source['videoPath']).read_bytes()
    exported=root/'visual.json';cli('export',exported);imported=root/'imported';cli('import',exported,data=imported)
    text=json.loads(cli('get',identifier,data=imported));assert text['visualRecording']==source['visualRecording'];assert 'videoPath' not in text and 'imagePath' not in text
    cli('capture-replay','--seconds','nan',ok=False);cli('capture-replay','--seconds','0',ok=False)
    cli('delete',identifier);assert json.loads(cli('stats'))['count']==0
    assert not (library/source['videoPath']).exists() and not (library/source['imagePath']).exists()
    assert (restored/copy['videoPath']).exists()
print('PASS: actual synthetic OCR/video/decode; CLI/HTTP/MCP timed sources; evidence hydration; backup byte equality; text-only interchange; erasure and output preservation')
