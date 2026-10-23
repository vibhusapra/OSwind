#!/usr/bin/env python3
"""Bounded synthetic mixed-media backup/restore with concurrent real CLI work.

One APFS run with uncontrolled caches is a workload check, not a population tail
estimate, a power benchmark, or a comparison against another product.
"""
import argparse, base64, copy, hashlib, json, math, os, pathlib, re, sqlite3, subprocess, tempfile, threading, time
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', nargs='?', default='.build/release/oswindctl')
parser.add_argument('--count',type=int,default=100000)
parser.add_argument('--media',type=int,default=1000)
parser.add_argument('--media-bytes',type=int,default=262144)
parser.add_argument('--output',required=True)
args = parser.parse_args()
assert 1<=args.count<=1000000 and 1<=args.media<=args.count and 128<=args.media_bytes<=10485760
binary = pathlib.Path(args.binary).resolve(); stop = threading.Event(); concurrent = []; failures = []
report = {'fixture':{'records':args.count,'media_files':args.media,'bytes_per_media':args.media_bytes,'description':'authored short notes without bulk vectors, padded 1px PNGs; concurrent CLI notes include Apple embeddings; no personal captures'},'limits':['one run per operation','uncontrolled filesystem caches','CLI timings include process startup and store open','synthetic retained bytes, not realistic capture distribution','no power or competitor comparison']}
with tempfile.TemporaryDirectory(prefix='oswind-backup-benchmark-') as temporary:
    work = pathlib.Path(temporary); source = work/'source'; archive = work/'package.oswindbackup'; target = work/'restored'
    def cli(*arguments, data=source):
        result = subprocess.run([str(binary),'--data',str(data),*map(str,arguments)],capture_output=True,text=True,timeout=120)
        if result.returncode: raise RuntimeError((arguments,result.returncode,result.stderr))
        return result.stdout
    source_id = cli('note','Synthetic fixture template').strip()
    connection = sqlite3.connect(source/'memory.sqlite'); connection.execute('PRAGMA foreign_keys=ON'); template = json.loads(connection.execute('SELECT payload FROM memories WHERE id=?',(source_id,)).fetchone()[0])
    connection.execute('DELETE FROM memories'); connection.commit()
    image = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aM3sAAAAASUVORK5CYII=')
    image += b'\0'*(args.media_bytes-len(image)); media_names = []
    for i in range(args.media):
        relative = f'images/synthetic-{i:06}.png'; (source/relative).write_bytes(image); media_names.append(relative)
    seed_start = time.monotonic(); now = time.time(); apple_epoch = 978307200
    def records():
        for i in range(args.count):
            identifier = f'synthetic-{i:07}'; stamp = now-i
            title = f'Lunar release fixture {i:07}'; text = f'Synthetic release {i:07}: Maya owns checklist {i%97}; deadline Friday. Unique lookup marker{ i:07}. This is generated benchmark content.'
            payload = dict(template,id=identifier,timestamp=stamp-apple_epoch,app='Notes',bundleID='com.oswind.synthetic',title=title,text=text,favorite=False,tags=['benchmark'],regions=[],imagePath=media_names[i%args.media])
            for key in ('embedding','embeddingModel','audioPath','url','endTimestamp'): payload.pop(key,None)
            yield (identifier,stamp,'note','Notes',title,None,text,0,json.dumps(payload,separators=(',',':')).encode(),None,None)
    connection.executemany('INSERT INTO memories VALUES(?,?,?,?,?,?,?,?,?,?,?)',records()); connection.commit(); connection.execute('PRAGMA wal_checkpoint(TRUNCATE)'); assert connection.execute('PRAGMA foreign_key_check').fetchall()==[]; assert connection.execute('PRAGMA integrity_check').fetchone()[0]=='ok'; connection.close()
    report['fixture']['seed_seconds'] = time.monotonic()-seed_start
    report['fixture']['database_bytes'] = (source/'memory.sqlite').stat().st_size
    def query():
        started = time.monotonic(); hits = json.loads(cli('search','--mode','keyword',f'marker{args.count//2:07}'))
        assert hits and hits[0]['memory']['id']==f'synthetic-{args.count//2:07}'
        return (time.monotonic()-started)*1000
    report['baseline_search_ms'] = [query() for _ in range(5)]
    def live_work():
        i=0
        try:
            while not stop.is_set():
                started = time.monotonic(); cli('note',f'Synthetic concurrent capture {i}: recall marker streamproof'); insert_ms = (time.monotonic()-started)*1000
                search_ms = query(); concurrent.append({'insert_ms':insert_ms,'search_ms':search_ms,'offset_s':time.monotonic()-backup_start}); i+=1
                stop.wait(.05)
        except BaseException as error: failures.append(str(error))
    def measured(name, arguments):
        started = time.monotonic()
        result = subprocess.run(['/usr/bin/time','-l',str(binary),'--data',str(source),*map(str,arguments)],capture_output=True,text=True,timeout=1800)
        elapsed = time.monotonic()-started
        pathlib.Path(args.output).with_suffix('.'+name+'.log').write_text(result.stderr)
        if result.returncode:
            report.update(passed=False,failed_operation=name,error=result.stderr.splitlines()[-25:]); pathlib.Path(args.output).write_text(json.dumps(report,indent=2)+'\n'); raise RuntimeError((name,result.returncode,result.stderr))
        rss = re.search(r'^\s*(\d+)\s+maximum resident set size',result.stderr,re.M)
        value = {'seconds':elapsed,'peak_rss_bytes':int(rss.group(1)) if rss else None,'result':json.loads(result.stdout)}
        pathlib.Path(args.output).with_suffix('.'+name+'.log').write_text(result.stderr)
        report[name] = value; pathlib.Path(args.output).write_text(json.dumps(report,indent=2)+'\n')
        return value
    backup_start = time.monotonic(); writer = threading.Thread(target=live_work); writer.start()
    try: report['create'] = measured('create',['backup','create',archive])
    finally: stop.set(); writer.join(timeout=120)
    assert not writer.is_alive() and not failures, failures
    report['concurrent_cli'] = concurrent
    assert concurrent, 'backup completed without a concurrent CLI write/search sample'
    report['inspect'] = measured('inspect',['backup','inspect',archive])
    report['restore'] = measured('restore',['backup','restore',archive,'--to',target,'--fingerprint',report['create']['result']['archiveFingerprint']])
    assert report['create']['result']==report['inspect']['result']==report['restore']['result']
    assert args.count<=report['restore']['result']['memories']<=args.count+len(concurrent)+1
    assert report['restore']['result']['mediaFiles']==args.media
    with sqlite3.connect(target/'memory.sqlite') as restored:
        assert restored.execute('SELECT COUNT(*) FROM memories').fetchone()[0]==report['restore']['result']['memories']
        assert restored.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
        assert restored.execute('PRAGMA foreign_key_check').fetchall()==[]
        row = json.loads(restored.execute('SELECT payload FROM memories WHERE id=?',(f'synthetic-{args.count//2:07}',)).fetchone()[0])
        assert hashlib.sha256((target/row['imagePath']).read_bytes()).digest()==hashlib.sha256(image).digest()
    assert json.loads(cli('search','--mode','keyword',f'marker{args.count//2:07}',data=target))[0]['memory']['id']==f'synthetic-{args.count//2:07}'
    report['passed'] = True
    pathlib.Path(args.output).write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({key:({k:v for k,v in value.items() if k!='result'} if key in ('create','inspect','restore') else value) for key,value in report.items() if key!='concurrent_cli'},indent=2))
