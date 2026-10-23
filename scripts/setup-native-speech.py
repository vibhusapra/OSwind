#!/usr/bin/env python3
"""Install pinned Parakeet v3 or Community-1 Core ML weights into a NEW directory on macOS.

No SDK auto-recovery/cache deletion. Existing installations are verified, never
replaced. Model downloads include no recordings, transcripts or credentials.
"""
import argparse, ctypes, hashlib, json, os, pathlib, shutil, sys, tempfile, urllib.request

ROOT=pathlib.Path(__file__).resolve().parents[1]

def verify(directory,catalog):
    for item in catalog['files']:
        file=directory/item['path']
        if any(p.is_symlink() for p in [file,*list(file.parents)[:len(pathlib.PurePosixPath(item['path']).parts)-1]]): raise ValueError('Model file links are not accepted')
        h=hashlib.sha256(); count=0
        with file.open('rb') as stream:
            while block:=stream.read(1024*1024): count+=len(block); h.update(block)
        if count!=item['bytes'] or h.hexdigest()!=item['sha256']: raise ValueError('Model integrity mismatch: '+item['path'])

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model',choices=['parakeet','speakers'],default='parakeet',help='Speech recognizer or recording-local speaker models')
    parser.add_argument('--destination',help='New directory; defaults to the versioned OSwind model cache')
    parser.add_argument('--verify-only',action='store_true',help='Verify a complete install without any network access')
    args=parser.parse_args()
    catalog=json.loads((ROOT/'models'/({'parakeet':'parakeet-v3-coreml.json','speakers':'speaker-community1-coreml.json'}[args.model])).read_text())
    destination=pathlib.Path(args.destination).expanduser() if args.destination else pathlib.Path.home()/'Library/Caches/OSwind/models'/(('parakeet-v3-' if args.model=='parakeet' else 'speaker-community1-')+catalog['revision'][:12])
    if not destination.is_absolute() or destination.is_symlink(): raise ValueError('Choose an absolute, non-symlink model directory')
    if destination.exists():
        verify(destination,catalog); print('Verified pinned local model: '+str(destination)); return
    if args.verify_only: raise ValueError('Model is not installed; verify-only never downloads')
    if sys.platform!='darwin': raise ValueError('This installer currently targets macOS Core ML')
    destination.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    staging=pathlib.Path(tempfile.mkdtemp(prefix='.oswind-model-download-',dir=destination.parent))
    try:
        print(f"Downloading {sum(i['bytes'] for i in catalog['files']):,} bytes from {catalog['repository']} @ {catalog['revision']}",flush=True)
        for index,item in enumerate(catalog['files'],1):
            relative=pathlib.PurePosixPath(item['path'])
            if relative.is_absolute() or any(p in ['.','..'] for p in relative.parts): raise ValueError('Invalid catalog path')
            output=staging.joinpath(*relative.parts); output.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
            url=f"https://huggingface.co/{catalog['repository']}/resolve/{catalog['revision']}/{item['path']}?download=true"
            request=urllib.request.Request(url,headers={'User-Agent':'OSwind-model-setup/0.1'})
            digest=hashlib.sha256(); count=0
            fd=os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
            with os.fdopen(fd,'wb') as stream,urllib.request.urlopen(request,timeout=60) as response:
                while block:=response.read(1024*1024):
                    count+=len(block)
                    if count>item['bytes']: raise ValueError('Oversized model download: '+item['path'])
                    digest.update(block);stream.write(block)
                stream.flush();os.fsync(stream.fileno())
            if count!=item['bytes'] or digest.hexdigest()!=item['sha256']: raise ValueError('Model download integrity mismatch: '+item['path'])
            print(f"{index}/{len(catalog['files'])} verified {item['path']}",flush=True)
        for name,content in [('OSWIND-MODEL.json',json.dumps(catalog,indent=2)+'\n'),('ATTRIBUTION.txt',catalog['attribution']+'\n'+catalog['license_url']+'\nhttps://huggingface.co/'+catalog['repository']+'\n')]:
            fd=os.open(staging/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
            with os.fdopen(fd,'w') as stream:stream.write(content);stream.flush();os.fsync(stream.fileno())
        # Darwin RENAME_EXCL atomically publishes the whole verified directory,
        # refusing even an empty directory created at the destination meanwhile.
        libc=ctypes.CDLL(None,use_errno=True); rename=libc.renamex_np
        rename.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint];rename.restype=ctypes.c_int
        if rename(os.fsencode(staging),os.fsencode(destination),4):raise OSError(ctypes.get_errno(),'Cannot publish model without replacing an existing destination')
        print('Choose this model directory in OSwind Audio settings: '+str(destination))
    finally:
        if staging.exists():shutil.rmtree(staging)

if __name__=='__main__':
    try:main()
    except (Exception,KeyboardInterrupt) as error:print(str(error) or 'Model download cancelled',file=sys.stderr);sys.exit(1)
