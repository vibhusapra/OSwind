#!/usr/bin/env python3
"""Score raw anonymous speaker timelines with pinned pyannote.metrics.
Install benchmarks/requirements-speaker-eval.txt in a separate environment.
This measures a declared development subset, never a product leaderboard.
"""
import argparse,hashlib,importlib.metadata,json,math,os,pathlib,re,shutil,signal,subprocess,time,wave
from pyannote.core import Annotation,Segment,Timeline
from pyannote.metrics.diarization import DiarizationErrorRate

def sha(file):
    digest=hashlib.sha256()
    with file.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):digest.update(block)
    return digest.hexdigest()
def read_reference(path,identifier,duration):
    result=Annotation(uri=identifier)
    for index,line in enumerate(path.read_text().splitlines()):
        if not line.strip():continue
        fields=line.split()
        if len(fields)!=10 or fields[0]!='SPEAKER' or fields[1]!=identifier:raise ValueError('Invalid reference RTTM')
        start,length=float(fields[3]),float(fields[4]);end=start+length
        if not all(map(math.isfinite,[start,end])) or start<0 or length<=0 or end>duration+0.02:raise ValueError('Reference interval outside source audio')
        result[Segment(start,min(duration,end)),index]=fields[7]
    return result

def read_hypothesis(timeline,identifier,duration):
    if timeline['scope']!='recording' or not math.isfinite(timeline['duration']) or abs(timeline['duration']-duration)>0.001:raise ValueError('Hypothesis does not match source duration/scope')
    result=Annotation(uri=identifier)
    if len(timeline['turns'])>200000:raise ValueError('Oversized hypothesis')
    for index,turn in enumerate(timeline['turns']):
        start,end=turn['start'],turn['end'];speaker=turn['speaker']
        if not all(map(math.isfinite,[start,end])) or start<0 or end<=start or end>duration+0.001 or not isinstance(speaker,str) or not speaker:raise ValueError('Invalid hypothesis interval')
        result[Segment(start,min(duration,end)),index]=speaker
    return result

def score(reference,hypothesis,duration,collar=0,metric=None):
    metric=metric if metric is not None else DiarizationErrorRate(collar=collar,skip_overlap=False)
    detail=metric(reference,hypothesis,uem=Timeline([Segment(0,duration)]),detailed=True)
    return {key:float(value) for key,value in detail.items()}

def private_json(path,value):
    data=(json.dumps(value,indent=2,allow_nan=False)+'\n').encode();temporary=path.with_suffix(path.suffix+'.part')
    with temporary.open('wb') as stream:os.chmod(temporary,0o600);stream.write(data)
    temporary.replace(path)

def model_hash(directory):
    digest=hashlib.sha256();count=0
    for file in sorted(directory.rglob('*')):
        if file.is_symlink():raise ValueError('Model fingerprint does not follow symlinks')
        if file.is_file():digest.update(str(file.relative_to(directory)).encode()+b'\0'+bytes.fromhex(sha(file)));count+=1
    if not count:raise ValueError('Empty model directory')
    return digest.hexdigest()

def evaluate(binary,model,dataset,output,repetitions=2):
    manifest=json.loads((dataset/'manifest.json').read_text())
    if manifest['state']!='prepared':raise ValueError('Dataset preparation is not complete')
    if output.exists():raise ValueError('Evaluation directory must be new')
    output.mkdir(parents=True,mode=0o700);(output/'predictions').mkdir(mode=0o700);(output/'runner').mkdir(mode=0o700)
    original_sha=sha(binary);pinned=output/'runner/oswindctl';shutil.copy2(binary,pinned);os.chmod(pinned,0o500)
    if sha(pinned)!=original_sha or sha(binary)!=original_sha:raise ValueError('Executable changed during pinning')
    binary=pinned
    report={'format':'OSwind natural speaker development evaluation v1','state':'running','dataset':{key:manifest[key] for key in ['dataset','annotation_commit','selection','license','attribution','license_source']},'binary_sha256':original_sha,'pinned_runner':'runner/oswindctl','model_tree_sha256':model_hash(model),'repetitions':repetitions,'scorer':{name:importlib.metadata.version(name) for name in ['pyannote.metrics','pyannote.core','numpy','scipy']},'settings':{'collars_seconds':[0,0.25],'skip_overlap':False,'uem':'Entire source WAV duration, including unannotated silence','oracle_speaker_count':False},'clips':[],'scope':'Predetermined development clips, not held-out/corpus-wide or competitor app quality. Raw diarization before ASR projection. Each clip uses a fresh process; later repetitions reuse its backend. OS/Core ML compilation caches uncontrolled. macOS process RSS excludes device allocation, background daemons and system power.'}
    report['selection_coverage']={'kind':manifest.get('coverage','fixed-subset'),'planned_clips':len(manifest['clips']),'available_reference_clips':manifest.get('available_reference_clips')}
    if manifest.get('coverage')=='full-development-set':report['scope']=report['scope'].replace('Predetermined development clips, not held-out/corpus-wide or competitor app quality.','Complete pinned development selection, not held-out/test-set or competitor app quality. Includes previously evaluated development clips.')
    metrics={(run,collar):DiarizationErrorRate(collar=collar,skip_overlap=False) for run in range(repetitions) for collar in [0,0.25]}
    private_json(output/'report.json',report)
    try:
        for clip in manifest['clips']:
            identifier=clip['id']
            if not re.fullmatch('[a-z]{5}',identifier):raise ValueError('Unsafe clip ID')
            audio=dataset/'audio'/(identifier+'.wav');reference_path=dataset/'reference'/(identifier+'.rttm')
            if sha(audio)!=clip['audio_sha256'] or sha(reference_path)!=clip['reference_sha256']:raise ValueError('Dataset source hash drift')
            with wave.open(str(audio),'rb') as wav:duration=wav.getnframes()/wav.getframerate()
            if not math.isfinite(duration) or duration<=0:raise ValueError('Invalid source duration')
            reference=read_reference(reference_path,identifier,duration)
            prediction=output/'predictions'/(identifier+'.json');stderr=output/(identifier+'.stderr.log')
            command=['/usr/bin/time','-l',str(binary),'--data',str(output/'forbidden-library'),'diarize',str(audio),'--speaker-model',str(model),'--repetitions',str(repetitions),'--output',str(prediction)]
            started=time.monotonic()
            with (output/(identifier+'.stdout.json')).open('w') as stdout,stderr.open('w') as errors:
                process=subprocess.Popen(command,stdout=stdout,stderr=errors,start_new_session=True)
                try:code=process.wait(timeout=2400)
                except BaseException:
                    os.killpg(process.pid,signal.SIGTERM)
                    try:process.wait(timeout=5)
                    except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait()
                    raise
            if code!=0:raise RuntimeError(f'{identifier} inference exited {code}; see retained logs')
            data=json.loads(prediction.read_text())
            if data['format']!='OSwind raw speaker timeline v1' or len(data['runs'])!=repetitions:raise ValueError('Incomplete timeline response')
            measured=re.search(r'^\s*(\d+)\s+maximum resident set size',stderr.read_text(),re.M)
            if not measured:raise ValueError('macOS peak RSS measurement unavailable')
            entry={'id':identifier,'source_audio_seconds':duration,'audio_sha256':clip['audio_sha256'],'reference_sha256':clip['reference_sha256'],'reference_speakers':len(reference.labels()),'process_wall_seconds':time.monotonic()-started,'process_peak_rss_bytes':int(measured.group(1)),'preparation_seconds':data['preparation_seconds'],'policy':data.get('policy','legacy-exclusive-default'),'runs':[]}
            for index,run in enumerate(data['runs']):
                if run['index']!=index or run['resident_backend_reused']!=(index>0) or not math.isfinite(run['seconds']) or run['seconds']<=0:raise ValueError('Invalid inference timing/residency')
                hypothesis=read_hypothesis(run['timeline'],identifier,duration)
                entry['runs'].append({'index':index,'seconds':run['seconds'],'real_time_factor':run['seconds']/duration,'resident_backend_reused':index>0,'model':run['timeline']['model'],'detected_speakers':len(hypothesis.labels()),'scores':{str(collar):score(reference,hypothesis,duration,collar,metrics[index,collar]) for collar in [0,0.25]}})
            if sha(audio)!=clip['audio_sha256'] or sha(reference_path)!=clip['reference_sha256'] or (output/'forbidden-library').exists():raise ValueError('Input mutation or unexpected library write')
            report['clips'].append(entry);private_json(output/'report.json',report);print('Scored',identifier,entry['runs'][0]['scores'],flush=True)
        if sha(binary)!=report['binary_sha256']:raise ValueError('Pinned executable changed during evaluation')
        if model_hash(model)!=report['model_tree_sha256']:raise ValueError('Model files changed during inference')
        for clip in manifest['clips']:
            if sha(dataset/'audio'/(clip['id']+'.wav'))!=clip['audio_sha256'] or sha(dataset/'reference'/(clip['id']+'.rttm'))!=clip['reference_sha256']:raise ValueError('Dataset source drift after corpus inference')
        report['source_stability_verified']=True
        report['aggregate']=[{'run':run,'collar_seconds':collar,'micro_der':float(abs(metric)),'components':{k:float(v) for k,v in metric[:].items()},'combined_real_time_factor':sum(c['runs'][run]['seconds'] for c in report['clips'])/sum(c['source_audio_seconds'] for c in report['clips'])} for (run,collar),metric in metrics.items()]
        report['state']='completed';private_json(output/'report.json',report);return report
    except BaseException as error:
        report.update(state='failed',failure=str(error));private_json(output/'report.json',report);raise

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--binary',type=pathlib.Path,required=True);parser.add_argument('--model',type=pathlib.Path,required=True);parser.add_argument('--dataset',type=pathlib.Path,required=True);parser.add_argument('--output',type=pathlib.Path,required=True);parser.add_argument('--repetitions',type=int,default=2)
    a=parser.parse_args()
    if not 1<=a.repetitions<=10:parser.error('repetitions must be 1–10')
    evaluate(a.binary.resolve(),a.model.resolve(),a.dataset.resolve(),a.output.resolve(),a.repetitions)
