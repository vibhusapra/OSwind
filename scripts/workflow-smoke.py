#!/usr/bin/env python3
"""Owned CLI workflow, real local speech, SIGINT/SIGKILL and recovery checks."""
import argparse, datetime, hashlib, json, os, pathlib, signal, sqlite3, struct, subprocess, time, zlib
from owned_sqlite_fixture import register_inactive_sync_fixture

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('cli',type=pathlib.Path)
parser.add_argument('--root',type=pathlib.Path,required=True)
parser.add_argument('--helper',type=pathlib.Path,required=True)
a=parser.parse_args();cli=a.cli.resolve();root=a.root.resolve()
assert not root.exists(),'Use a new owned fixture directory'
root.mkdir(mode=0o700,parents=True);library=root/'library'
report={'state':'running','scope':'Owned retained PNG, deliberate CLI export, actual installed local speech, owned interruption helper only','checks':[]}
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def save():(root/'report.json').write_text(json.dumps(report,indent=2)+'\n')
def check(name,condition):
    assert condition,name
    report['checks'].append(name);save()
def command(*args):return [str(cli),'--data',str(library),*map(str,args)]
def run(name,*args,ok=True,timeout=90):
    result=subprocess.run(command(*args),capture_output=True,timeout=timeout)
    (root/(name+'.stdout')).write_bytes(result.stdout);(root/(name+'.stderr')).write_bytes(result.stderr)
    check(name,(result.returncode==0)==ok)
    return json.loads(result.stdout) if ok else result
def png():
    width,height=640,360
    data=b''.join(b'\0'+b''.join(bytes((24,82,204) if 80<=x<260 and 80<=y<200 else (255,255,255)) for x in range(width)) for y in range(height))
    def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(data))+chunk(b'IEND',b'')
def child_present(pid):
    try:os.kill(pid,0);return True
    except ProcessLookupError:return False
def interrupted(kind):
    pidfile=root/(kind+'-child.pid');helper=root/(kind+'-holding-helper.py')
    helper.write_text('#!/usr/bin/python3\nimport os,pathlib,signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\npathlib.Path('+repr(str(pidfile))+').write_text(str(os.getpid()))\nwhile True:time.sleep(1)\n');helper.chmod(0o700)
    output=root/(kind+'-unpublished')
    with (root/(kind+'.stdout')).open('wb')as stdout,(root/(kind+'.stderr')).open('wb')as stderr:
        process=subprocess.Popen(command('workflow','export','--draft',draftfile,'--output',output,'--helper',helper),stdout=stdout,stderr=stderr)
        deadline=time.monotonic()+20
        while not pidfile.exists() and process.poll()is None and time.monotonic()<deadline:time.sleep(.02)
        check(kind+' owned worker entered',pidfile.exists() and process.poll()is None)
        child=int(pidfile.read_text());process.send_signal(signal.SIGINT if kind=='sigint' else signal.SIGKILL)
        code=process.wait(timeout=20)
        check(kind+' process result',code==(130 if kind=='sigint' else -signal.SIGKILL))
        deadline=time.monotonic()+12
        while child_present(child) and time.monotonic()<deadline:time.sleep(.02)
        check(kind+' actual child stopped',not child_present(child))
    check(kind+' never published',not output.exists())
    if kind=='sigint':check('sigint removed private workspaces',not list((library/'video/.staging').iterdir()))
try:
    save();run('initialize','stats');image=library/'images/owned.png';image.write_bytes(png());original=sha(image)
    source={'id':'owned-workflow-cli','timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'kind':'screen','app':'Owned fixture','bundleID':'dev.oswind.owned','title':'Authored screen','text':'Owned source','imagePath':'images/owned.png','regions':[],'favorite':False,'tags':[]}
    sourcefile=root/'source.json';sourcefile.write_text(json.dumps([source]));run('import-source','import',sourcefile)
    # JSON text import deliberately drops media associations. Install only our
    # authored PNG association as a fixture; this is not live capture evidence.
    db=sqlite3.connect(library/'memory.sqlite');register_inactive_sync_fixture(db)
    try:
        with db:
            payload=json.loads(db.execute('SELECT payload FROM memories WHERE id=?',(source['id'],)).fetchone()[0]);payload['imagePath']='images/owned.png'
            db.execute('UPDATE memories SET payload=? WHERE id=?',(json.dumps(payload).encode(),source['id']))
    finally:db.close()
    check('owned SQL image association installed',sha(image)==original)
    frame=run('inspect-frame','workflow','frame',source['id']);check('source binding hashes original pixels',frame['source']['mediaSHA256']==original)
    run('invalid-frame','workflow','frame',source['id'],'--frame','1',ok=False)
    run('duplicate-frame','workflow','frame',source['id'],'--frame','0','--frame','0',ok=False)
    run('unknown-option','workflow','frame',source['id'],'--unknown',ok=False)
    draft=frame['draft'];draftfile=root/'draft.json';draftfile.write_text(json.dumps(draft))
    run('blank-script','workflow','export','--draft',draftfile,'--output',root/'blank','--helper',a.helper,ok=False)
    draft['steps'][0]['narration']='This retained screen has a blue rectangle on a white background. OSwind keeps the original source linked to this step.';draftfile.write_text(json.dumps(draft))
    interrupted('sigint');interrupted('sigkill')
    output=root/'portable-workflow';info=run('real-local-export','workflow','export','--draft',draftfile,'--output',output,'--helper',a.helper)
    check('actual speech has measured duration',info['steps']==1 and info['duration']>1 and info['plaintextIndependentCopy'])
    manifest=json.loads((output/'workflow.json').read_text())
    check('every portable payload hash matches',all(sha(output/f['path'])==f['sha256'] and (output/f['path']).stat().st_size==f['bytes'] for f in manifest['files']))
    check('movie hash matches result',sha(output/'workflow.mp4')==info['movieSHA256'])
    for timing in output.glob('*.timing.json'):
        value=json.loads(timing.read_text());check(timing.name+' portable audio path',value['audio']==timing.name.replace('.timing.json','.wav'))
    check('scripts captions and retained frames included',all((output/name).is_file() for name in ['narration.txt','narration.wav','step-01-narration.txt','step-01-narration.wav','step-01.png','captions.vtt','index.html','README.txt']))
    check('no database or credentials exported',not any((output/name).exists() for name in ['memory.sqlite','settings.json','api-token']))
    check('orphan workspace recovered on next export',not list((library/'video/.staging').iterdir()))
    before={p.name:sha(p)for p in output.iterdir()}
    run('existing-destination','workflow','export','--draft',draftfile,'--output',output,'--helper',a.helper,ok=False)
    check('existing output bytes preserved',before=={p.name:sha(p)for p in output.iterdir()})
    run('inside-library','workflow','export','--draft',draftfile,'--output',library/'must-not-export','--helper',a.helper,ok=False)
    source['text']='Changed owned source';sourcefile.write_text(json.dumps([source]));run('update-source','import',sourcefile)
    run('stale-source','workflow','export','--draft',draftfile,'--output',root/'stale','--helper',a.helper,ok=False)
    check('original pixels unchanged',sha(image)==original)
    check('history remains readable',run('get-source','get',source['id'])['text']==source['text'])
    report.update(state='passed',cliSHA256=sha(cli),movieSHA256=info['movieSHA256'],measuredDuration=info['duration'],export=str(output),limits=['No native user input, live capture, physical power, fresh-machine setup or whole-product ranking acceptance'])
except BaseException as error:
    report.update(state='failed',error=str(error));save();raise
finally:save()
print('PASS:',len(report['checks']),'owned workflow CLI, actual local speech and interruption checks')
