#!/usr/bin/env python3
"""Real product import/naming/portability on the public two-stock-voice fixture.

Generate fixture with tools/SpeechProbe/make-fixture.py. No download, TCC, live
input, persistent voice profiles, natural-meeting DER or ranking is tested here.
"""
import argparse,collections,hashlib,json,pathlib,re,subprocess,tempfile,time
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary');p.add_argument('--fixture',required=True);p.add_argument('--asr-model',required=True);p.add_argument('--speaker-model',required=True);p.add_argument('--output',required=True)
a=p.parse_args();binary=pathlib.Path(a.binary).resolve();fixture=pathlib.Path(a.fixture).resolve();reference=json.loads((fixture/'reference.json').read_text());audio=fixture/'two-speaker.wav'
assert reference['synthetic'] and len(reference['segments'])==4

def tokens(value):return re.findall(r"[a-z0-9]+(?:'[a-z]+)?",value.lower())
def distance(a,b):
    row=list(range(len(b)+1))
    for i,x in enumerate(a,1):
        out=[i]
        for j,y in enumerate(b,1):out.append(min(row[j]+1,out[-1]+1,row[j-1]+(x!=y)))
        row=out
    return row[-1]

def digest(file):return hashlib.sha256(file.read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix='oswind-speaker-product-') as directory:
    root=pathlib.Path(directory);library=root/'library'
    def cli(*args,data=library,ok=True):
        result=subprocess.run([str(binary),'--data',str(data),*map(str,args)],capture_output=True,text=True,timeout=300)
        assert (result.returncode==0)==ok,(args,result.stderr)
        return result.stdout
    def find(data=library):return json.loads(cli('search','--mode','keyword','archive',data=data))[0]['memory']
    started=time.perf_counter()
    memory=json.loads(cli('import-audio',audio,'--engine','parakeet','--native-model',pathlib.Path(a.asr_model).resolve(),'--speaker-model',pathlib.Path(a.speaker_model).resolve(),'--retain-audio'))
    elapsed=time.perf_counter()-started;transcript=memory['transcript'];info=transcript['diarization'];assert info['scope']=='recording' and info['detectedSpeakers']==2
    expected=tokens(' '.join(r['text'] for r in reference['segments']));actual=tokens(transcript['text']);wer=distance(expected,actual)/len(expected);assert wer==0
    eligible=correct=unassigned=0;wrong=[];mapping={}
    for word in transcript['segments']:
        mid=(word['start']+word['end'])/2
        r=next((r for r in reference['segments'] if r['start']+.25<=mid<=r['end']-.25),None)
        if not r:continue
        eligible+=1;label=word.get('speaker')
        if not label:unassigned+=1;continue
        if label not in mapping:mapping[label]=r['speaker']
        if mapping[label]==r['speaker']:correct+=1
        else:wrong.append(word)
    assert len(mapping)==2 and not wrong and correct/eligible>=.9,(mapping,correct,eligible,unassigned,wrong)
    # The mapping is learned from this synthetic sequence; it is not a natural
    # speaker identity test, nor independently verified word alignment.
    retained=library/memory['audioPath'];assert digest(retained)==digest(audio)
    renamed=json.loads(cli('name-speaker',memory['id'],'--from','Speaker 1','--name','Maya'))
    assert all(s.get('speaker')!='Speaker 1' for s in renamed['transcript']['segments'])
    cli('name-speaker',memory['id'],'--from','Speaker 2','--name','Maya',ok=False)
    assert find()['transcript']==renamed['transcript']
    archive=root/'meeting.oswindbackup';restored=root/'restored'
    cli('backup','create',archive);cli('backup','restore',archive,'--to',restored)
    reopened=find(restored);assert reopened['transcript']==renamed['transcript'] and digest(restored/reopened['audioPath'])==digest(audio)
    exported=root/'meeting.json';cli('export',exported);interchange=root/'interchange';cli('import',exported,data=interchange)
    text=find(interchange);assert text['transcript']==renamed['transcript'] and 'audioPath' not in text
    cli('delete',memory['id']);assert not retained.exists() and audio.exists()
    report={'scope':'OSwind integrated import, naming, redaction-compatible persistence, search and portability on stock-voice A/B/A/B synthetic audio','synthetic':True,'duration_seconds':reference['seconds'],'fixture_sha256':digest(audio),'reference':reference,'wall_import_seconds':elapsed,'normalized_WER':wer,'timed_words':len(transcript['segments']),'speaker_info':info,'assigned_words':sum(s.get('speaker') is not None for s in transcript['segments']),'eligible_words_with_250ms_edge_collar':eligible,'eligible_correct_assigned':correct,'eligible_unassigned':unassigned,'eligible_wrong_assigned':wrong,'anonymous_label_mapping_in_this_fixture':mapping,'checks':['real native local-only ASR+diarization saved and retrieved','recording-local naming persists and refuses merging two identities','retained original bytes match; full backup restores speaker metadata and audio','text interchange preserves sanitized speaker metadata and strips media','erasure removes owned clip; fixture remains'],'limits':['clean generated voices, four known utterances, not natural-meeting DER/WDER or independent word-alignment ground truth','coverage/unknowns reported; accuracy among assigned words alone can conceal abstention','no live speaker tracking, persistent cross-recording identities, microphone/TCC/UI acceptance, power or competitor ranking','wall time includes model load, normalization, inference, redaction, insertion and indexing; caches uncontrolled']}
    pathlib.Path(a.output).write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
