#!/usr/bin/env python3
"""Synthetic separate-process backup/restore, corruption and interruption checks."""
import argparse, base64, hashlib, json, os, pathlib, signal, sqlite3, subprocess, tempfile, time, wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', nargs='?', default='.build/debug/oswindctl')
parser.add_argument('--output')
parser.add_argument('--interruptions', action='store_true', help='Include a sparse 2 GiB media fixture and SIGINT/SIGKILL checks')
args = parser.parse_args()
binary = pathlib.Path(args.binary).resolve()
checks = []
with tempfile.TemporaryDirectory(prefix='oswind-backup-smoke-') as temporary:
    work = pathlib.Path(temporary)
    source, archive, restored = (work/name for name in ('source','archive.oswindbackup','restored'))
    ignored = work/'must-not-open'
    temp = work/'temporary'; temp.mkdir(mode=0o700)
    environment = dict(os.environ, TMPDIR=str(temp)+'/')
    def cli(*arguments, data=ignored, ok=True, timeout=60):
        result = subprocess.run([str(binary),'--data',str(data),*map(str,arguments)],env=environment,capture_output=True,text=True,timeout=timeout)
        if ok:
            assert result.returncode==0, (arguments,result.returncode,result.stderr)
        else:
            assert result.returncode!=0, (arguments,result.stdout)
        return result
    identifier = cli('note','Lunar release decision: Maya owns the checklist; deadline Friday.',data=source).stdout.strip()
    chat = json.loads(cli('chat','new',data=source).stdout)['id']
    cli('chat','ask',chat,'--provider','evidence','Who owns the Lunar release checklist?',data=source)
    (source/'images').mkdir(exist_ok=True); (source/'audio').mkdir(exist_ok=True)
    image = source/'images/synthetic.png'
    image.write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aM3sAAAAASUVORK5CYII='))
    audio = source/'audio/synthetic.wav'
    with wave.open(str(audio),'wb') as file:
        file.setnchannels(1); file.setsampwidth(2); file.setframerate(16000); file.writeframes(b'\0\0'*1600)
    with sqlite3.connect(source/'memory.sqlite') as connection:
        payload = json.loads(connection.execute('SELECT payload FROM memories WHERE id=?',(identifier,)).fetchone()[0])
        payload.update(imagePath='images/synthetic.png',audioPath='audio/synthetic.wav',favorite=True,tags=['synthetic','backup'])
        connection.execute('UPDATE memories SET payload=?,favorite=1 WHERE id=?',(json.dumps(payload).encode(),identifier))
    (source/'api-token').write_text('SYNTHETIC-SECRET-EXCLUDED')
    (source/'indexes').mkdir(exist_ok=True); (source/'indexes/disposable-test-cache').write_text('rebuild me')
    original = {path.relative_to(source).as_posix():hashlib.sha256(path.read_bytes()).hexdigest() for path in (image,audio)}
    created = json.loads(cli('backup','create',archive,data=source).stdout)
    inspected = json.loads(cli('backup','inspect',archive).stdout)
    assert created==inspected and inspected['memories']==1 and inspected['mediaFiles']==2 and inspected['conversations']==1
    assert inspected['encryption']=='none' and len(inspected['archiveFingerprint'])==64
    assert not (archive/'api-token').exists() and not (archive/'indexes').exists()
    assert archive.stat().st_mode & 0o777==0o700
    cli('backup','restore',archive,'--to',restored,'--fingerprint',inspected['archiveFingerprint'])
    assert not ignored.exists(), 'inspection/restore opened an unrelated normal store'
    hits = json.loads(cli('search','--mode','keyword','--details','Lunar',data=restored).stdout)
    # --details is an envelope on current CLI; tolerate a direct hit list for older adapters.
    hits = hits['hits'] if isinstance(hits,dict) else hits
    assert hits[0]['memory']['id']==identifier
    settings = json.loads((restored/'settings.json').read_text())
    assert all(settings.get(key) is False for key in ('captureOnLaunch','apiEnabled','audioEnabled','systemAudioEnabled','automaticMaintenance'))
    assert settings['ai']['allowRemote'] is False
    with sqlite3.connect(restored/'memory.sqlite') as connection:
        record = json.loads(connection.execute('SELECT payload FROM memories WHERE id=?',(identifier,)).fetchone()[0])
        for key,old in [('imagePath','images/synthetic.png'),('audioPath','audio/synthetic.wav')]:
            assert hashlib.sha256((restored/record[key]).read_bytes()).hexdigest()==original[old]
        assert record['favorite'] and record['tags']==['synthetic','backup']
        assert connection.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
        assert connection.execute('PRAGMA foreign_key_check').fetchall()==[]
    reopened = json.loads(cli('chat','show',chat,data=restored).stdout)
    assert len(reopened['turns'])==1 and 'Maya' in reopened['turns'][0]['answer']['text']
    cli('chat','ask',chat,'--provider','evidence','And its deadline?',data=restored)
    assert len(json.loads(cli('chat','show',chat,data=restored).stdout)['turns'])==2
    checks.append('media/chat/metadata round trip, fingerprint, private permissions, quiet settings, isolated routing and reusable library')
    keep = restored/'keep'; keep.write_text('keep')
    cli('backup','restore',archive,'--to',restored,ok=False); assert keep.read_text()=='keep'
    cli('backup','create',archive,data=source,ok=False)
    wrong = work/'wrong-fingerprint'; cli('backup','restore',archive,'--to',wrong,'--fingerprint','0'*64,ok=False); assert not wrong.exists()
    blob = next((archive/'media').iterdir()); good = blob.read_bytes(); blob.write_bytes(b'corrupt')
    invalid = work/'invalid'; cli('backup','inspect',archive,ok=False); cli('backup','restore',archive,'--to',invalid,ok=False); assert not invalid.exists()
    blob.write_bytes(good)
    before = (archive/'header.json').read_bytes()
    cli('backup','inspect',archive)
    assert (archive/'header.json').read_bytes()==before
    checks.append('existing destinations, fingerprint mismatch and corrupted media refused without target publication')
    if args.interruptions:
        # Sparse synthetic bytes: no recording or personal content. Hashing forces
        # long enough cancellable work even on filesystems with instant COW clones.
        with audio.open('r+b') as file: file.truncate(2*1024**3)
        for interrupt in (signal.SIGINT,signal.SIGKILL):
            destination = work/('interrupted-'+str(interrupt)+'.oswindbackup')
            process = subprocess.Popen([str(binary),'--data',str(source),'backup','create',str(destination)],env=environment,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            started = time.monotonic(); lines = []
            try:
                for line in process.stderr:
                    lines.append(line.rstrip())
                    if 'Verifying media' in line:
                        active = json.loads(cli('backup','cleanup','--directory',work).stdout)
                        assert active['removed_jobs']==0
                        active_scratch=json.loads(cli('backup','cleanup','--directory',source/'audio/.staging').stdout);assert active_scratch['removed_jobs']==0
                        assert list((source/'audio/.staging').glob('.oswind-job-*'))
                        process.send_signal(interrupt); break
                    assert time.monotonic()-started<60, lines
                output, error = process.communicate(timeout=30)
                assert process.returncode==(130 if interrupt==signal.SIGINT else -signal.SIGKILL), (process.returncode,lines,error,output)
                assert not destination.exists()
                cleanup = json.loads(cli('backup','cleanup','--directory',work).stdout)
                scratch_cleanup = json.loads(cli('backup','cleanup','--directory',source/'audio/.staging').stdout)
                legacy_cleanup = json.loads(cli('backup','cleanup').stdout)
                if interrupt==signal.SIGKILL: assert cleanup['removed_jobs']>=1 and scratch_cleanup['removed_jobs']>=1
                assert not list(work.glob('.oswind-job-*')) and not list(temp.glob('.oswind-job-*')) and not list((source/'audio/.staging').iterdir())
                checks.append({'interrupt':signal.Signals(interrupt).name,'elapsed_s':time.monotonic()-started,'destination_jobs_removed':cleanup['removed_jobs'],'scratch_jobs_removed':scratch_cleanup['removed_jobs']})
            finally:
                if process.poll() is None: process.kill(); process.wait()
        assert 'Lunar' in cli('search','--mode','keyword','Lunar',data=source).stdout
    report = {'fixture':'synthetic note, 1px PNG, silent PCM WAV, saved evidence chat','checks':checks,'passed':True,'interruptions':args.interruptions}
    if args.output: pathlib.Path(args.output).write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
