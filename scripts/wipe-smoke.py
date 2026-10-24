#!/usr/bin/env python3
"""Owned full-library wipe, media admission, retry and interruption contracts."""
import argparse,contextlib,fcntl,hashlib,json,pathlib,select,signal,sqlite3,subprocess,tempfile,time,os
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary');p.add_argument('--older-binary');p.add_argument('--interruptions',action='store_true');p.add_argument('--output');a=p.parse_args();binary=pathlib.Path(a.binary).resolve();older=pathlib.Path(a.older_binary).resolve() if a.older_binary else None;pins={str(x):hashlib.sha256(x.read_bytes()).hexdigest() for x in [binary,older] if x}
@contextlib.contextmanager
def db(root):
    conn=sqlite3.connect(root/'memory.sqlite')
    try:
        with conn:yield conn
    finally:conn.close()
def cli(root,*args,runner=binary,ok=True):
    r=subprocess.run([str(runner),'--data',str(root),*map(str,args)],capture_output=True,text=True,timeout=120);assert (r.returncode==0)==ok,(args,r.returncode,r.stdout,r.stderr)
    if ok and args[0]=='note':return {'id':r.stdout.strip()}
    return json.loads(r.stdout) if ok and r.stdout.lstrip().startswith(('{','[')) else r.stdout+r.stderr
def wait_phase(process,phase,timeout=30):
    deadline=time.monotonic()+timeout;received=b''
    while time.monotonic()<deadline:
        if select.select([process.stderr],[],[],.1)[0]:
            chunk=os.read(process.stderr.fileno(),4096);received+=chunk
            if phase.encode() in received:return received.decode().splitlines()
        assert process.poll() is None,(process.returncode,received.decode())
    raise AssertionError(('Expected phase',phase,received.decode()))
def start(root):return subprocess.Popen([str(binary),'--data',str(root),'wipe','--confirm','DELETE-ALL','--json'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
with tempfile.TemporaryDirectory(prefix='oswind-owned-wipe-') as temporary:
    work=pathlib.Path(temporary);root=work/'library';first=cli(root,'note','Earlier source',runner=older or binary)
    with db(root) as c:previous=c.execute('PRAGMA user_version').fetchone()[0];identity=c.execute("SELECT value FROM store_metadata WHERE key='identity'").fetchone()[0]
    assert cli(root,'stats')['count']==1
    with db(root) as c:
        schema=c.execute('PRAGMA user_version').fetchone()[0];assert schema>=16 and c.execute("SELECT value FROM store_metadata WHERE key='identity'").fetchone()[0]==identity
    if older:
        before=hashlib.sha256((root/'memory.sqlite').read_bytes()).hexdigest();assert 'newer' in cli(root,'delete',first['id'],runner=older,ok=False).lower();assert hashlib.sha256((root/'memory.sqlite').read_bytes()).hexdigest()==before
    for args in [('wipe',),('wipe','--confirm','WRONG'),('wipe','--confirm','DELETE-ALL','--extra'),('wipe','retry','--confirm','DELETE-ALL')]:cli(root,*args,ok=False)
    assert cli(root,'stats')['count']==1
    (root/'images/known').write_bytes(b'known');(root/'audio/nested').mkdir();(root/'audio/nested/orphan').write_bytes(b'orphan');(root/'video/orphan').write_bytes(b'video')
    outside=work/'outside';outside.write_bytes(b'preserve');(root/'images/link').symlink_to(outside)
    (root/'indexes').mkdir(exist_ok=True);(root/'indexes/disposable').write_bytes(b'private disposable index')
    with db(root) as c:
        payload=json.loads(c.execute('SELECT payload FROM memories WHERE id=?',(first['id'],)).fetchone()[0]);payload.update(imagePath='images/known',favorite=True);c.execute('UPDATE memories SET payload=?,favorite=1 WHERE id=?',(json.dumps(payload).encode(),first['id']))
    with (root/'.media-admission.lock').open('a+b') as lock:
        os.chmod(root/'.media-admission.lock',0o600);fcntl.flock(lock,fcntl.LOCK_SH)
        process=start(root);wait_phase(process,'Waiting for active media writers');assert cli(root,'stats')['count']==1 and process.poll() is None
        later=cli(root,'note','Arrived before the wipe acquired admission');(root/'images/writer-pending').write_bytes(b'committing supported writer fixture')
        with db(root) as c:
            payload=json.loads(c.execute('SELECT payload FROM memories WHERE id=?',(later['id'],)).fetchone()[0]);payload['imagePath']='images/writer-pending';c.execute('UPDATE memories SET payload=? WHERE id=?',(json.dumps(payload).encode(),later['id']))
        fcntl.flock(lock,fcntl.LOCK_UN)
        out,err=process.communicate(timeout=60);assert process.returncode==0,(out,err);wiped=json.loads(out)
    assert wiped['erasure']['sources']==2 and wiped['erasure']['removedMedia']==4 and wiped['erasure']['pendingMedia']==1 and not wiped['cleanupComplete'] and wiped['compacted']
    assert cli(root,'stats')['count']==0 and not (root/'indexes').exists() and outside.read_bytes()==b'preserve'
    with db(root) as c:assert c.execute('SELECT path FROM erasure_assets').fetchall()==[('images/link',)] and c.execute("SELECT value FROM store_metadata WHERE key='library_wipe_dirty'").fetchone()[0]=='1'
    assert cli(root,'wipe','retry','--json')['erasure']['pendingMedia']==1
    (root/'images/link').unlink();(root/'images/link').write_bytes(b'new live media');(root/'audio/new-orphan').write_bytes(b'new unreferenced media')
    fresh=cli(root,'note','Fresh history after the committed wipe')
    with db(root) as c:
        payload=json.loads(c.execute('SELECT payload FROM memories WHERE id=?',(fresh['id'],)).fetchone()[0]);payload['imagePath']='images/link';c.execute('UPDATE memories SET payload=? WHERE id=?',(json.dumps(payload).encode(),fresh['id']))
    retry=cli(root,'wipe','retry','--json');assert retry['cleanupComplete'] and retry['erasure']['sharedMedia']==1 and retry['erasure']['sources']==0
    assert cli(root,'stats')['count']==1 and (root/'images/link').read_bytes()==b'new live media' and (root/'audio/new-orphan').read_bytes()==b'new unreferenced media'
    # The real CLI installs SIGINT cancellation while blocked on the shared lease.
    with (root/'.media-admission.lock').open('r+b') as lock:
        fcntl.flock(lock,fcntl.LOCK_SH);process=start(root);wait_phase(process,'Waiting for active media writers');process.send_signal(signal.SIGINT);out,err=process.communicate(timeout=10);assert process.returncode==130,(process.returncode,out,err);fcntl.flock(lock,fcntl.LOCK_UN)
    assert cli(root,'stats')['count']==1
    with db(root) as c:assert c.execute('PRAGMA integrity_check').fetchone()[0]=='ok' and not c.execute('PRAGMA foreign_key_check').fetchall()
    interruptions=[]
    if a.interruptions:
        for sig in [signal.SIGINT,signal.SIGKILL]:
            interrupted=work/('interrupt-'+str(sig.value));cli(interrupted,'note','Erase this source')
            session=cli(interrupted,'chat','new');turn=cli(interrupted,'chat','ask',session['id'],'--provider','evidence','"Erase this source"');cli(interrupted,'chat','save-recap',session['id'],'--turn',turn['id'])
            for i in range(10000):(interrupted/'images'/str(i)).write_bytes(b'owned')
            process=start(interrupted);phases=wait_phase(process,'Removing retained media');process.send_signal(sig);out,err=process.communicate(timeout=90)
            assert process.returncode==(0 if sig==signal.SIGINT else -signal.SIGKILL),(process.returncode,out,err)
            if sig==signal.SIGINT:
                value=json.loads(out);assert value['cancelled'] and value['erasure']['sources']==2 and not value['cleanupComplete']
            assert cli(interrupted,'stats')['count']==0
            with db(interrupted) as c:pending=c.execute('SELECT COUNT(*) FROM erasure_assets').fetchone()[0];assert pending>0
            remaining=len(list((interrupted/'images').iterdir()));assert remaining==pending
            retried=cli(interrupted,'wipe','retry','--json');assert retried['cleanupComplete'] and retried['erasure']['sources']==0 and not list((interrupted/'images').iterdir())
            interruptions.append({'signal':sig.name,'remaining_files_equal_durable_queue':remaining,'retry_complete':True,'source_deletion_committed':True})
assert all(hashlib.sha256(pathlib.Path(x).read_bytes()).hexdigest()==h for x,h in pins.items())
report={'format':'OSwind full-library wipe process v1','binary_sha256':pins[str(binary)],'schema_version':schema,'older_writer':{'binary_sha256':pins[str(older)],'source_schema':previous,'target_schema':schema,'upgrade_identity_preserved':True,'refusal_database_bytes_preserved':True} if older else None,'invalid_inputs_preserve_history':True,'shared_admission_delays_wipe_without_blocking_reads_or_note_writes':True,'referenced_and_orphan_media_deleted':4,'unsafe_symlink_queued_target_preserved':True,'retry_preserves_new_sources_live_media_and_orphans':True,'sigint_before_commit_preserves_history':True,'integrity_and_foreign_keys_pass':True,'interruptions':interruptions,'limits':['Owned fixture and cooperative admission protocol; raw SQLite/manual file writers and already-open older executables are outside fencing','SIGINT/SIGKILL are process interruption tests, not storage-power failure or secure SSD wiping','Not native clicks, capture power or competitor evidence']}
if a.output:
    target=pathlib.Path(a.output);target.parent.mkdir(parents=True,exist_ok=True);target.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
