#!/usr/bin/env python3
"""Real local visual model + CLI/HTTP/MCP proof on an explicit photo fixture.

Requires a NEW artifact directory. Copies only the supplied images into an
isolated library. Never opens normal OSwind history. Raw process outputs remain
private; the published report contains aggregate checks and timings only.
"""
import argparse, hashlib, json, pathlib, subprocess, time, urllib.error, urllib.parse, urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=pathlib.Path)
    parser.add_argument('--fixture', required=True, type=pathlib.Path)
    parser.add_argument('--model-dir', required=True, type=pathlib.Path)
    parser.add_argument('--root', required=True, type=pathlib.Path)
    args = parser.parse_args()
    binary, root = args.binary.resolve(), args.root.resolve()
    root.mkdir(mode=0o700, parents=False, exist_ok=False)
    library = root / 'library'
    fixture = json.loads(args.fixture.read_text())
    query = fixture['queries'][0]
    prefix = [str(binary), '--data', str(library)]

    def invoke(command, timeout=180):
        result = subprocess.run(command, capture_output=True, check=True, timeout=timeout)
        return json.loads(result.stdout)

    # The timed benchmark runs before other processes load the model. Host OS
    # caches and background activity remain explicitly uncontrolled.
    with (root / 'benchmark-stderr.log').open('wb') as log:
        subprocess.run(['/usr/bin/time', '-lp', str(binary), 'benchmark-visual', '--fixture', str(args.fixture.resolve()),
                        '--root', str(library), '--model-dir', str(args.model_dir.resolve()),
                        '--output', str(root / 'benchmark.json')], stdout=subprocess.DEVNULL, stderr=log, check=True, timeout=600)
    initial = invoke(prefix + ['search', '--mode', 'visual', '--details', '--literal', query])
    explicit = invoke(prefix + ['vision', 'search', '--literal', query])
    model_id = initial['modelID']

    def identities(result):
        assert result['strategy'] == 'visual-exact-source-validated'
        assert result['modelID'] == model_id
        for hit in result['hits']:
            match = hit['visual']
            assert match['modelID'] == model_id and len(match['mediaSHA256']) == 64
            assert match['frameOrdinal'] == 0 and match.get('frameTime') is None
        return [hit['memory']['id'] for hit in result['hits']]

    expected = identities(initial)
    assert expected and identities(explicit) == expected
    request = {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {
        'name': 'search_memory', 'arguments': {'query': query, 'mode': 'visual', 'literal': True}}}
    requests = [{'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-11-25'}},
                {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
                {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}, request]
    wire = subprocess.run(prefix + ['mcp'], input=''.join(json.dumps(item)+'\n' for item in requests), capture_output=True, text=True, check=True, timeout=180)
    responses = [json.loads(line) for line in wire.stdout.splitlines()]
    assert len(responses) == 3
    tools = responses[1]['result']['tools']
    search = next(tool for tool in tools if tool['name'] == 'search_memory')
    assert 'visual' in search['inputSchema']['properties']['mode']['enum']
    mcp = responses[2]['result']
    assert not mcp.get('isError', False)
    assert identities(json.loads(mcp['content'][0]['text'])) == expected

    server = subprocess.Popen(prefix + ['serve'], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        token_path = library / 'api-token'
        for _ in range(100):
            if token_path.exists():
                break
            assert server.poll() is None, 'Isolated API process exited'
            time.sleep(.05)
        token = token_path.read_text()

        def get(parameters, authorized=True):
            request = urllib.request.Request('http://127.0.0.1:47831/v1/search?'+urllib.parse.urlencode(parameters),
                                             headers={'Authorization': 'Bearer '+token} if authorized else {})
            with urllib.request.urlopen(request, timeout=180) as response:
                return json.load(response)

        parameters = {'query': query, 'mode': 'visual', 'literal': 'true'}
        for _ in range(100):
            try:
                http = get(parameters)
                break
            except urllib.error.URLError as error:
                if isinstance(error, urllib.error.HTTPError):
                    raise
                assert server.poll() is None, 'Isolated API process exited'
                time.sleep(.05)
        else:
            raise RuntimeError('Isolated API did not listen')
        assert identities(http) == expected
        scoped = get(parameters | {'app': 'Fixture A', 'tag': 'even'})
        assert scoped['hits'] and all(hit['memory']['app'] == 'Fixture A' and 'even' in hit['memory']['tags'] for hit in scoped['hits'])
        try:
            get(parameters, authorized=False)
            raise AssertionError('Unauthenticated visual search succeeded')
        except urllib.error.HTTPError as error:
            assert error.code == 401
        # Explicit, owned fixture corruption must never pair old vectors with
        # replacement pixels. The saved original source row remains readable.
        (library / 'images/source-0.image').write_bytes(b'Owned replacement fixture bytes')
        changed = get(parameters)
        assert 'fixture-0' not in identities(changed)
        assert any('changed or have missing media' in warning for warning in changed['warnings'])
    finally:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
        server.stderr.close()
    report = {'scope': 'Explicit isolated photo fixture; real local model; CLI, HTTP and MCP visual retrieval. No capture/UI/energy/competitor claim.',
              'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'modelID': model_id,
              'checks': ['main CLI and explicit vision search agree', 'MCP preserves model and source identities',
                         'HTTP agrees with CLI/MCP', 'HTTP app/tag scopes', 'HTTP authentication required',
                         'changed source bytes omitted with warning'], 'passed': True}
    (root / 'process-report.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
