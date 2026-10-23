#!/usr/bin/env python3
"""Evaluate complete CLI imports on a caller-supplied public/consented fixture.

Compares OSwind speech configurations, not complete competitor applications.
Each trial starts a fresh process/library. Model/Core ML caches are uncontrolled.
"""
import argparse, hashlib, json, pathlib, platform, re, subprocess, tempfile, time
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('binary'); p.add_argument('--audio',required=True); p.add_argument('--reference',required=True)
p.add_argument('--native-model',required=True); p.add_argument('--whisper-model'); p.add_argument('--whisper-binary',default='/opt/homebrew/bin/whisper-cli')
p.add_argument('--trials',type=int,default=2); p.add_argument('--output',required=True)
a=p.parse_args(); binary=pathlib.Path(a.binary).resolve(); audio=pathlib.Path(a.audio).resolve(); model=pathlib.Path(a.native_model).resolve()
assert 1<=a.trials<=20

def words(text): return re.findall(r"[a-z0-9]+(?:'[a-z]+)?",text.lower())
def wer(text):
    reference=words(a.reference); candidate=words(text); row=list(range(len(candidate)+1))
    for i,x in enumerate(reference,1):
        nextrow=[i]
        for j,y in enumerate(candidate,1): nextrow.append(min(row[j]+1,nextrow[j-1]+1,row[j-1]+(x!=y)))
        row=nextrow
    return row[-1]/max(1,len(reference))
def digest(file):
    h=hashlib.sha256()
    with file.open('rb') as stream:
        while block:=stream.read(1024*1024): h.update(block)
    return h.hexdigest()
report={'scope':'whole OSwind CLI audio import; alternate ASR configurations, not competitor applications',
        'machine':platform.machine(),'reference':a.reference,'audio_sha256':digest(audio),'measurements':[],
        'native_model_files':[{'path':str(f.relative_to(model)),'bytes':f.stat().st_size,'sha256':digest(f)} for f in sorted(model.rglob('*')) if f.is_file()],
        'limits':['one short clean public fixture does not establish held-out recognition quality or word alignment accuracy','fresh process per trial includes model load, normalization, SQLite insertion and Apple embedding','existing model/Core ML caches are uncontrolled; no download included','no resident throughput, power, battery, live hardware or whole competitor comparison','compute configuration requests a Core ML policy, not proof of every operation running on that processor']}
configurations=[('parakeet',c) for c in ['neuralEngine','gpu','cpu']]
if a.whisper_model: configurations.append(('whisper','whisper-default'))
with tempfile.TemporaryDirectory(prefix='oswind-speech-eval-') as temporary:
    for engine,compute in configurations:
        for trial in range(a.trials):
            library=pathlib.Path(temporary)/(engine+'-'+compute+'-'+str(trial)); library.mkdir(mode=0o700)
            settings={'whisperBinary':str(pathlib.Path(a.whisper_binary).resolve())}
            (library/'settings.json').write_text(json.dumps(settings))
            arguments=[str(binary),'--data',str(library),'import-audio',str(audio),'--engine',engine]
            if engine=='parakeet': arguments+=['--native-model',str(model),'--compute',compute]
            else: arguments+=['--model',str(pathlib.Path(a.whisper_model).resolve())]
            started=time.perf_counter(); result=subprocess.run(['/usr/bin/time','-lp',*arguments],capture_output=True,text=True,timeout=300)
            elapsed=time.perf_counter()-started
            if result.returncode: raise RuntimeError((engine,compute,result.stderr))
            memory=json.loads(result.stdout); transcript=memory['transcript']; error=wer(memory['text'])
            assert transcript['duration']>0 and transcript['segments'] and memory.get('audioPath') is None
            retrieval=subprocess.run([str(binary),'--data',str(library),'search','--mode','keyword',next(w for w in words(a.reference) if len(w)>=4)],capture_output=True,text=True,timeout=30)
            assert retrieval.returncode==0 and any(hit['memory']['id']==memory['id'] for hit in json.loads(retrieval.stdout))
            rss=re.search(r'(\d+)\s+maximum resident set size',result.stderr)
            footprint=re.search(r'(\d+)\s+peak memory footprint',result.stderr)
            measurement={'engine':engine,'compute':compute,'trial':trial,'wall_seconds':elapsed,'peak_RSS_bytes':int(rss[1]) if rss else None,
                         'peak_footprint_bytes':int(footprint[1]) if footprint else None,'normalized_WER':error,'text':memory['text'],
                         'timed_segments':len(transcript['segments']),'saved_and_retrieved':True}
            report['measurements'].append(measurement)
            pathlib.Path(a.output).write_text(json.dumps(report,indent=2)+'\n')
            print(json.dumps(measurement),flush=True)
