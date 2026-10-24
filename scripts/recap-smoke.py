#!/usr/bin/env python3
"""Owned linked-recap persistence, erasure, JSON/Markdown/backup and old-writer contracts."""
import argparse,contextlib,hashlib,json,pathlib,re,sqlite3,subprocess,tempfile
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary');p.add_argument('--older-binary');p.add_argument('--provider',choices=['evidence','ollama'],default='evidence');p.add_argument('--output');o=p.parse_args();binary=pathlib.Path(o.binary).resolve();older=pathlib.Path(o.older_binary).resolve() if o.older_binary else None;pins={str(b):hashlib.sha256(b.read_bytes()).hexdigest() for b in [binary,older] if b}
@contextlib.contextmanager
def connect(path):
    db=sqlite3.connect(path)
    try:
        with db:yield db
    finally:db.close()
with tempfile.TemporaryDirectory(prefix='oswind-recap-contract-') as temporary:
    root=pathlib.Path(temporary);library=root/'library'
    def cli(*args,data=library,runner=binary,ok=True):
        result=subprocess.run([str(runner),'--data',str(data),*map(str,args)],capture_output=True,text=True,timeout=240)
        assert (result.returncode==0)==ok,(args,result.returncode,result.stdout,result.stderr)
        return json.loads(result.stdout) if result.returncode==0 and result.stdout.lstrip().startswith(('{','[')) else result.stdout+result.stderr
    parent=dict(id='parent',timestamp='2026-10-23T20:00:00Z',kind='note',app='Notes',bundleID='com.oswind.private',title='Release decision',text='Lunar release. Maya owns the checklist. The deadline is Friday.',favorite=False,tags=[],regions=[])
    other=dict(parent,id='other',app='Other',bundleID='com.oswind.other',title='Unrelated recipe',text='A separate soup recipe.')
    input_path=root/'input.json';input_path.write_text(json.dumps([parent,other]));cli('import',input_path,runner=older or binary)
    with connect(library/'memory.sqlite') as db:identity=db.execute("SELECT value FROM store_metadata WHERE key='identity'").fetchone()[0];previous_schema=db.execute('PRAGMA user_version').fetchone()[0]
    assert cli('stats')['count']==2
    with connect(library/'memory.sqlite') as db:assert db.execute('PRAGMA user_version').fetchone()[0]==15 and db.execute("SELECT value FROM store_metadata WHERE key='identity'").fetchone()[0]==identity
    if older:
        before=hashlib.sha256((library/'memory.sqlite').read_bytes()).hexdigest();assert 'newer' in cli('delete','parent',runner=older,ok=False).lower();assert hashlib.sha256((library/'memory.sqlite').read_bytes()).hexdigest()==before
    chat=cli('chat','new');turn=cli('chat','ask',chat['id'],'--provider',o.provider,'Who owns the checklist and when is it due for "Lunar release"?');assert {x['memory']['id'] for x in turn['answer']['sources']}=={'parent'}
    if o.provider=='ollama':assert 'maya' in turn['answer']['text'].lower() and 'friday' in turn['answer']['text'].lower() and '[1]' in turn['answer']['text']
    first=cli('chat','save-recap',chat['id'],'--turn',turn['id'],'--title','Saved release');assert first['kind']=='summary' and first['recap']['sources'][0]['id']=='parent'
    next_turn=cli('chat','ask',chat['id'],'--provider',o.provider,'What was recorded in "Saved release"?');assert {x['memory']['id'] for x in next_turn['answer']['sources']}=={first['id']};assert any('Saved recaps' in x for x in next_turn['answer']['warnings'])
    second=cli('chat','save-recap',chat['id'],'--turn',next_turn['id'],'--title','Second level');assert second['recap']['sources'][0]['id']==first['id']
    cli('chat','save-recap',chat['id'],'--turn','missing',ok=False)
    preview=cli('erase','preview','--app','Notes');assert preview['matchedSources']==1 and preview['sources']==3
    exported=root/'all.json';cli('export',exported);clone=root/'json-clone';imported=cli('import',exported,'--json',data=clone);assert imported==dict(imported=4,excluded=0,skippedLinkedRecaps=0)
    filtered=root/'filtered';settings=cli('config',data=filtered);settings['privacy']['excludedApps']=['com.oswind.private'];(filtered/'settings.json').write_text(json.dumps(settings))
    omitted=cli('import',exported,'--json',data=filtered);assert omitted==dict(imported=1,excluded=1,skippedLinkedRecaps=2)
    markdown=root/'markdown';info=cli('export-markdown',markdown);assert info['memories']==4
    for file in markdown.rglob('*.md'):
        for target in re.findall(r'\]\(([^)]+)\)',file.read_text()):assert (file.parent/target).resolve().exists(),(file,target)
    settings=cli('config');settings['privacy']['excludedApps']=['com.oswind.private'];(library/'settings.json').write_text(json.dumps(settings))
    hidden=root/'hidden-markdown';info=cli('export-markdown',hidden);assert info['memories']==1 and info['excludedMemories']==3 and info['excludedTurns']==2
    archive=root/'library.oswindbackup';cli('backup','create',archive);restored=root/'restored';cli('backup','restore',archive,'--to',restored)
    assert cli('get',second['id'],data=restored)['recap']['sources'][0]['id']==first['id']
    erased=cli('delete','parent','--json',data=restored);assert erased['sources']==3 and erased['conversationTurns']==2 and cli('stats',data=restored)['count']==1
    revised=dict(parent,text='Lunar release. Theo owns the new checklist.');input_path.write_text(json.dumps([revised]));cli('import',input_path,data=clone)
    assert cli('stats',data=clone)['count']==2
    for identifier in [first['id'],second['id']]:cli('get',identifier,data=clone,ok=False)
    final=cli('erase','preview','--app','Notes');erased=cli('erase','apply','--app','Notes','--token',final['token']);assert erased['sources']==3 and cli('stats')['count']==1
    for data in [library,clone,restored,filtered]:
        with connect(data/'memory.sqlite') as db:assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok' and not db.execute('PRAGMA foreign_key_check').fetchall()
assert all(hashlib.sha256(pathlib.Path(b).read_bytes()).hexdigest()==s for b,s in pins.items())
report=dict(format='OSwind linked recap process v1',answers=[{k:t['answer'][k] for k in ['text','provider','duration','warnings']} for t in [turn,next_turn]],binary_sha256=pins[str(binary)],schema_version=15,provider=o.provider,specific_turn_save_and_second_level_chain=True,saved_time_warning=True,scope_preview_closure=True,json_roundtrip_links_preserved=True,filtered_import_omits_dependent_recaps=True,markdown_links_resolve=True,filtered_markdown_omits_recaps_and_cited_turns=True,full_backup_restores_links=True,source_revision_and_erasure_remove_chain=True,sqlite_integrity_pass=True,older_writer=dict(binary_sha256=pins[str(older)],source_schema=previous_schema,target_schema=15,upgrade_identity_preserved=True,refusal_database_bytes_preserved=True) if older else None,limits=['Owned fixtures and pinned executables; not native clicks, natural answer quality, secure SSD wiping or already-open older-process fencing'])
if o.output:
    output=pathlib.Path(o.output).resolve();output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
