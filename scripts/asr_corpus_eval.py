#!/usr/bin/env python3
"""Evaluate frozen LibriSpeech selections through complete local OSwind audio imports.
Requires jiwer from benchmarks/requirements-speech-eval.txt. No model downloads,
reference prompts, retained raw audio, or normal-library access. Not an app ranking.
"""
import argparse,hashlib,importlib.metadata,json,math,os,pathlib,platform,re,shutil,signal,sqlite3,subprocess,tempfile,time,wave
import jiwer

PROFILES={'parakeet-neuralEngine':('parakeet','neuralEngine'),'parakeet-gpu':('parakeet','gpu'),'whisper-default':('whisper','whisper-default')}
def require(condition,message):
    if not condition:raise ValueError(message)
def sha(file):
    h=hashlib.sha256()
    with file.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):h.update(block)
    return h.hexdigest()
def tree_hash(root):
    h=hashlib.sha256();count=0
    for file in sorted(root.rglob('*')):
        require(not file.is_symlink(),'Model fingerprint refuses symlinks')
        if file.is_file():h.update(str(file.relative_to(root)).encode()+b'\0'+bytes.fromhex(sha(file)));count+=1
    require(count>0,'Empty native model');return h.hexdigest()
def private_json(file,value):
    temporary=file.with_suffix(file.suffix+'.part');temporary.write_text(json.dumps(value,indent=2,allow_nan=False)+'\n');temporary.chmod(0o600);temporary.replace(file)
def normalized(text):return ' '.join(re.findall(r"[a-z0-9]+(?:'[a-z0-9]+)*",text.casefold().replace('’',"'")))
def word_counts(reference,hypothesis):
    reference,hypothesis=normalized(reference),normalized(hypothesis);value=jiwer.process_words(reference,hypothesis)
    return {'reference_words':value.hits+value.substitutions+value.deletions,'hypothesis_words':value.hits+value.substitutions+value.insertions,'hits':value.hits,'substitutions':value.substitutions,'deletions':value.deletions,'insertions':value.insertions,'wer':value.wer}
def micro(rows):
    result={key:sum(row[key] for row in rows) for key in ['reference_words','hypothesis_words','hits','substitutions','deletions','insertions']};require(result['reference_words']>0,'Aggregate needs reference words');result['micro_wer']=(result['substitutions']+result['deletions']+result['insertions'])/result['reference_words'];return result

def selection(dataset):
    manifest_path=dataset/'manifest.json';manifest=json.loads(manifest_path.read_text());require(manifest['state']=='prepared','ASR assets are not prepared');clips=[];pinned={str(manifest_path):sha(manifest_path)}
    for item in manifest['splits']:
        split=item['split'];require(split in ['test-clean','test-other'],'Unknown ASR split')
        prepared=dataset/split/'prepared.json';plan_path=dataset/split/'selection-plan.json';info=json.loads(prepared.read_text());plan=json.loads(plan_path.read_text());pinned.update({str(x):sha(x) for x in [prepared,plan_path]})
        require(info['split']==plan['split']==split,'Split labels differ from frozen paths')
        ids=[c['id'] for c in info['clips']];require(len(ids)==len(set(ids))==info['selected_utterances']==item['selected_utterances'],'Duplicate or incomplete ASR selection');require(set(ids)=={c['id'] for c in plan['clips']},'Prepared selection differs from frozen IDs');require({c['id']:c['reference_sha256'] for c in info['clips']}=={c['id']:c['reference_sha256'] for c in plan['clips']},'Prepared references differ from frozen plan')
        require(len({i.split('-')[0] for i in ids})==info['speakers']==item['speakers'],'Speaker coverage differs from the plan')
        for clip in info['clips']:
            identifier=clip['id'];require(re.fullmatch(r'[0-9]+-[0-9]+-[0-9]+',identifier),'Unsafe ASR identifier');clips.append(dict(clip,split=split))
    require(clips and len({(c['split'],c['id']) for c in clips})==len(clips),'Empty or duplicate split selection');return manifest,clips,pinned

def verify_sources(dataset,clips,pinned):
    for path,digest in pinned.items():require(sha(pathlib.Path(path))==digest,'Dataset manifest or frozen plan drift')
    for clip in clips:
        for kind,suffix,key in [('audio','.wav','wav_sha256'),('audio','.flac','flac_sha256'),('reference','.txt','reference_sha256')]:require(sha(dataset/clip['split']/kind/(clip['id']+suffix))==clip[key],'Dataset source drift')

def evaluate(binary,dataset,native_model,whisper_binary,whisper_model,output,trials=2,profiles=None):
    profiles=list(profiles or PROFILES);require(1<=trials<=10 and profiles and len(set(profiles))==len(profiles) and set(profiles)<=set(PROFILES),'Invalid trials/profiles')
    manifest,clips,pinned=selection(dataset);verify_sources(dataset,clips,pinned);require(not output.exists(),'Evaluation directory must be new')
    output.mkdir(parents=True,mode=0o700);(output/'runner').mkdir(mode=0o700);(output/'predictions').mkdir(mode=0o700)
    binary_digest=sha(binary);runner=output/'runner/oswindctl';shutil.copy2(binary,runner);runner.chmod(0o500);require(sha(runner)==binary_digest==sha(binary),'Executable changed during pinning')
    models={}
    if any(PROFILES[p][0]=='parakeet' for p in profiles):models['parakeet_model_tree_sha256']=tree_hash(native_model)
    if 'whisper-default' in profiles:models.update(whisper_model_sha256=sha(whisper_model),whisper_executable_sha256=sha(whisper_binary))
    report={'format':'OSwind frozen natural ASR import evaluation v2','state':'running','binary_sha256':binary_digest,'pinned_runner':'runner/oswindctl','harness_sha256':sha(pathlib.Path(__file__)),'dataset':{k:manifest.get(k) for k in ['source','license','selection','created_utc','splits']},'selection_manifest_sha256':pinned[str(dataset/'manifest.json')],'models':models,'scorer':{name:importlib.metadata.version(name) for name in ['jiwer','rapidfuzz']},'platform':{'machine':platform.machine(),'macos':platform.mac_ver()[0]},'profiles':profiles,'trials':trials,'normalization':"Casefold, curly apostrophe to ASCII, ASCII alphanumeric words with internal apostrophes; punctuation discarded, no number expansion, spelling correction or NIST equivalence claim",'import_failure_policy':'Nonzero exit or per-import timeout is retained as a failed attempt. End-to-end WER scores missing delivered text as all reference-word deletions; successful-import WER is also reported separately. No failed clips are excluded or retried within a run.', 'reference_access':'Reference bytes hashed before inference; reference text read for scoring only after the import subprocess completed; no transcript/reference prompts supplied','measurements':[],'scope_limits':['Frozen selected English audiobook utterances, not full LibriSpeech or meeting/noise/streaming recognition','Held out from OSwind tuning until this frozen run; upstream model-training overlap is unaudited','Complete CLI import per fresh process/library, including normalization, model load, admission and Apple embedding; not resident throughput','Core ML compute policy is requested, not proof every operation ran on that processor; whisper uses its default backend','Caches/background activity uncontrolled; process RSS excludes device allocations and child processes; no power/battery or competitor app ranking','No corpus audio, reference text or predictions are redistributed']}
    private_json(output/'report.json',report)
    try:
        for clip in clips:
            audio=dataset/clip['split']/'audio'/(clip['id']+'.wav');reference=dataset/clip['split']/'reference'/(clip['id']+'.txt')
            require(sha(audio)==clip['wav_sha256'] and sha(reference)==clip['reference_sha256'],'Clip hash drift')
            with wave.open(str(audio),'rb') as wav:duration=wav.getnframes()/wav.getframerate()
            require(math.isfinite(duration) and duration>0 and abs(duration-clip['duration_seconds'])<.001,'Prepared audio duration changed')
            for profile in profiles:
                engine,compute=PROFILES[profile]
                for trial in range(trials):
                    key=clip['split']+'-'+clip['id']+'-'+profile+'-'+str(trial);stdout_path=output/'predictions'/(key+'.json');stderr_path=output/'predictions'/(key+'.stderr.log')
                    with tempfile.TemporaryDirectory(prefix='oswind-owned-asr-eval-') as temporary:
                        library=pathlib.Path(temporary);settings={'whisperBinary':str(whisper_binary),'retainAudio':False,'automaticMaintenance':False,'captureOnLaunch':False,'apiEnabled':False,'routinesEnabled':False,'search':{'provider':'apple'}};private_json(library/'settings.json',settings)
                        command=['/usr/bin/time','-l',str(runner),'--data',str(library),'import-audio',str(audio),'--engine',engine]
                        command+=['--native-model',str(native_model),'--compute',compute] if engine=='parakeet' else ['--model',str(whisper_model)]
                        started=time.monotonic()
                        with stdout_path.open('w') as stdout,stderr_path.open('w') as stderr:
                            stdout_path.chmod(0o600);stderr_path.chmod(0o600);process=subprocess.Popen(command,stdout=stdout,stderr=stderr,start_new_session=True)
                            timed_out=False
                            try:code=process.wait(timeout=600)
                            except subprocess.TimeoutExpired:
                                timed_out=True;os.killpg(process.pid,signal.SIGTERM)
                                try:code=process.wait(timeout=5)
                                except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);code=process.wait()
                            except BaseException:
                                os.killpg(process.pid,signal.SIGTERM)
                                try:process.wait(timeout=5)
                                except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait()
                                raise
                        elapsed=time.monotonic()-started;success=code==0 and not timed_out
                        database=library/'memory.sqlite';saved_count=0;memory=None
                        if success:
                            memory=json.loads(stdout_path.read_text());require(memory['text']==memory['transcript']['text'] and memory.get('audioPath') is None,'Invalid text or unexpected retained audio');require(abs(memory['transcript']['duration']-duration)<.001,'Import source duration mismatch')
                            require(database.is_file(),'Import did not create its isolated library')
                        if database.is_file():
                            conn=sqlite3.connect('file:'+str(database)+'?mode=ro',uri=True)
                            try:
                                rows=conn.execute('SELECT id,payload FROM memories').fetchall();saved_count=len(rows)
                                if success:require(len(rows)==1 and rows[0][0]==memory['id'] and json.loads(rows[0][1])['text']==memory['text'],'Actual saved record differs from the response')
                            finally:conn.close()
                    counts=word_counts(reference.read_text(),memory['text'] if success else '');require(counts['reference_words']>0,'Empty normalized reference');rss=re.search(r'^\s*(\d+)\s+maximum resident set size',stderr_path.read_text(),re.M)
                    require(rss is not None or timed_out,'macOS peak RSS missing')
                    report['measurements'].append({'id':clip['id'],'split':clip['split'],'profile':profile,'trial':trial,'source_audio_seconds':duration,'wav_sha256':clip['wav_sha256'],'reference_sha256':clip['reference_sha256'],'prediction_sha256':sha(stdout_path),'stderr_sha256':sha(stderr_path),'model':memory['transcript']['model'] if success else None,'scores':counts,'import_succeeded':success,'exit_code':code,'timed_out':timed_out,'saved_record_count':saved_count,'process_wall_seconds':elapsed,'real_time_factor':elapsed/duration,'process_peak_rss_bytes':int(rss[1]) if rss else None,'saved_record_verified':success})
                    require(sha(audio)==clip['wav_sha256'] and sha(reference)==clip['reference_sha256'],'Input changed during import');private_json(output/'report.json',report)
            print('Scored',clip['split'],clip['id'],flush=True)
        verify_sources(dataset,clips,pinned);require(sha(runner)==binary_digest and sha(pathlib.Path(__file__))==report['harness_sha256'],'Pinned runner or harness drift')
        if 'parakeet_model_tree_sha256' in models:require(tree_hash(native_model)==models['parakeet_model_tree_sha256'],'Native model drift')
        if 'whisper-default' in profiles:require(sha(whisper_model)==models['whisper_model_sha256'] and sha(whisper_binary)==models['whisper_executable_sha256'],'Whisper model/executable drift')
        expected=len(clips)*len(profiles)*trials;require(len(report['measurements'])==expected,'Incomplete ASR measurement coverage');report['aggregate']=[]
        for split in [x['split'] for x in manifest['splits']]:
            for profile in profiles:
                for trial in range(trials):
                    rows=[x for x in report['measurements'] if (x['split'],x['profile'],x['trial'])==(split,profile,trial)];report['aggregate'].append({'split':split,'profile':profile,'trial':trial,'utterances':len(rows),'successful_imports':sum(r['import_succeeded'] for r in rows),'failed_imports':sum(not r['import_succeeded'] for r in rows),'successful_import_scores':micro([r['scores'] for r in rows if r['import_succeeded']]) if any(r['import_succeeded'] for r in rows) else None,**micro([r['scores'] for r in rows]),'combined_import_real_time_factor':sum(r['process_wall_seconds'] for r in rows)/sum(r['source_audio_seconds'] for r in rows),'peak_process_rss_bytes':max((r['process_peak_rss_bytes'] for r in rows if r['process_peak_rss_bytes'] is not None),default=None)})
        report.update(state='completed',source_stability_verified=True,all_imports_succeeded=all(r['import_succeeded'] for r in report['measurements']),failed_imports=sum(not r['import_succeeded'] for r in report['measurements']));private_json(output/'report.json',report);return report
    except BaseException as error:report.update(state='failed',failure=str(error));private_json(output/'report.json',report);raise

if __name__=='__main__':
    def terminated(signum,frame):raise KeyboardInterrupt('Evaluation terminated')
    signal.signal(signal.SIGTERM,terminated)
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',type=pathlib.Path,required=True);p.add_argument('--dataset',type=pathlib.Path,required=True);p.add_argument('--native-model',type=pathlib.Path,required=True);p.add_argument('--whisper-binary',type=pathlib.Path,required=True);p.add_argument('--whisper-model',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--trials',type=int,default=2);p.add_argument('--profiles',nargs='+',choices=list(PROFILES),default=list(PROFILES));a=p.parse_args()
    evaluate(a.binary.resolve(),a.dataset.resolve(),a.native_model.resolve(),a.whisper_binary.resolve(),a.whisper_model.resolve(),a.output.resolve(),a.trials,a.profiles)
