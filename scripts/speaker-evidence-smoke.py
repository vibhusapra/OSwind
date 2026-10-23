#!/usr/bin/env python3
"""Actual native import -> recording-local names -> retrieval -> cited answers.

Uses only the authored stock-voice fixture and installed local models. Reports
all model answers, including failures; this is not natural-meeting accuracy,
a blinded evaluation, cross-recording recognition or a competitor benchmark.
"""
import argparse, hashlib, json, pathlib, re, subprocess, tempfile, time
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('binary');p.add_argument('--fixture',required=True);p.add_argument('--asr-model',required=True);p.add_argument('--speaker-model',required=True);p.add_argument('--chat-model');p.add_argument('--output',required=True)
a=p.parse_args();binary=pathlib.Path(a.binary).resolve();fixture=pathlib.Path(a.fixture).resolve()
assert json.loads((fixture/'reference.json').read_text())['synthetic']
with tempfile.TemporaryDirectory(prefix='oswind-speaker-evidence-') as directory:
    library=pathlib.Path(directory)/'library'
    def cli(*args):
        result=subprocess.run([str(binary),'--data',str(library),*map(str,args)],capture_output=True,text=True,timeout=300)
        assert result.returncode==0,(args,result.stderr)
        return json.loads(result.stdout)
    started=time.perf_counter()
    source=cli('import-audio',fixture/'two-speaker.wav','--engine','parakeet','--native-model',pathlib.Path(a.asr_model).resolve(),'--speaker-model',pathlib.Path(a.speaker_model).resolve())
    import_seconds=time.perf_counter()-started
    source=cli('name-speaker',source['id'],'--from','Speaker 1','--name','Maya')
    source=cli('name-speaker',source['id'],'--from','Speaker 2','--name','Theo')
    assert 'Maya' not in source['text'] and 'Theo' not in source['text']
    names=cli('search','--mode','keyword','Maya');assert [h['memory']['id'] for h in names]==[source['id']]
    filtered=cli('search','--mode','keyword','--speaker','Theo','archive');assert [h['memory']['id'] for h in filtered]==[source['id']]
    evidence=cli('ask','--provider','evidence','Who owns capture? speaker:Maya')
    assert '[1]' in evidence['text'] and 'speaker "Maya"' in evidence['text'] and 'speaker "Theo"' in evidence['text'],evidence['text']
    assert 'Speaker annotations' in evidence['text'] # actual ASR words must align; a raw fallback cannot satisfy this
    questions=[
        ('Who owns the capture tests?',['Maya']),
        ('Who will handle local model setup?',['Theo']),
        ('Who will verify the restored copy?',['Theo']),
        ('speaker:Maya What does Maya want restored together?',['media','transcript']),
        ('Did Maya volunteer to handle local model setup?',['Theo']),
        ('Did Maya promise a budget of 500 dollars?',[]),
    ]
    answers=[]
    if a.chat_model:
        for question,expected in questions:
            before=time.perf_counter();answer=cli('ask','--provider','ollama','--model',a.chat_model,question)
            citations=[int(n) for n in re.findall(r'\[(\d+)\]',answer['text'])]
            valid_citations=all(1<=n<=len(answer['sources']) for n in citations)
            # Transparent authored string checks, not a semantic accuracy score.
            checks={word:word.casefold() in answer['text'].casefold() for word in expected}
            answers.append({'question':question,'provider':answer['provider'],'answer':answer['text'],'wall_seconds':time.perf_counter()-before,'source_ids':[h['memory']['id'] for h in answer['sources']],'warnings':answer.get('warnings',[]),'expected_strings':expected,'expected_string_presence':checks,'citations':citations,'valid_citation_indices':valid_citations,'has_citation':bool(citations)})
            print(json.dumps(answers[-1]),flush=True)
    report={'synthetic':True,'scope':'Real native ASR/diarization, two manual recording-local names, indexed retrieval and local cited answers on one authored 32-second fixture','binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'fixture_sha256':hashlib.sha256((fixture/'two-speaker.wav').read_bytes()).hexdigest(),'import_wall_seconds':import_seconds,'transcript':source['transcript'],'evidence_answer':evidence['text'],'chat_model':a.chat_model,'answers':answers,'checks':['names absent from raw source yet indexed keyword and structured scope retrieval pass','actual timed ASR aligns to original source; rendered evidence includes both named voices and unknown spans','every model response and citation validity is reported, including failures'],'limits':['one clean generated A/B/A/B recording; not natural meeting DER/WER or independent speaker identity ground truth','manual names are local labels, not recognition across recordings','expected string checks are transparent and incomplete; inspect every published response','uncontrolled model/OS caches and existing GPU runtime; no power/competitor/SOTA claim']}
    report['source_files_sha256']={str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(pathlib.Path('Sources/OSwindCore').glob('*.swift')) if path.name in {'MemoryStore.swift','SpeakerSearch.swift','AudioEvidence.swift','AI.swift','Retrieval.swift','Models.swift','EvidenceText.swift','QueryScopeResolver.swift','Integration.swift'}}
    pathlib.Path(a.output).write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'output':a.output,'import_wall_seconds':import_seconds,'answers':[{'question':x['question'],'answer':x['answer'],'checks':x['expected_string_presence']} for x in answers]},indent=2))
