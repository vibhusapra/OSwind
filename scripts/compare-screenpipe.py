#!/usr/bin/env python3
"""Compare authenticated keyword HTTP reads over identical authored text.

Requires the pinned official Screenpipe ARM64 CLI and an already signed OSwind
CLI. No installation, permission changes, services, normal history or capture.
See docs/SCREENPIPE-COMPARISON.md for the protocol and its limits.
"""
import argparse
import ctypes
import datetime
import hashlib
import json
import math
import os
import pathlib
import platform
import random
import re
import secrets
import signal
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from screenpipe_oracle import text_rows as screenpipe_text_rows

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCREENPIPE_VERSION = '0.4.53'
SCREENPIPE_SOURCE = '6e237a53d877eb5470737874b4d213de4c76c421'
SCREENPIPE_ARCHIVE_SHA = 'b9fd0a4975808329fdbdd3948ffdfc59406e823ef41150c8cab94f94bb5e3d48'
# The official signed executable, rather than the compressed release asset.
SCREENPIPE_SHA = '601fdd01a71cbd77c1cd1fafd8979e84cf1ccb0f4e028713cdd2d6b71026d895'
ID = re.compile(r'^oswbench([0-9]{6})\n')


def sha(path):
    with pathlib.Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True)+'\n')
    temporary.replace(path)


def clock_snapshot():
    result = dict(utcUnix=time.time(), monotonicSeconds=time.monotonic())
    for key in ['sleeptime', 'waketime']:
        try:
            raw = subprocess.run(['/usr/sbin/sysctl', '-n', 'kern.'+key], capture_output=True, text=True, timeout=2)
            match = re.search(r'\bsec\s*=\s*(\d+)', raw.stdout)
            result[key+'Unix'] = int(match.group(1)) if match else None
        except (OSError, subprocess.TimeoutExpired):
            result[key+'Unix'] = None
    return result


def clock_span(start, end):
    wall = end['utcUnix']-start['utcUnix']
    monotonic = end['monotonicSeconds']-start['monotonicSeconds']
    return dict(utcElapsedSeconds=wall, monotonicElapsedSeconds=monotonic,
                clockDifferenceSeconds=wall-monotonic, start=start, end=end)


def quantiles(values):
    values = sorted(values)
    middle = len(values)//2
    return dict(n=len(values), medianMS=(values[middle]+values[~middle])/2,
                p95MS=values[math.ceil(.95*len(values))-1], maxMS=values[-1])


def corpus(count):
    source = ROOT/'benchmarks/fixtures/desktop-retrieval-v1.json'
    query_source = ROOT/'benchmarks/fixtures/lexical-comparison-v1.json'
    documents = json.loads(source.read_text())['documents']
    queries = json.loads(query_source.read_text())['queries']
    rows = []
    for index, document in enumerate(documents):
        rows.append(dict(id=f'oswbench{index:06d}', label=document['id'],
                         text=f'oswbench{index:06d}\n'+document['title']+'\n'+document['text']))
    rng = random.Random(1729)
    words = 'cedar fern amber moss pebble gravel spruce thistle meadow'.split()
    while len(rows) < count:
        index = len(rows)
        rows.append(dict(id=f'oswbench{index:06d}', label=f'filler-{index}',
                         text=f'oswbench{index:06d}\nAuthored archive entry. '+
                         ' '.join(rng.choices(words, k=40))+'.'))
    shared = [dict(q, id=f'lexical-{index}') for index, q in enumerate(queries) if 'app' not in q]
    unsupported = [dict(q, reason='Transcription import does not carry app identity; no matched app-filter comparison.')
                   for q in queries if 'app' in q]
    for index in [0, len(documents), count-1]:
        shared.append(dict(id=f'identity-{index}', query=f'oswbench{index:06d}', expected=[rows[index]['label']]))
    return rows, shared, unsupported


def decode_hits(product, response, rows):
    """Require exact original text and unique known source identity, not hit count."""
    lookup = {r['id']: r for r in rows}
    hits = response['hits'] if product == 'oswind' else response['data']
    labels = []
    for hit in hits:
        if product == 'screenpipe' and hit['type'] != 'Audio':
            raise ValueError('Unexpected source type')
        text = hit['memory']['text'] if product == 'oswind' else hit['content']['transcription']
        match = ID.match(text)
        if not match:
            raise ValueError('Unidentified or non-authored source')
        key = 'oswbench'+match.group(1)
        if key not in lookup or text != lookup[key]['text']:
            raise ValueError('Unknown or changed source text')
        if product == 'oswind' and hit['memory']['id'] != key:
            raise ValueError('Source ID differs from its authored content')
        labels.append(lookup[key]['label'])
    if len(labels) != len(set(labels)):
        raise ValueError('Duplicate source identities in one response')
    return labels


def score(expected, found):
    first = found[0] if found else None
    expected, found = set(expected), set(found)
    intersection = len(expected & found)
    return dict(exactSet=expected == found,
                recall=intersection/len(expected) if expected else None,
                precision=intersection/len(found) if found else None,
                hitAt1=first in expected if expected else None,
                absentReturnedEmpty=not found if not expected else None)


class Client:
    def __init__(self, port, token):
        self.port, self.token = port, token
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(self, path, body=None, authenticate=True):
        headers = {'Content-Type': 'application/json', 'x-screenpipe-client': 'api'}
        if authenticate:
            headers['Authorization'] = 'Bearer '+self.token
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(f'http://127.0.0.1:{self.port}'+path, data=data, headers=headers)
        started = time.perf_counter_ns()
        with self.opener.open(request, timeout=15) as response:
            payload = response.read(8*1024*1024+1)
        elapsed = (time.perf_counter_ns()-started)/1e6
        if len(payload) > 8*1024*1024:
            raise ValueError('Response exceeds benchmark bound')
        return json.loads(payload), elapsed, len(payload)

    def get(self, path):
        return self.request(path)[0]


def port_available(port):
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(('127.0.0.1', port))
        return sock.getsockname()[1]


class Child:
    def __init__(self, argv, directory, environment, log_name='process.log'):
        self.log_path = directory/log_name
        self.log = self.log_path.open('wb')
        try:
            self.process = subprocess.Popen(argv, stdout=self.log, stderr=subprocess.STDOUT,
                                            env=environment, start_new_session=True)
        except BaseException:
            self.log.close()
            raise

    def stop(self):
        p, forced = self.process, []
        for sig, seconds in [(signal.SIGINT, 15), (signal.SIGTERM, 10), (signal.SIGKILL, 5)]:
            if p.poll() is not None:
                break
            try:
                os.killpg(p.pid, sig)
            except ProcessLookupError:
                break
            if sig != signal.SIGINT:
                forced.append(sig.name)
            try:
                p.wait(timeout=seconds)
            except subprocess.TimeoutExpired:
                continue
        p.wait(timeout=1)
        self.log.close()
        try:
            os.killpg(p.pid, 0)
            group_absent = False
            os.killpg(p.pid, signal.SIGTERM)
        except ProcessLookupError:
            group_absent = True
        return dict(pid=p.pid, returncode=p.returncode, forced=forced, processGroupAbsent=group_absent,
                    logSHA256=sha(self.log_path))


def ready(child, client, health_path):
    deadline = time.monotonic()+45
    while child.process.poll() is None and time.monotonic() < deadline:
        try:
            return client.get(health_path)
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            time.sleep(.1)
    raise RuntimeError('Owned server did not become ready')


def screenpipe_health(value):
    ui = value['ui_recorder']
    required = ['running', 'input_tap_running', 'app_events_running', 'clipboard_capture']
    if value['frame_status'] != 'disabled' or value['audio_status'] != 'disabled' or any(ui[k] for k in required) or ui['events_inserted'] != 0:
        raise ValueError('Capture isolation is not established')
    return {k: value[k] for k in ['version', 'status', 'frame_status', 'audio_status', 'ui_recorder']}


def storage(directory):
    files = [p for p in directory.rglob('*') if p.is_file()]
    return dict(files=len(files), logicalBytes=sum(p.stat().st_size for p in files))


def sandbox_argv(binary, directory, port, metal, profile=None):
    argv = ['/usr/bin/sandbox-exec', '-f', str(profile or ROOT/'scripts/comparisons/screenpipe-backend.sb')]
    for key, value in dict(USER_DIRECTORY=pathlib.Path.home(), TASK_ROOT=directory, BINARY=binary,
                           METAL=metal, API_ADDRESS='localhost:'+str(port)).items():
        argv += ['-D', key+'='+str(value)]
    return argv


def permission_ipc_status():
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    bootstrap = ctypes.c_uint.in_dll(library, 'bootstrap_port').value
    lookup = library.bootstrap_look_up
    lookup.argtypes = [ctypes.c_uint, ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint)]
    lookup.restype = ctypes.c_int
    port = ctypes.c_uint()
    status = lookup(bootstrap, b'com.apple.tccd', ctypes.byref(port))
    if status == 0:
        library.mach_port_deallocate(library.mach_task_self(), port)
    return status


def sandbox_canary(binary, directory, port, metal, outside, profile=None):
    """Exercise denials on authored data before starting either real server."""
    if permission_ipc_status() != 0:
        raise ValueError('Permission IPC negative control needs a reachable parent baseline')
    outside.write_text('AUTHORED_OUTSIDE_CANARY')
    script = directory/'sandbox-canary.py'
    script.write_text('''import ctypes,json,pathlib,socket,sys
root=pathlib.Path(sys.argv[1]);outside=pathlib.Path(sys.argv[2]);port=int(sys.argv[3]);result={}
library=ctypes.CDLL('/usr/lib/libSystem.B.dylib');bootstrap=ctypes.c_uint.in_dll(library,'bootstrap_port').value
lookup=library.bootstrap_look_up;lookup.argtypes=[ctypes.c_uint,ctypes.c_char_p,ctypes.POINTER(ctypes.c_uint)];lookup.restype=ctypes.c_int
permission_port=ctypes.c_uint();permission_status=lookup(bootstrap,b'com.apple.tccd',ctypes.byref(permission_port));result['knownPermissionIPCDenied']=permission_status!=0
if permission_status==0:library.mach_port_deallocate(library.mach_task_self(),permission_port)
(root/'inside.txt').write_text('AUTHORED_INSIDE')
result['insideReadWrite']=(root/'inside.txt').read_text()=='AUTHORED_INSIDE'
for operation in ['read','write']:
 try:
  outside.read_text() if operation=='read' else outside.write_text('FORBIDDEN')
  result[operation+'OutsideDenied']=False
 except PermissionError:result[operation+'OutsideDenied']=True
s=socket.socket();s.settimeout(2)
try:s.connect(('192.0.2.1',443));result['externalConnectDenied']=False
except PermissionError:result['externalConnectDenied']=True
except Exception:result['externalConnectDenied']=False
s.close();s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',port));s.listen()
c=socket.socket();c.connect(('127.0.0.1',port));a,_=s.accept();c.sendall(b'OWNED_LOOPBACK');result['dedicatedLoopbackWorks']=a.recv(50)==b'OWNED_LOOPBACK'
c.shutdown(socket.SHUT_WR);assert a.recv(1)==b'';a.close();assert c.recv(1)==b'';c.close();s.close();s=socket.socket()
try:s.bind(('127.0.0.1',0));result['unassignedLoopbackBindDenied']=False
except PermissionError:result['unassignedLoopbackBindDenied']=True
s.close();print(json.dumps(result));assert all(result.values())
''')
    # /usr/bin/python3 and its standard library are outside the denied user
    # directory. No home-variable override, credential environment or imports
    # from user packages are needed.
    argv = sandbox_argv(binary, directory, port, metal, profile)+['/usr/bin/python3', str(script), str(directory), str(outside), str(port)]
    result = subprocess.run(argv, capture_output=True, text=True, timeout=15,
                            env={'PATH': '/usr/bin:/bin', 'TMPDIR': str(directory/'tmp')})
    if result.returncode != 0 or outside.read_text() != 'AUTHORED_OUTSIDE_CANARY':
        raise ValueError('Sandbox canary failed: '+result.stderr[:500])
    values = json.loads(result.stdout)
    if not values or not all(value is True for value in values.values()):
        raise ValueError('Sandbox canary did not prove all declared checks')
    if permission_ipc_status() != 0:
        raise ValueError('Permission IPC parent baseline disappeared')
    return values


def sqlite_rows(path, query):
    connection = sqlite3.connect('file:'+str(path.resolve())+'?mode=ro', uri=True)
    try:
        # The stock Screenpipe index registers a custom elements virtual table.
        # Read-only writable_schema lets independent SQLite inspect ordinary
        # tables without loading or executing that vendor module. No write occurs.
        connection.execute('PRAGMA writable_schema=ON')
        return connection.execute(query).fetchall()
    finally:
        connection.close()


def audit_sources(root, rows, use_parquet=False):
    expected = sorted(r['text'] for r in rows)
    own = sqlite_rows(root/'oswind/data/memory.sqlite', 'SELECT id,text FROM memories ORDER BY id')
    indexes = list((root/'screenpipe/data').rglob('index.sqlite'))
    if len(indexes) != 1:
        raise ValueError('Expected one isolated Screenpipe index')
    other, archive = screenpipe_text_rows(indexes[0], root/'screenpipe/data', use_parquet=use_parquet)
    if own != sorted((r['id'], r['text']) for r in rows) or sorted(r[1] for r in other) != expected:
        raise ValueError('Stored original corpus differs')
    counts = {table: sqlite_rows(indexes[0], 'SELECT COUNT(*) FROM '+table)[0][0]
              for table in ['frames', 'ui_events', '_bulk_element_lookup']}
    if any(counts.values()):
        raise ValueError('Unexpected captured or UI sources')
    if sqlite_rows(indexes[0], "SELECT COUNT(*) FROM audio_chunks WHERE file_path!=''")[0][0]:
        raise ValueError('Unexpected audio media path')
    if any(p.is_file() and p.suffix.lower() in {'.jpg', '.jpeg', '.png', '.mp4', '.wav', '.m4a'}
           for directory in ['screenpipe/data', 'oswind/data'] for p in (root/directory).rglob('*')):
        raise ValueError('Unexpected capture media')
    embedded = sqlite_rows(root/'oswind/data/memory.sqlite', 'SELECT COUNT(*) FROM memories WHERE embedding IS NOT NULL')[0][0]
    own_digest = hashlib.sha256(json.dumps(own, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()
    return dict(originalTextRowsEach=len(rows), originalTextsByteEqual=True, zeroCapturedCounts=counts, oswindEmbeddedSources=embedded,
                oswindSourceIdentitySHA256=own_digest, screenpipeSourceIdentitySHA256=archive['sourceIdentitySHA256'],
                mediaFiles=0, archive=archive, method='Independent read-only Python SQLite plus optional pinned Arrow decoder; physical file and per-row SHA256/generation checks; no vendor extension loaded.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--screenpipe', type=pathlib.Path, required=True)
    parser.add_argument('--oswind', type=pathlib.Path, required=True)
    parser.add_argument('--oswind-package-proof', type=pathlib.Path, required=True)
    parser.add_argument('--root', type=pathlib.Path, required=True, help='New retained output directory')
    parser.add_argument('--count', type=int, default=1000)
    parser.add_argument('--repetitions', type=int, default=5)
    parser.add_argument('--parquet', action='store_true', help='Read archived payloads with pinned pyarrow 21.0.0 (Python 3.12 wheels are hash-pinned)')
    args = parser.parse_args()
    if sys.platform != 'darwin' or not 64 <= args.count <= 10000 or not 2 <= args.repetitions <= 20:
        parser.error('Requires macOS, 64..10000 records and 2..20 repetitions')
    binary, own_binary, root = args.screenpipe.resolve(), args.oswind.resolve(), args.root.resolve()
    if sha(binary) != SCREENPIPE_SHA:
        parser.error('Screenpipe executable does not match pinned official release')
    proof_path = args.oswind_package_proof.resolve()
    supplied_proof = json.loads(proof_path.read_text())
    proof = supplied_proof.get('package', supplied_proof)
    if proof['executables']['oswindctl']['signedSHA256'] != sha(own_binary):
        parser.error('OSwind executable does not match supplied package proof')
    if root.exists() or any(root in p.parents for p in [binary, own_binary, ROOT]):
        parser.error('Use a new output directory outside all source/binary parents')
    if pathlib.Path.home() not in root.parents:
        parser.error('Run directory must be inside the user directory covered by the sandbox read-denial canary')
    subprocess.run(['codesign', '--verify', '--strict', str(binary)], check=True, capture_output=True)
    subprocess.run(['codesign', '--verify', '--strict', str(own_binary)], check=True, capture_output=True)
    port_available(47831)
    port = port_available(0)
    root.mkdir(mode=0o700, parents=True)
    for name in ['screenpipe', 'screenpipe/tmp', 'oswind', 'oswind/tmp', 'oswind/data', 'tmp']:
        (root/name).mkdir(mode=0o700)
    rows, queries, unsupported = corpus(args.count)
    fixture = root/'corpus.json'
    write(fixture, rows)
    inputs = [pathlib.Path(__file__), ROOT/'scripts/comparisons/screenpipe-backend.sb',
              ROOT/'scripts/screenpipe_oracle.py',
              ROOT/'benchmarks/fixtures/desktop-retrieval-v1.json', ROOT/'benchmarks/fixtures/lexical-comparison-v1.json',
              binary, binary.with_name('mlx.metallib'), own_binary, proof_path, fixture]
    parquet_dependency = None
    if args.parquet:
        import pyarrow
        if pyarrow.__version__ != '21.0.0':
            parser.error('Use pinned pyarrow 21.0.0 for the physical payload oracle')
        dependency_root = pathlib.Path(pyarrow.__file__).parent
        dependencies = [p for p in dependency_root.rglob('*') if p.is_file() and p.suffix in ['.py', '.so', '.dylib']]
        inputs += dependencies+[ROOT/'benchmarks/requirements-screenpipe-oracle.txt']
        parquet_dependency = dict(version=pyarrow.__version__, frozenRuntimeFiles=len(dependencies))
    frozen = {str(p): sha(p) for p in inputs}
    report = dict(format='OSwind versus stock Screenpipe authenticated keyword HTTP component comparison',
                  version=1, state='running', oswindSource=proof['codeCommit'],
                  startedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  benchmarkCheckout=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                  screenpipe=dict(version=SCREENPIPE_VERSION, sourceTagCommit=SCREENPIPE_SOURCE, archiveSHA256=SCREENPIPE_ARCHIVE_SHA),
                  records=len(rows), seed=1729, frozen=frozen, queries=queries, unmatchedAppQueries=unsupported,
                  parquetDependency=parquet_dependency,
                  initialClock=clock_snapshot(),
                  environment=dict(macOS=platform.mac_ver()[0], architecture=platform.machine(), python=platform.python_version(),
                                   cpu=subprocess.check_output(['/usr/sbin/sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip()),
                  measurements=[], cleanup={}, limits=[
                      'Authored text database/HTTP comparison only; no capture, transcription, GUI, models, physical power or whole-product ranking.',
                      'Both stock ARM64 CLI servers run under the same file/network/desktop-permission sandbox, limited to their own directory and API port. Screenpipe health is expected to report degraded UI.',
                      'Screenpipe /add transcription accepts text without audio or historical app/time identity. OSwind imports matching note text; app/time filters are not compared.',
                      'Both shipping response shapes and query semantics remain; relevance differences are retained. Same Python HTTP client opens each request without a proxy.',
                      'Input/audit/warmup reads warm caches; no cold-start claim. Repeated Screenpipe requests may use its shipping result cache. Host/background work and sleep are uncontrolled; UTC and monotonic clock spans are retained.',
                      'OSwind import rebuilds local Apple embeddings, which are not used for keyword queries. Ingestion timings and storage are descriptive, not matched model work.',
                      'No permission grants or settings changes, login services, normal history, cloud account, external API or external model calls are used.'])
    report_path = root/'report.json'
    write(report_path, report)
    children = {}
    environment = {'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8', 'TMPDIR': str(root/'tmp')}
    token = secrets.token_urlsafe(24)
    try:
        report['sandboxCanaries'] = {
            'screenpipe': sandbox_canary(binary, root/'screenpipe', port, binary.with_name('mlx.metallib'), root/'screenpipe-outside-canary.txt'),
            'oswind': sandbox_canary(own_binary, root/'oswind', 47831, own_binary, root/'oswind-outside-canary.txt')}
        initialized = subprocess.run([str(own_binary), '--data', str(root/'oswind/data'), 'stats'],
                                     capture_output=True, env=environment, timeout=30, check=True)
        if json.loads(initialized.stdout)['count'] != 0:
            raise ValueError('OSwind library was not empty')
        own_baseline = storage(root/'oswind/data')
        imported = [dict(id=r['id'], kind='note', app='OSwindAuthoredFixture', bundleID='', title='',
                         timestamp='2026-10-22T14:00:00Z', text=r['text'], regions=[], tags=[], favorite=False) for r in rows]
        write(root/'import.json', imported)
        start = time.monotonic()
        import_clock = clock_snapshot()
        result = subprocess.run([str(own_binary), '--data', str(root/'oswind/data'), 'import', str(root/'import.json'), '--json'],
                                capture_output=True, env=environment, timeout=900)
        (root/'import.stdout').write_bytes(result.stdout)
        (root/'import.stderr').write_bytes(result.stderr)
        if result.returncode != 0 or json.loads(result.stdout)['imported'] != len(rows):
            raise ValueError('OSwind import failed or omitted sources')
        report['oswindImportSeconds'] = time.monotonic()-start
        report['oswindImportClock'] = clock_span(import_clock, clock_snapshot())
        argv = sandbox_argv(binary, root/'screenpipe', port, binary.with_name('mlx.metallib'))
        argv += [str(binary), 'record', '--data-dir', str(root/'screenpipe/data'), '--port', str(port),
                 '--disable-audio', '--disable-vision', '--disable-screenshots', '--app-context', 'off', '--disable-telemetry',
                 '--disable-snapshot-compaction', '--disable-meeting-detector', '--disable-click-capture',
                 '--disable-keyboard-capture=true', '--disable-clipboard-capture=true', '--capture-on-clipboard=false',
                 '--capture-scroll=false', '--use-pii-removal=false', '--included-windows', 'OSwindAuthoredNeverLive9e28f51507']
        children['screenpipe'] = Child(argv, root/'screenpipe', dict(environment, TMPDIR=str(root/'screenpipe/tmp'), CI='1', SCREENPIPE_API_KEY=token))
        other = Client(port, token)
        report['initialHealth'] = screenpipe_health(ready(children['screenpipe'], other, '/health'))
        report['baselineStorage'] = dict(screenpipe=storage(root/'screenpipe/data'), oswind=own_baseline)
        start = time.monotonic()
        import_clock = clock_snapshot()
        for row in rows:
            response, _, _ = other.request('/add', dict(device_name='OSwindAuthoredFixture', content=dict(
                content_type='transcription', data=dict(transcription=row['text'], transcription_engine='authored-text-no-audio'))))
            if response.get('success') is not True:
                raise ValueError('Screenpipe refused authored text')
        report['screenpipeImportSeconds'] = time.monotonic()-start
        report['screenpipeImportClock'] = clock_span(import_clock, clock_snapshot())
        # The stock macOS database uses a process-exclusive VFS. Independently
        # inspect it only after a real graceful stop, then restart the same API.
        report['preAuditStop'] = children.pop('screenpipe').stop()
        if report['preAuditStop']['forced'] or not report['preAuditStop']['processGroupAbsent'] or report['preAuditStop']['returncode'] != 0:
            raise ValueError('Screenpipe did not close cleanly for independent audit')
        report['beforeQueries'] = audit_sources(root, rows, use_parquet=args.parquet)
        children['screenpipe'] = Child(argv, root/'screenpipe', dict(environment, TMPDIR=str(root/'screenpipe/tmp'), CI='1', SCREENPIPE_API_KEY=token),
                                        log_name='query-process.log')
        report['queryHealth'] = screenpipe_health(ready(children['screenpipe'], other, '/health'))
        # Prepare a benchmark-only credential before entering the sandbox.
        # Foundation's first atomic token write may use an external replacement
        # directory, which this process sandbox intentionally cannot write.
        own_token = secrets.token_hex(32)
        token_path = root/'oswind/data/api-token'
        token_path.write_text(own_token)
        token_path.chmod(0o600)
        own_argv = sandbox_argv(own_binary, root/'oswind', 47831, own_binary)
        children['oswind'] = Child(own_argv+[str(own_binary), '--data', str(root/'oswind/data'), 'serve'], root/'oswind',
                                    dict(environment, TMPDIR=str(root/'oswind/tmp')))
        own = Client(47831, own_token)
        ready(children['oswind'], own, '/health')
        clients = dict(screenpipe=other, oswind=own)
        def search(product, query):
            params = dict(query=query, mode='keyword', limit=20) if product == 'oswind' else dict(q=query, content_type='audio', limit=20)
            path = '/v1/search' if product == 'oswind' else '/search'
            response, milliseconds, size = clients[product].request(path+'?'+urllib.parse.urlencode(params))
            return decode_hits(product, response, rows), milliseconds, size
        report['warmup'] = []
        query_clock = clock_snapshot()
        for query in queries:
            for product in ['screenpipe', 'oswind']:
                labels, ms, size = search(product, query['query'])
                report['warmup'].append(dict(product=product, queryID=query['id'], labels=labels, milliseconds=ms, responseBytes=size, **score(query['expected'], labels)))
        for repetition in range(args.repetitions):
            for query_index, query in enumerate(queries):
                for product in (['screenpipe', 'oswind'] if (repetition+query_index) % 2 == 0 else ['oswind', 'screenpipe']):
                    labels, ms, size = search(product, query['query'])
                    report['measurements'].append(dict(product=product, queryID=query['id'], repetition=repetition,
                                                       labels=labels, milliseconds=ms, responseBytes=size, **score(query['expected'], labels)))
            write(report_path, report)
        report['queryClock'] = clock_span(query_clock, clock_snapshot())
        if abs(report['queryClock']['clockDifferenceSeconds']) > 1:
            raise ValueError('Query UTC and monotonic clocks diverged; latency qualification refused')
        report['finalHealth'] = screenpipe_health(other.get('/health'))
        report['storageAtEnd'] = {k: storage(root/p) for k, p in [('screenpipe', 'screenpipe/data'), ('oswind', 'oswind/data')]}
        report['summary'] = {}
        for product in ['screenpipe', 'oswind']:
            samples = [r for r in report['measurements'] if r['product'] == product]
            positives = [r for r in samples if r['recall'] is not None]
            report['summary'][product] = dict(**quantiles([r['milliseconds'] for r in samples]),
                                             exactSets=sum(r['exactSet'] for r in samples), observations=len(samples),
                                             failedQueryIDs=sorted(set(r['queryID'] for r in samples if not r['exactSet'])),
                                             positiveHitAt1=sum(r['hitAt1'] for r in positives)/len(positives),
                                             meanPositiveRecall=sum(r['recall'] for r in positives)/len(positives),
                                             responseBytes=sum(r['responseBytes'] for r in samples))
        report['state'] = 'completed'
    except BaseException as error:
        report['state'] = 'failed'
        report['errorType'] = type(error).__name__
        report['error'] = str(error)[:1000]
        if isinstance(error, urllib.error.HTTPError):
            report['httpErrorCode'] = error.code
            report['httpErrorBody'] = error.read(4096).decode(errors='replace')
    finally:
        for name, child in reversed(list(children.items())):
            try:
                report['cleanup'][name] = child.stop()
            except Exception as error:
                report['cleanup'][name] = dict(errorType=type(error).__name__, error=str(error)[:300], forced=['cleanup-error'])
        report['inputsUnchanged'] = all(sha(p) == digest for p, digest in frozen.items())
        if not report['inputsUnchanged'] or any(x['forced'] or not x.get('processGroupAbsent') or x.get('returncode') not in [0, -2, 130]
                                               for x in report['cleanup'].values()):
            report['state'] = 'failed'
        if report['state'] == 'completed':
            try:
                report['afterShutdown'] = audit_sources(root, rows, use_parquet=args.parquet)
                keys = ['oswindSourceIdentitySHA256', 'screenpipeSourceIdentitySHA256', 'oswindEmbeddedSources']
                if any(report['afterShutdown'][key] != report['beforeQueries'][key] for key in keys):
                    raise ValueError('Corpus changed after shutdown')
            except Exception as error:
                report.update(state='failed', auditError=str(error))
        report['finishedAtUTC'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        report['totalClock'] = clock_span(report['initialClock'], clock_snapshot())
        write(report_path, report)
    print(json.dumps(dict(state=report['state'], records=len(rows), summary=report.get('summary'), root=str(root)), indent=2))
    return 0 if report['state'] == 'completed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
