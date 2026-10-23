#!/usr/bin/env python3
"""Isolated CLI/HTTP/MCP scope, literal, saved-history and evaluation-root checks."""
import argparse, datetime, json, pathlib, subprocess, tempfile, time, urllib.error, urllib.parse, urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('binary', nargs='?', default='.build/debug/oswindctl')
parser.add_argument('--provider', choices=['evidence', 'apple', 'ollama'], default='evidence')
parser.add_argument('--model', default='qwen3:4b-instruct-2507-q4_K_M')
parser.add_argument('--output', type=pathlib.Path)
options = parser.parse_args()
binary = pathlib.Path(options.binary).resolve()
started = datetime.datetime.now().astimezone()
report = {'schema':1, 'fixture':'query-scope-process-v1', 'provider':options.provider,
          'model':options.model if options.provider == 'ollama' else options.provider,
          'timestamp':started.isoformat(), 'scope':'Five fictional Comet notes and a clock marker; narrow process/grounding regression, not held-out relevance, power or a product ranking.'}
with tempfile.TemporaryDirectory(prefix='oswind-query-scope-') as directory:
    base = pathlib.Path(directory)
    store = base/'store'
    prefix = [str(binary), '--data', str(store)]
    def raw(*args, **kwargs):
        return subprocess.run(prefix+list(args), text=True, capture_output=True, timeout=120, **kwargs)
    def cli(*args):
        value = raw(*args)
        assert value.returncode == 0, (args[0], value.stderr)
        return value.stdout
    rows = [
        ('old', '2026-10-21T20:00:00Z', 'Safari', False, [], 'Comet owner is Mira.'),
        ('start', '2026-10-22T07:00:00Z', 'Safari', True, ['work'], 'Comet owner is Lina.'),
        ('late', '2026-10-23T06:59:59Z', 'Safari', False, [], 'Comet deadline is Thursday.'),
        ('end', '2026-10-23T07:00:00Z', 'Safari', True, ['work'], 'Comet owner is Max. Its deadline is Friday.'),
        ('mail', '2026-10-22T19:00:00Z', 'Mail', True, ['work'], 'Comet owner is Theo.')]
    identifiers = {}
    for name, *_ in rows:
        identifiers[name] = cli('note', 'Comet seed '+name).strip()
    clock = cli('note', 'ClockScopeMarker').strip()
    exported = base/'fixture.json'
    cli('export', str(exported))
    memories = json.loads(exported.read_text())
    mapped = {value['id']:value for value in memories}
    for name, stamp, app, favorite, tags, facts in rows:
        memory = mapped[identifiers[name]]
        memory.update(timestamp=stamp, app=app, favorite=favorite, tags=tags,
                      text=facts+' The words yesterday and app:Safari are literal fixture text.')
    exported.write_text(json.dumps(memories))
    cli('import', str(exported))
    query = 'Comet app:safari since:2026-10-22T07:00:00Z until:2026-10-23T07:00:00Z'
    def ids(result): return {hit['memory']['id'] for hit in result['hits']}
    expected = {identifiers['start'], identifiers['late']}
    result = json.loads(cli('search', '--details', '--mode', 'keyword', query))
    assert ids(result) == expected and result['resolution']['filter']['app'] == 'Safari'
    assert result['resolution']['filter']['query'] == 'Comet'
    saved = json.loads(cli('search', '--details', '--mode', 'keyword', query+' kind:note tag:work is:favorite'))
    assert ids(saved) == {identifiers['start']}
    literal = json.loads(cli('search', '--details', '--mode', 'keyword', '--literal', 'yesterday app:Safari'))
    assert len(literal['hits']) == 5 and literal['resolution']['clauses'] == []
    for invalid in [('search','--mode','hybrid','kind:invalid Comet'), ('search','on:2026-02-30'), ('search','--app','Mail','app:Safari'), ('search','--limit','oops','Comet'), ('search','--app'), ('search','--mode','invalid','Comet'), ('ask','--provider','invalid','Comet')]:
        failure = raw(*invalid)
        assert failure.returncode != 0 and failure.stderr, invalid
    today = json.loads(cli('search','--details','--mode','keyword','ClockScopeMarker today'))
    if datetime.datetime.now().astimezone().date() == started.date():
        assert ids(today) == {clock}
        report['relative_today'] = 'passed'
    else:
        report['relative_today'] = 'day changed during process smoke; deterministic calendar unit tests cover boundaries'
    session = json.loads(cli('chat','new'))['id']
    question = 'Who owns Comet and what is its deadline? '+query.removeprefix('Comet ')
    model_flags = ['--model',options.model] if options.provider == 'ollama' else []
    answer = json.loads(cli('chat','ask',session,'--provider',options.provider,*model_flags,question))
    assert {hit['memory']['id'] for hit in answer['answer']['sources']} == expected
    assert answer['filter']['start'] == '2026-10-22T07:00:00Z' and answer['filter']['end'] == '2026-10-23T07:00:00Z'
    assert answer['filter']['app'] == 'Safari' and answer['timeZone']
    assert 'Lina' in answer['answer']['text'] and 'Thursday' in answer['answer']['text'], answer['answer']['text']
    if options.provider != 'evidence':
        assert '[1]' in answer['answer']['text'] or '[2]' in answer['answer']['text']
    followup = json.loads(cli('chat','ask',session,'--provider','evidence','--app','Safari','Comet decision'))
    assert len(followup['answer']['sources']) == 4
    assert 'start' not in followup['filter'] and 'end' not in followup['filter']
    reopened = json.loads(cli('chat','show',session))['turns']
    assert reopened[0]['filter'] == answer['filter'] and reopened[0]['timeZone'] == answer['timeZone']
    output = base/'conversation.md'
    cli('chat','export',session,str(output))
    assert answer['timeZone'] in output.read_text() and '2026-10-23T07:00:00Z' in output.read_text()
    requests = [
        {'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'search_memory','arguments':{'query':query,'mode':'keyword'}}},
        {'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':'search_memory','arguments':{'query':'on:2026-02-30'}}},
        {'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'search_memory','arguments':{'query':'Comet','app':42}}}]
    rpc = raw('mcp', input=''.join(json.dumps(value)+'\n' for value in requests))
    assert rpc.returncode == 0, rpc.stderr
    replies = [json.loads(line) for line in rpc.stdout.splitlines()]
    assert ids(json.loads(replies[0]['result']['content'][0]['text'])) == expected
    assert all(reply['result']['isError'] for reply in replies[1:])
    server = subprocess.Popen(prefix+['serve'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        token_file = store/'api-token'
        for _ in range(100):
            if token_file.exists(): break
            assert server.poll() is None, 'The local server exited'
            time.sleep(.05)
        token = token_file.read_text()
        def get(parameters):
            request = urllib.request.Request('http://127.0.0.1:47831/v1/search?'+parameters,headers={'Authorization':'Bearer '+token})
            try:
                with urllib.request.urlopen(request,timeout=10) as response: return response.status,json.load(response)
            except urllib.error.HTTPError as error: return error.code,json.load(error)
        encoded = urllib.parse.urlencode({'query':query,'mode':'keyword'})
        for _ in range(100):
            try: status,value = get(encoded); break
            except urllib.error.URLError:
                assert server.poll() is None, 'The local server exited'
                time.sleep(.05)
        assert status == 200 and ids(value) == expected, (status,value)
        assert get(urllib.parse.urlencode({'query':'yesterday','mode':'keyword','literal':'true'}))[0] == 200
        for suffix in ['&app=Safari&app=Mail','&literal=maybe','&limit=oops','&limt=3']:
            assert get(encoded+suffix)[0] == 400, suffix
    finally:
        server.terminate()
        try: server.wait(timeout=5)
        except subprocess.TimeoutExpired: server.kill(); server.wait()
    untouched = base/'must-not-be-opened'
    evaluation = subprocess.run([str(binary),'--data',str(untouched),'eval-retrieval','--fixture',str(base/'missing-fixture.json')],capture_output=True,text=True,timeout=20)
    assert evaluation.returncode != 0 and not untouched.exists(), 'Standalone evaluation opened the capture store'
    report.update(checks='passed', source_ids=sorted(expected), time_zone=answer['timeZone'], answer=answer['answer']['text'], answer_seconds=answer['answer']['duration'])
if options.output:
    options.output.parent.mkdir(parents=True,exist_ok=True)
    options.output.write_text(json.dumps(report,indent=2)+'\n')
print('PASS: CLI/HTTP/MCP scopes and errors, literal bypass, source boundaries, persisted chat time zone, historical-scope isolation, standalone-evaluation isolation')
