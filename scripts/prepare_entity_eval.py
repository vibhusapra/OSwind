"""Prepare a pinned Few-NERD projection. Downloads only with explicit --download.

Requires pyarrow only to read local Parquet; no dataset loader scripts execute.
Source annotations/text remain local under their CC BY-SA4.0 license.
"""
import argparse,pathlib,json,hashlib,urllib.request,os
from entity_quality import select,gold_memberships

REVISION='205f3e9c9f3577ea2561d43f2f62dc249ab92d5b'
FILES={
 'test':dict(path='supervised/test-00000-of-00001.parquet',bytes=4823735,SHA256='b7ad746fcbeb68fcc235ba7142d7c3723ea2dc39930089e947284defecf300c6',rows=37648,count=1024),
 'validation':dict(path='supervised/validation-00000-of-00001.parquet',bytes=2424344,SHA256='d502de918f2a6510179e64bc8b7cfff4e28999188e308f8b0fe75bd71844da66',rows=18824,count=256)
}
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def prepare(base,download=False):
 import pyarrow.parquet as pq
 base.mkdir(mode=0o700,parents=True,exist_ok=True);outputs={}
 for split,spec in FILES.items():
  target=base/(split+'.parquet');url='https://huggingface.co/datasets/DFKI-SLT/few-nerd/resolve/'+REVISION+'/'+spec['path']
  if not target.exists():
   if not download:raise ValueError('Pinned data missing; explicitly use --download: '+str(target))
   partial=target.with_suffix('.partial');h=hashlib.sha256();count=0;owned=False
   try:
    with urllib.request.urlopen(url,timeout=60) as response,partial.open('xb') as out:
     owned=True
     while chunk:=response.read(65536):
      count+=len(chunk)
      if count>spec['bytes']:raise ValueError('Download exceeds pinned size')
      h.update(chunk);out.write(chunk)
    if count!=spec['bytes'] or h.hexdigest()!=spec['SHA256']:raise ValueError('Pinned dataset content differs')
    os.link(partial,target)
   finally:
    if owned:partial.unlink()
  if target.stat().st_size!=spec['bytes'] or digest(target)!=spec['SHA256']:raise ValueError('Dataset content differs')
  records=pq.read_table(target,columns=['id','tokens','ner_tags','fine_ner_tags']).to_pylist()
  if len(records)!=spec['rows']:raise ValueError('Corpus row count differs')
  records=select(records,split,spec['count']);adapted=[]
  for row in records:
   text,gold=gold_memberships(row)
   adapted.append(dict(id='fewnerd-'+split+'-'+str(row['id']),corpusID=str(row['id']),tokens=row['tokens'],ner_tags=row['ner_tags'],fine_ner_tags=row['fine_ner_tags']))
  encoded=(json.dumps(adapted,ensure_ascii=False,separators=(',',':'))+'\n').encode();output=base/(split+'-selected.json')
  if output.exists() and output.read_bytes()!=encoded:raise ValueError('Frozen selection differs; preserve original before investigation')
  if not output.exists():output.write_bytes(encoded)
  outputs[split]=dict(**spec,url=url,selectedRows=len(adapted),selectedSHA256=hashlib.sha256(encoded).hexdigest(),selectedIDs=[r['corpusID'] for r in adapted])
 plan=dict(format='OSwind Few-NERD entity membership protocol v1',dataset='DFKI-SLT/few-nerd',revision=REVISION,configuration='supervised',license='CC-BY-SA-4.0',attribution='Ding et al., Few-NERD: A Few-shot Named Entity Recognition Dataset, ACL2021, doi:10.18653/v1/2021.acl-long.248',sources=['https://huggingface.co/datasets/DFKI-SLT/few-nerd','https://github.com/thunlp/Few-NERD','https://aclanthology.org/2021.acl-long.248/'],files=outputs,selection='All rows eligible, including negatives; lowest SHA256 of UTF8(OSwind Few-NERD entity membership v1/SPLIT/ID), ties by string ID. Fixed256 validation and1024 test rows; no test-result selection.',text='Tokens joined with exactly one ASCII space; gold offsets measured as UTF16 code units. Artificial punctuation spacing can affect tagging.',projection='Coarse person7→person, organization5→organization, location4 and building2→place. Other categories excluded from target labels. Contiguous equal fine/coarse IO tags form a span; adjacent different fine tags remain separate. This is an OSwind projection, not the published66-type Few-NERD task.',metric='Exact NFC/whitespace-normalized lowercased typed surface per source, deduplicated across repeated names. Primary membership micro/by-kind precision, recall and F1. Anchored membership additionally requires a valid exact UTF16 source slice matching any gold occurrence for that membership; repeated mentions do not inflate the denominator.',limits='Public English encyclopedia sentences, imperfect annotations and projection differences. No desktop/OCR/ASR multilingual, real identity resolution, full token-level NER, competitor app or top-three claim. Default source privacy transformations must be observed; source text must match gold before scoring.',scorerSHA256=digest(pathlib.Path(__file__).with_name('entity_quality.py')),preparerSHA256=digest(pathlib.Path(__file__)))
 output=base/'plan.json';encoded=(json.dumps(plan,indent=2)+'\n').encode()
 if output.exists() and output.read_bytes()!=encoded:raise ValueError('Frozen protocol differs; preserve old protocol rather than overwrite')
 if not output.exists():output.write_bytes(encoded)
 print(json.dumps(dict(prepared=True,revision=REVISION,planSHA256=digest(output),selected={k:v['selectedRows'] for k,v in outputs.items()})))

if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--root',type=pathlib.Path,required=True);parser.add_argument('--download',action='store_true');args=parser.parse_args();prepare(args.root,args.download)
