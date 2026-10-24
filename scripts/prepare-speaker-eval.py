#!/usr/bin/env python3
"""Prepare a predetermined VoxConverse development or test selection, with exact HTTP ranges and CRCs.
No media is redistributed. Official dataset attribution and source hashes are
written beside private local assets. Requires a pinned annotation ZIP and plan.
"""
import argparse,hashlib,io,json,os,pathlib,re,time,urllib.request,zipfile

AUDIO_URL='https://www.robots.ox.ac.uk/~vgg/data/voxconverse/data/voxconverse_dev_wav.zip'
AUDIO_URLS={'dev':AUDIO_URL,'test':'https://www.robots.ox.ac.uk/~vgg/data/voxconverse/data/voxconverse_test_wav.zip'}
MAX_MEMBER=128*1024**2
class RangeFile(io.RawIOBase):
    def __init__(self,url,timeout=60):
        super().__init__();self.url=url;self.timeout=timeout;self.position=0;self.bytes_read=0;self.requests=0
        with urllib.request.urlopen(urllib.request.Request(url,method='HEAD'),timeout=timeout) as response:
            self.length=int(response.headers['Content-Length']);self.etag=response.headers.get('ETag','');self.final_url=response.geturl()
        if not 0<self.length<=10*1024**3 or not self.etag or self.etag.startswith('W/') or '\r' in self.etag or '\n' in self.etag:raise ValueError('A bounded archive with a strong ETag is required')
    def readable(self):return True
    def seekable(self):return True
    def tell(self):return self.position
    def seek(self,offset,whence=0):
        target=offset if whence==0 else self.position+offset if whence==1 else self.length+offset if whence==2 else -1
        if not 0<=target<=self.length:raise ValueError('ZIP seek outside archive')
        self.position=target;return target
    def read(self,size=-1):
        if self.closed:raise ValueError('Closed archive')
        size=min(self.length-self.position,size if size>=0 else self.length-self.position)
        if size==0:return b''
        if size>MAX_MEMBER:raise ValueError('Oversized ZIP range request')
        start=self.position;end=start+size-1
        request=urllib.request.Request(self.url,headers={'Range':f'bytes={start}-{end}','If-Range':self.etag,'Accept-Encoding':'identity'})
        with urllib.request.urlopen(request,timeout=self.timeout) as response:
            if response.status!=206 or response.headers.get('Content-Range')!=f'bytes {start}-{end}/{self.length}' or response.headers.get('ETag')!=self.etag or response.geturl()!=self.final_url:
                raise ValueError('Archive entity or requested range changed')
            payload=response.read(size+1)
        if len(payload)!=size:raise ValueError('Truncated or oversized ZIP range')
        self.position+=size;self.bytes_read+=size;self.requests+=1;return payload

def digest(data):return hashlib.sha256(data).hexdigest()
def file_digest(path):
    result=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):result.update(block)
    return result.hexdigest()
def save(root,manifest):
    temporary=root/'manifest.json.part';temporary.write_text(json.dumps(manifest,indent=2)+'\n');os.chmod(temporary,0o600);temporary.replace(root/'manifest.json')
def prepare(annotations,plan,output,audio_archive=None,split='dev',coverage=None):
    if output.exists():raise ValueError('Output directory must be new')
    if not re.fullmatch('[a-f0-9]{40}',plan['annotation_commit']):raise ValueError('Pin an immutable annotation commit')
    ids=[clip['id'] for clip in plan['clips']]
    if not 1<=len(ids)<=512 or len(set(ids))!=len(ids) or not all(re.fullmatch('[a-z]{5}',value) for value in ids):raise ValueError('Invalid fixed clip identifiers')
    if split not in AUDIO_URLS or plan.get('split',split)!=split:raise ValueError('Unknown or inconsistent dataset split')
    coverage=coverage or plan.get('coverage','fixed-subset')
    if coverage not in ['fixed-subset','full-development-set','full-test-set'] or coverage=='full-development-set' and split!='dev' or coverage=='full-test-set' and split!='test':raise ValueError('Coverage does not match the dataset split')
    audio_url=AUDIO_URLS[split]
    output.mkdir(mode=0o700,parents=True);(output/'audio').mkdir(mode=0o700);(output/'reference').mkdir(mode=0o700)
    manifest={'format':'OSwind natural speaker subset v1','state':'preparing','dataset':'VoxConverse '+split,'split':split,'selection_plan_canonical_sha256':digest(json.dumps(plan,sort_keys=True,separators=(',',':')).encode()),'annotation_commit':plan['annotation_commit'],'selection':plan['selection'],'license':'CC BY 4.0; research use; original video copyright retained','attribution':'Chung, Huh, Nagrani, Afouras and Zisserman. Spot the conversation: speaker diarisation in the wild. Interspeech 2020.','license_source':'https://github.com/joonson/voxconverse/blob/'+plan['annotation_commit']+'/README.md','source_audio_url':audio_url,'annotation_zip_sha256':file_digest(annotations),'clips':[],'scope':'Predetermined '+split+' selection; no inference or quality score. Test is held out from OSwind tuning only; upstream training overlap is unaudited. Source audio stays private.'}
    source=None
    try:
        source=open(audio_archive,'rb') if audio_archive else RangeFile(audio_url)
        if not audio_archive:manifest.update(audio_archive_bytes=source.length,audio_archive_etag=source.etag,retrieval='Official URL with exact HTTP ranges and pinned entity')
        else:manifest.update(audio_archive_bytes=audio_archive.stat().st_size,audio_archive_sha256=file_digest(audio_archive),retrieval='Caller-provided ZIP; no publisher fingerprint claim')
        with zipfile.ZipFile(annotations) as reference,zipfile.ZipFile(source) as audio:
            prefix='joonson-voxconverse-'+plan['annotation_commit'][:7]+'/'+split+'/'
            available={pathlib.PurePosixPath(name).stem for name in reference.namelist() if re.fullmatch(re.escape(prefix)+r'[a-z]{5}\.rttm',name)}
            if coverage in ['full-development-set','full-test-set'] and set(ids)!=available:raise ValueError('Full split selection does not equal the pinned reference set')
            if not set(ids)<=available:raise ValueError('Selected IDs are outside the pinned reference split')
            manifest.update(coverage=coverage,available_reference_clips=len(available),planned_clips=len(ids))
            entries=audio.infolist()
            for clip in plan['clips']:
                identifier=clip['id'];matches=[info for info in entries if pathlib.PurePosixPath(info.filename).name==identifier+'.wav']
                if len(matches)!=1:raise ValueError('Missing/ambiguous audio member: '+identifier)
                info=matches[0]
                if info.file_size>MAX_MEMBER or info.compress_size>MAX_MEMBER or info.flag_bits&1:raise ValueError('Unsupported/oversized audio member')
                if clip['annotation_member']!=prefix+identifier+'.rttm':raise ValueError('Annotation member does not match pinned revision')
                if reference.getinfo(clip['annotation_member']).file_size>1024*1024:raise ValueError('Oversized reference annotation')
                labels=reference.read(clip['annotation_member'])
                if digest(labels)!=clip['annotation_sha256']:raise ValueError('Reference annotation hash changed')
                started=time.monotonic();data=audio.read(info) # ZipExtFile verifies the official CRC.
                if len(data)!=info.file_size:raise ValueError('Decoded WAV size differs from ZIP directory')
                target=output/'audio'/(identifier+'.wav');target.write_bytes(data);os.chmod(target,0o600)
                ref=output/'reference'/(identifier+'.rttm');ref.write_bytes(labels);os.chmod(ref,0o600)
                manifest['clips'].append({'id':identifier,'audio':'audio/'+identifier+'.wav','reference':'reference/'+identifier+'.rttm','audio_bytes':len(data),'audio_sha256':digest(data),'reference_sha256':digest(labels),'archive_member':info.filename,'archive_crc32':f'{info.CRC:08x}','fetch_seconds':time.monotonic()-started})
                save(output,manifest);print('Prepared',identifier,len(data),'bytes',flush=True)
        manifest['state']='prepared'
        if not audio_archive:manifest.update(http_range_bytes=source.bytes_read,http_range_requests=source.requests)
        save(output,manifest);return manifest
    except BaseException as error:
        manifest.update(state='failed',failure=str(error));save(output,manifest);raise
    finally:
        if source is not None:source.close()
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--annotations',type=pathlib.Path,required=True);p.add_argument('--plan',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--audio-archive',type=pathlib.Path);p.add_argument('--split',choices=['dev','test'],default='dev');p.add_argument('--coverage',choices=['fixed-subset','full-development-set','full-test-set'])
    a=p.parse_args();prepare(a.annotations,json.loads(a.plan.read_text()),a.output,a.audio_archive,a.split,a.coverage)
