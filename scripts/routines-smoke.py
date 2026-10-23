#!/usr/bin/env python3
"""Real isolated routine CLI/answer/backup processes; schedule clocks are explicit.
Optional --chat-model uses the existing local Ollama server without changing it.
No desktop, hardware, permission, power or competitor acceptance is established.
"""
import argparse,concurrent.futures,datetime,hashlib,json,pathlib,re,subprocess,tempfile,time
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary');p.add_argument('--output',required=True);p.add_argument('--chat-model');p.add_argument('--old-binary');a=p.parse_args();binary=pathlib.Path(a.binary).resolve();output=pathlib.Path(a.output).resolve();output.parent.mkdir(parents=True,exist_ok=True)
report={'format':'OSwind routine process contracts v1','state':'running','binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'scope':'Explicit-clock synthetic routine processes on isolated libraries; not physical app controls, native wake, full-model accuracy, energy or competitor evidence','checks':[]}
def save():output.write_text(json.dumps(report,indent=2)+'\n')
def stamp(date):return date.isoformat().replace('+00:00','Z')
def check(name):report['checks'].append(name);save()
save()
try:
 with tempfile.TemporaryDirectory(prefix='oswind-routines-process-') as temporary:
    root=pathlib.Path(temporary);library=root/'library'
    def cli(*args,data=library,ok=True):
        r=subprocess.run([str(binary),'--data',str(data),*map(str,args)],capture_output=True,text=True,timeout=240)
        assert (r.returncode==0)==ok,(args,r.returncode,r.stderr)
        return json.loads(r.stdout) if ok and r.stdout.strip().startswith(('{','[')) else r.stdout
    d=cli('routine','template');d.update(window='last24Hours',title='Synthetic ownership recap',prompt='Report the recorded owner and deadline with source citations.')
    now=datetime.datetime.now(datetime.timezone.utc);slot=(now+datetime.timedelta(minutes=2)).replace(second=0,microsecond=0);d['schedule'].update(timeZone='UTC',hour=slot.hour,minute=slot.minute)
    file=root/'definition.json';file.write_text(json.dumps(d));item=cli('routine','put',file,'--at',stamp(now-datetime.timedelta(days=1,seconds=100)));identifier=item['id'] if 'id' in item else item['definition']['id']
    source={'id':cli('note','Mira owns the retrieval benchmark. The prototype is due Friday.').strip()}
    no_run=cli('routine','tick','--at',stamp(slot+datetime.timedelta(seconds=1)));assert no_run['claimed'] is False
    cli('routine','scheduler','on');first=cli('routine','tick','--at',stamp(slot+datetime.timedelta(seconds=1)));assert first['status']=='completed' and first['resultAvailable']
    session=cli('chat','show',first['chatID']);assert [s['memory']['id'] for s in session['turns'][0]['answer']['sources']]==[source['id']]
    assert cli('routine','tick','--at',stamp(slot+datetime.timedelta(seconds=2)))['claimed'] is False
    check('Scheduler off prevents execution; one due occurrence persists an evidence-backed conversation with exact source IDs')
    preview=cli('routine','preview',identifier,'--at',stamp(slot));assert preview['executes'] is False and preview['source_scope']['end']==stamp(slot)
    cli('routine','put',file,ok=False);assert cli('routine','list')[0]['revision']==1
    check('Preview has explicit source window; conflicting edits preserve the original revision')
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results=list(pool.map(lambda _:cli('routine','tick','--at',stamp(slot+datetime.timedelta(days=1,seconds=1))),range(8)))
    assert sum(r.get('status')=='completed' for r in results)==1,results
    assert len(cli('routine','history',identifier))==2
    check('Eight competing CLI processes complete exactly one new schedule slot; no duplicate persisted output')
    remote=cli('routine','template');remote['ai'].update(provider='compatible',endpoint='https://example.invalid',allowRemote=True)
    remote_file=root/'remote.json';remote_file.write_text(json.dumps(remote));remote_item=cli('routine','put',remote_file)
    denied=cli('routine','run',remote_item['definition']['id']);assert denied['status']=='failed' and denied['message'].startswith('Remote processing is disabled')
    check('Remote generation is rejected by explicit routine/global permission gates')
    if a.old_binary:
        older=pathlib.Path(a.old_binary).resolve();db=library/'memory.sqlite';before=hashlib.sha256(db.read_bytes()).hexdigest()
        r=subprocess.run([str(older),'--data',str(library),'get',source['id']],capture_output=True,text=True,timeout=30)
        assert r.returncode!=0 and 'newer OSwind version' in r.stderr and hashlib.sha256(db.read_bytes()).hexdigest()==before
        report['older_writer_sha256']=hashlib.sha256(older.read_bytes()).hexdigest();check('Schema-12 writer refuses the schema-13 library without changing its database bytes')
    archive=root/'complete.oswindbackup';restored=root/'restored'
    cli('backup','create',archive);cli('backup','restore',archive,'--to',restored)
    assert cli('routine','list',data=restored)==cli('routine','list')
    assert json.loads((restored/'settings.json').read_text())['routinesEnabled'] is False
    assert len(cli('routine','history',data=restored))==3
    restored_turns=cli('chat','show',first['chatID'],data=restored)['turns'];assert restored_turns[0]['answer']['sources'][0]['memory']['id']==source['id']
    check('Full backup/restore preserves definitions, revisions, next occurrences, history and citations; automatic execution restores off')
    cli('delete',source['id']);runs=cli('routine','history',identifier);assert next(r for r in runs if r['id']==first['id'])['resultAvailable'] is False
    assert not cli('chat','show',first['chatID'])['turns']
    cli('routine','delete',identifier);assert not cli('routine','history',identifier);assert not cli('chat','list')
    check('Source erasure removes dependent result text; deleting the routine removes its result conversations and history')
    if a.chat_model:
        model_library=root/'local-model';model_source={'id':cli('note','Mira owns the retrieval benchmark. The prototype is due Friday.',data=model_library).strip()}
        local=cli('routine','template',data=model_library);local.update(title='Synthetic local-model ownership recap',window='last24Hours',prompt='Who owns the retrieval benchmark and when is the prototype due? State only these recorded facts and cite evidence.')
        local['ai'].update(provider='ollama',endpoint='http://127.0.0.1:11434',model=a.chat_model,allowRemote=False)
        local_file=root/'local.json';local_file.write_text(json.dumps(local));saved=cli('routine','put',local_file,data=model_library)
        start=time.monotonic();run=cli('routine','run',saved['definition']['id'],'--at',stamp(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=2)),data=model_library)
        report['local_model']={'model':a.chat_model,'wall_seconds':time.monotonic()-start,'status':run['status'],'scope':'One authored owner/deadline fixture with uncontrolled caches and concurrent local activity; not a broad accuracy or speed result'}
        assert run['status']=='completed',run
        turn=cli('chat','show',run['chatID'],data=model_library)['turns'][0]
        report['local_model'].update(answer=turn['answer']['text'],warnings=turn['answer']['warnings'],sources=[s['memory']['id'] for s in turn['answer']['sources']]);save()
        text=turn['answer']['text'];assert 'mira' in text.lower() and 'friday' in text.lower() and '[1]' in text
        assert report['local_model']['sources']==[model_source['id']]
        assert not [w for w in turn['answer']['warnings'] if w != 'This recap uses a distributed sample of the selected timeline, not every recorded moment.']
        check('Actual local Ollama routine result names the authored owner/deadline with the correct live citation')
    report['state']='passed';save();print('PASS',len(report['checks']),'routine process contracts')
except BaseException as error:
 report.update(state='failed',failure=str(error));save();raise
