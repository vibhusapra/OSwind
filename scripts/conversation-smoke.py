#!/usr/bin/env python3
"""Reopen persisted chats across real CLI processes, export, and erase sources."""
import argparse, json, pathlib, subprocess, tempfile, sys
parser = argparse.ArgumentParser()
parser.add_argument("binary", nargs="?", default=".build/debug/oswindctl")
parser.add_argument("--provider", choices=["evidence","apple","ollama"], default="evidence")
parser.add_argument("--output")
options = parser.parse_args()
binary = pathlib.Path(options.binary).resolve()
with tempfile.TemporaryDirectory(prefix='oswind-chat-smoke-') as directory:
    prefix = [str(binary), '--data', directory]
    def cli(*args): return subprocess.check_output(prefix+list(args), text=True, timeout=60)
    source = cli('note', 'Lunar release decision: Maya owns the checklist; deadline Friday.').strip()
    session = json.loads(cli('chat','new'))['id']
    first = json.loads(cli('chat','ask',session,'--provider',options.provider,'Who owns the Lunar release checklist?'))
    assert source in [hit['memory']['id'] for hit in first['answer']['sources']]
    followup = json.loads(cli('chat','ask',session,'--provider',options.provider,'And its deadline?'))
    assert source in [hit['memory']['id'] for hit in followup['answer']['sources']]
    if options.output:
        pathlib.Path(options.output).write_text(json.dumps({'fixture':'Lunar release; Maya checklist; Friday deadline','provider':options.provider,'first':first['answer'],'followup':followup['answer']},indent=2)+'\n')
    assert 'Maya' in first['answer']['text'] and 'Friday' in followup['answer']['text'], (first['answer']['text'], followup['answer']['text'])
    assert '[1]' in first['answer']['text'] and '[1]' in followup['answer']['text'], (first['answer']['text'], followup['answer']['text'])
    reopened = json.loads(cli('chat','show',session))
    assert len(reopened['turns']) == 2 and reopened['turns'][1]['question']=='And its deadline?'
    output = pathlib.Path(directory)/'conversation.md'
    cli('chat','export',session,str(output))
    assert 'Friday' in output.read_text() and 'Memory ID:' in output.read_text()
    assert output.stat().st_mode & 0o777 == 0o600
    cli('delete',source)
    erased = json.loads(cli('chat','show',session))
    assert erased['turns']==[] and erased['session']['title']=='Conversation'
    cli('chat','delete',session)
    assert json.loads(cli('chat','list'))==[]
    print('PASS: separate-process chat persistence/follow-up, Markdown export/permissions, source-derived answer erasure, session deletion')
