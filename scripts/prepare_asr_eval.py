#!/usr/bin/env python3
"""Prepare a fixed, speaker-balanced LibriSpeech test selection before inference.
Reads local official archives; validates publisher MD5 plus recorded SHA-256.
Never extracts TAR paths directly. Audio and human reference text stay private.
"""
import argparse,datetime,hashlib,json,os,pathlib,re,subprocess,tarfile,wave
OFFICIAL_MD5={'test-clean':'32fa31d27d2e1cad72775fee3f4849a9','test-other':'fb5a50374b501bb3bac4815ee91d3135'}
MAX_REFERENCE=1024**2;MAX_AUDIO=8*1024**2

def fingerprint(file):
    md5,sha=hashlib.md5(),hashlib.sha256()
    with file.open('rb') as stream:
        for block in iter(lambda:stream.read(4*1024**2),b''):md5.update(block);sha.update(block)
    return {'publisher_md5':md5.hexdigest(),'archive_sha256':sha.hexdigest()}
def digest(file):return hashlib.sha256(file.read_bytes()).hexdigest()
def write(file,data):file.write_bytes(data);file.chmod(0o600)
def save(root,manifest):
    temporary=root/'manifest.part';write(temporary,(json.dumps(manifest,indent=2)+'\n').encode());temporary.replace(root/'manifest.json')
def convert(source,target):subprocess.run(['ffmpeg','-nostdin','-v','error','-i',str(source),'-map_metadata','-1','-ac','1','-ar','16000','-c:a','pcm_s16le','-n',str(target)],check=True,capture_output=True,timeout=120)
def contents(archive,member,limit):
    if not member.isfile() or not 0<member.size<=limit:raise ValueError('Unsupported or oversized selected TAR member')
    stream=archive.extractfile(member)
    if stream is None:raise ValueError('Selected TAR member is unreadable')
    data=stream.read(limit+1)
    if len(data)!=member.size:raise ValueError('Truncated or oversized selected TAR member')
    return data

def prepare(archives,output,expected_md5=None,converter=convert,conversion_version=None):
    if output.exists():raise ValueError('Output directory must be new')
    if not archives or not set(archives)<=set(OFFICIAL_MD5):raise ValueError('Use test-clean and/or test-other archives')
    expected_md5=OFFICIAL_MD5 if expected_md5 is None else expected_md5;pins={}
    for split,path in archives.items():
        pins[split]=fingerprint(path)
        if pins[split]['publisher_md5']!=expected_md5[split]:raise ValueError('Archive differs from the expected publisher fingerprint')
    if conversion_version is None:conversion_version=subprocess.check_output(['ffmpeg','-version'],text=True).splitlines()[0]
    output.mkdir(parents=True,mode=0o700)
    manifest={'state':'preparing','created_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source':'https://www.openslr.org/12/','license':'CC BY 4.0 per official resource page','selection':'First five lexicographic utterance IDs for EVERY available speaker in each test split, fixed before ASR inference; no result exclusions','scope':'Asset/reference preparation only, no model score. Read English audiobook speech, not meeting/noise acceptance. No audio or human reference text redistributed.','ffmpeg':conversion_version,'splits':[]};save(output,manifest)
    try:
        for split in ['test-clean','test-other']:
            if split not in archives:continue
            archive=archives[split];folder=output/split;folder.mkdir(mode=0o700);(folder/'audio').mkdir(mode=0o700);(folder/'reference').mkdir(mode=0o700);references={}
            with tarfile.open(archive,'r|gz') as tar:
                for member in tar:
                    match=re.fullmatch(r'LibriSpeech/'+split+r'/([0-9]+)/([0-9]+)/([0-9]+-[0-9]+)\.trans\.txt',member.name)
                    if not match:continue
                    speaker,chapter,prefix=match.groups()
                    if prefix!=speaker+'-'+chapter:raise ValueError('Reference path identity mismatch')
                    for line in contents(tar,member,MAX_REFERENCE).decode('utf-8').splitlines():
                        identifier,separator,text=line.partition(' ')
                        if not separator or not text.strip() or not re.fullmatch(re.escape(prefix)+r'-[0-9]+',identifier) or identifier in references:raise ValueError('Invalid or duplicate reference identifier')
                        references[identifier]=text
            speakers=sorted({identifier.split('-')[0] for identifier in references});selected=sorted(identifier for speaker in speakers for identifier in sorted(i for i in references if i.split('-')[0]==speaker)[:5])
            if not speakers or len(selected)!=len(speakers)*5:raise ValueError('Every selected speaker needs at least five available utterances')
            plan={'split':split,'speakers':len(speakers),'available_utterances':len(references),'selected_utterances':len(selected),**pins[split],'clips':[{'id':identifier,'reference_sha256':hashlib.sha256((references[identifier]+'\n').encode()).hexdigest()} for identifier in selected]}
            write(folder/'selection-plan.json',(json.dumps(plan,indent=2)+'\n').encode());found=set();clips=[]
            with tarfile.open(archive,'r|gz') as tar:
                for member in tar:
                    match=re.fullmatch(r'LibriSpeech/'+split+r'/([0-9]+)/([0-9]+)/([0-9]+-[0-9]+-[0-9]+)\.flac',member.name)
                    if not match or match.group(3) not in selected:continue
                    speaker,chapter,identifier=match.groups()
                    if not identifier.startswith(speaker+'-'+chapter+'-') or identifier in found:raise ValueError('Duplicate or mismatched selected audio member')
                    found.add(identifier);flac=folder/'audio'/(identifier+'.flac');wav=flac.with_suffix('.wav');ref=folder/'reference'/(identifier+'.txt');write(flac,contents(tar,member,MAX_AUDIO));write(ref,(references[identifier]+'\n').encode());converter(flac,wav);wav.chmod(0o600)
                    with wave.open(str(wav),'rb') as w:
                        if (w.getnchannels(),w.getframerate(),w.getsampwidth())!=(1,16000,2) or w.getnframes()<=0:raise ValueError('Converted audio must be nonempty mono 16 kHz PCM16')
                        seconds=w.getnframes()/w.getframerate()
                    clips.append({'id':identifier,'flac_sha256':digest(flac),'wav_sha256':digest(wav),'reference_sha256':digest(ref),'duration_seconds':seconds})
            if found!=set(selected):raise ValueError('Selected audio coverage is incomplete')
            info={**plan,'clips':sorted(clips,key=lambda c:c['id']),'selected_audio_seconds':sum(c['duration_seconds'] for c in clips)};write(folder/'prepared.json',(json.dumps(info,indent=2)+'\n').encode());manifest['splits'].append({k:info[k] for k in ['split','speakers','available_utterances','selected_utterances','selected_audio_seconds','archive_sha256','publisher_md5']});save(output,manifest);print('Prepared',split,len(clips),'clips',info['selected_audio_seconds'],'seconds',flush=True)
        for split,path in archives.items():
            if fingerprint(path)!=pins[split]:raise ValueError('Archive changed during preparation')
        manifest.update(state='prepared',completed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat());save(output,manifest);return manifest
    except BaseException as error:manifest.update(state='failed',failure=str(error));save(output,manifest);raise

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--test-clean',type=pathlib.Path,required=True);p.add_argument('--test-other',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args();prepare({'test-clean':a.test_clean,'test-other':a.test_other},a.output)
