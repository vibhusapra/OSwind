import pathlib,json,urllib.request,hashlib,os
base=pathlib.Path('.artifacts/entity-model-prototype-v1');info=json.loads((base/'dslim--distilbert-NER-metadata.json').read_text());repo=info['id'];revision=info['sha'];target=base/'distilbert-source';target.mkdir(mode=0o700,exist_ok=True);files=[]
for item in info['siblings']:
 name=item['rfilename']
 if name not in ['README.md','config.json','model.safetensors','special_tokens_map.json','tokenizer.json','tokenizer_config.json','vocab.txt']:continue
 output=target/name
 if not output.exists():
  partial=output.with_suffix(output.suffix+'.partial');url='https://huggingface.co/'+repo+'/resolve/'+revision+'/'+name;h=hashlib.sha256();git=hashlib.sha1();git.update(('blob '+str(item['size'])+'\0').encode());size=0
  with urllib.request.urlopen(url,timeout=120) as response,partial.open('xb') as out:
   while data:=response.read(1024*1024):
    size+=len(data);assert size<=item['size'];h.update(data);git.update(data);out.write(data)
  assert size==item['size']
  if 'lfs' in item:assert h.hexdigest()==item['lfs']['sha256']
  else:assert git.hexdigest()==item['blobId']
  os.link(partial,output);partial.unlink()
 raw=output.read_bytes();assert len(raw)==item['size'];digest=hashlib.sha256(raw).hexdigest()
 if 'lfs' in item:assert digest==item['lfs']['sha256']
 else:assert hashlib.sha1(('blob '+str(len(raw))+'\0').encode()+raw).hexdigest()==item['blobId']
 files.append(dict(path=name,bytes=len(raw),sha256=digest));print(json.dumps(files[-1]),flush=True)
manifest=dict(repository=repo,revision=revision,license='Apache-2.0 per pinned publisher card',sourceMetadataSHA256=hashlib.sha256((base/'dslim--distilbert-NER-metadata.json').read_bytes()).hexdigest(),files=files,scope='Public pinned source weights/tokenizer only. No remote model code, credential, provider or normal history.')
(base/'distilbert-source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
