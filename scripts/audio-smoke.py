#!/usr/bin/env python3
"""Real CLI audio contracts using generated PCM + a deterministic ASR process.

This tests ingestion, persistence/privacy and portability, not recognition quality.
"""
import argparse, hashlib, json, pathlib, subprocess, tempfile, wave
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('binary',nargs='?',default='.build/debug/oswindctl');parser.add_argument('--output');args=parser.parse_args();binary=pathlib.Path(args.binary).resolve()
with tempfile.TemporaryDirectory(prefix='oswind-audio-smoke-') as temporary:
    root=pathlib.Path(temporary); source=root/'source'; source.mkdir(mode=0o700)
    audio=root/'fixture.wav'
    with wave.open(str(audio),'wb') as file:
        file.setnchannels(1);file.setsampwidth(2);file.setframerate(16000);file.writeframes(b'\xe8\x03'*32000)
    digest=hashlib.sha256(audio.read_bytes()).hexdigest()
    model=root/'dummy-model';model.write_bytes(b'synthetic')
    fixture=root/'speech.json'
    executable=root/'fixture-asr';executable.write_text('#!/usr/bin/env python3\nimport json,pathlib,sys\nprefix=pathlib.Path(sys.argv[sys.argv.index("-of")+1])\nfixture=pathlib.Path(__file__).with_name("speech.json")\nprefix.with_suffix(".json").write_bytes(fixture.read_bytes())\n');executable.chmod(0o700)
    (source/'settings.json').write_text(json.dumps({'whisperBinary':str(executable),'whisperModel':str(model)}))
    def speech(text):fixture.write_text(json.dumps({'transcription':[{'offsets':{'from':0,'to':1000},'text':text}]}))
    def cli(*arguments,data=source,ok=True):
        result=subprocess.run([str(binary),'--data',str(data),*map(str,arguments)],capture_output=True,text=True,timeout=60)
        assert (result.returncode==0)==ok,(arguments,result.returncode,result.stderr)
        return result.stdout
    speech('Maya owns the Friday release checklist')
    memory=json.loads(cli('import-audio',audio,'--retain-audio'));retained=source/memory['audioPath']
    assert memory['transcript']['duration']==2 and memory['transcript']['segments'][0]['end']==1 and memory['audioSessionID']
    assert hashlib.sha256(retained.read_bytes()).hexdigest()==digest and retained.stat().st_mode&0o777==0o600
    assert json.loads(cli('search','--mode','keyword','checklist'))[0]['memory']['id']==memory['id']
    speech('password=synthetic123')
    redacted=json.loads(cli('import-audio',audio,'--retain-audio'))
    assert redacted.get('audioPath') is None and redacted['text']=='[REDACTED]' and redacted['transcript']['segments'][0]['text']=='[REDACTED]'
    package=root/'audio.oswindbackup';restored=root/'restored'
    cli('backup','create',package);cli('backup','restore',package,'--to',restored)
    reopened=json.loads(cli('search','--mode','keyword','checklist',data=restored))[0]['memory']
    assert reopened['transcript']==memory['transcript'] and reopened['audioSessionID']==memory['audioSessionID']
    assert hashlib.sha256((restored/reopened['audioPath']).read_bytes()).hexdigest()==digest
    cli('delete',memory['id']);assert not retained.exists() and hashlib.sha256(audio.read_bytes()).hexdigest()==digest
    invalid=root/'invalid.wav';invalid.write_text('not an audio container');cli('import-audio',invalid,'--retain-audio',ok=False)
    report={'passed':True,'fixture':'generated 2-second 16 kHz PCM; deterministic external ASR emits one timestamped segment','checks':['CLI file preparation, timestamp/session persistence and keyword retrieval','original clip retained privately, source never changed','detected secret suppresses complete raw clip and redacts both text representations','full media backup/restore preserves transcript/session and audio bytes','erasure removes owned clip only; malformed input fails'],'limits':['mock ASR does not establish recognition quality','native capture/panels/playback acceptance remains separate']}
    if args.output:pathlib.Path(args.output).write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
