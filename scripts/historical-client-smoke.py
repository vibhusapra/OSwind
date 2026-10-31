#!/usr/bin/env python3
"""Actual old25 executable against its owned library after a current26 upgrade.
No desktop capture, normal history, settings/TCC changes or provider credentials.
"""
import argparse,contextlib,hashlib,json,pathlib,sqlite3,subprocess,time

p=argparse.ArgumentParser();p.add_argument('binary',type=pathlib.Path);p.add_argument('--old-cli',type=pathlib.Path,required=True);p.add_argument('--old-sha256',required=True);p.add_argument('--root',type=pathlib.Path,required=True);a=p.parse_args()
def sha(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
binary=a.binary.resolve();old=a.old_cli.resolve();base=a.root.absolute()
assert base.resolve()==base and not base.exists() and base.parent.is_dir()
assert binary.is_file() and old.is_file() and sha(old)==a.old_sha256
base.mkdir(mode=0o700);(base/'owned-fixture').write_text('OSwind authored old25 client compatibility v1')
library=base/'library';db=library/'memory.sqlite';events=[];child=None
report=dict(state='running',currentCLI_SHA256=sha(binary),oldCLI_SHA256=sha(old),harnessSHA256=sha(pathlib.Path(__file__)),checks=[],operations=events,scope='Actual schema25 executable, owned synthetic text and complete process exits. No native recording, enrolled service, media playback, power or competitor evidence.')
def save(): (base/'report.json').write_text(json.dumps(report,indent=2)+'\n')
def run(cli,*args,ok=True,data=None):
    r=subprocess.run([str(cli),'--data',str(data or library),*map(str,args)],capture_output=True,text=True,timeout=45)
    n=len(events);(base/('%02d.stdout'%n)).write_text(r.stdout);(base/('%02d.stderr'%n)).write_text(r.stderr)
    events.append(dict(binary='old25' if cli==old else 'current26',arguments=list(map(str,args)),returncode=r.returncode,stdoutSHA256=hashlib.sha256(r.stdout.encode()).hexdigest(),stderrSHA256=hashlib.sha256(r.stderr.encode()).hexdigest()));save()
    assert (r.returncode==0)==ok,r.stderr
    return r

def source_snapshot():
    with contextlib.closing(sqlite3.connect(db.as_uri()+'?mode=ro',uri=True)) as c:return c.execute('SELECT id,hex(payload) FROM memories ORDER BY id').fetchall()
def physical(): return {x.name:sha(x) for x in library.glob('memory.sqlite*') if x.is_file()}
try:
    save();run(old,'note','Owned original schema25 text')
    with contextlib.closing(sqlite3.connect(db)) as c:assert c.execute('PRAGMA user_version').fetchone()==(25,)
    before=source_snapshot()
    child=subprocess.Popen([str(old),'--data',str(library),'collect','--stdin'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    # collect acquires this shared reservation after opening MemoryStore. This
    # proves actual initialization before migration, beyond merely spawning it.
    target='n'+str(library/'.media-admission.lock');deadline=time.monotonic()+25;ready=False
    while child.poll() is None and time.monotonic()<deadline:
        found=subprocess.run(['/usr/sbin/lsof','-a','-p',str(child.pid),'-Fn'],capture_output=True,text=True,timeout=5)
        if target in found.stdout.splitlines():ready=True;break
        time.sleep(.05)
    assert ready,'Owned old25 collector did not reach its post-open lease'
    run(binary,'stats')
    with contextlib.closing(sqlite3.connect(db)) as c:assert c.execute('PRAGMA user_version').fetchone()==(26,)
    assert source_snapshot()==before
    wire=json.dumps(dict(format='OSwind collector batch',version=1,collectorID='org.oswind.old25-fixture',records=[dict(key='owned-late-old25',timestamp='2026-10-31T11:00:00Z',text='Must never be admitted',app='Owned',bundleID='org.oswind.old25-fixture',title='Late old25 source')]))+'\n'
    output,error=child.communicate(wire,timeout=30)
    (base/'initialized-old25.stdout').write_text(output);(base/'initialized-old25.stderr').write_text(error)
    report['initializedOld25']=dict(postOpenLeaseObserved=ready,returncode=child.returncode,stderrSHA256=hashlib.sha256(error.encode()).hexdigest())
    assert child.returncode!=0 and source_snapshot()==before
    # Require a product compatibility refusal, not malformed collector input.
    assert ('newer OSwind' in error or 'oswind_historical_writer_v1' in error),error
    report['checks'].append('actual already-initialized old25 writer refuses after26 upgrade; source payloads unchanged')
    stable=physical();report['beforeFreshRefusalsSQLiteFiles']=stable;save()
    for args in [('stats',),('note','Owned fresh old25 write must refuse')]:
        r=run(old,*args,ok=False);report['afterFreshRefusalsSQLiteFiles']=physical();save();assert 'newer OSwind' in r.stderr and physical()==stable
    report['checks'].append('fresh actual old25 reader and writer refuse26; all existing SQLite file bytes unchanged')
    archive=base/'copy.oswindbackup';created=json.loads(run(binary,'backup','create',archive).stdout);assert created['sourceSchema']==26
    inspected=json.loads(run(binary,'backup','inspect',archive).stdout);assert inspected['sourceSchema']==26
    archive_before={str(x.relative_to(archive)):sha(x) for x in archive.rglob('*') if x.is_file()}
    r=run(old,'backup','inspect',archive,ok=False,data=base/'inspection-root')
    assert ('newer OSwind' in r.stderr or 'schema' in r.stderr.lower() or 'Unsupported or invalid library backup header' in r.stderr),r.stderr
    assert archive_before=={str(x.relative_to(archive)):sha(x) for x in archive.rglob('*') if x.is_file()}
    report['checks'].append('actual old25 backup inspector refuses26 package; all package bytes unchanged')
    run(binary,'note','Owned current26 write still works');assert len(source_snapshot())==2
    assert sha(old)==report['oldCLI_SHA256'] and sha(binary)==report['currentCLI_SHA256']
    report.update(state='passed',sourceSchema=25,targetSchema=26,allChildrenTerminal=True);save();print(json.dumps(report,indent=2))
except BaseException as error:
    report.update(state='failed',errorType=type(error).__name__,error=str(error));save();raise
finally:
    if child is not None and child.poll() is None:
        child.terminate()
        try:child.communicate(timeout=5)
        except subprocess.TimeoutExpired:child.kill();child.communicate(timeout=5)
