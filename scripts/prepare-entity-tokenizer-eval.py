#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["tokenizers==0.22.2"]
# ///
"""Prepare frozen offline token/UTF-16 references, without model inference.

Requires the pinned Few-NERD validation selection from prepare_entity_eval.py.
Derived corpus text remains local under CC BY-SA4.0; attribution is written next
to the output. Only two small public tokenizer files download, with an explicit
flag. No weights, remote code, provider, credential or normal history is used.
"""
import argparse,hashlib,json,os,pathlib,urllib.request

REVISION='dfa2838a127384aabb82ed7719e16dab84c42a2a'
SELECTION='4548cc513f36d7eef30c240169b0d83fa33a1da125037181666473f7e4a0484d'
EXPECTED='4a37be51c00dde8318a734f8db95be5614f420a5ec8218088f6a8846b1cf9407'
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def prepare(args):
 source=args.tokenizer.resolve();selected=args.corpus.resolve()/'validation-selected.json';output=args.output.resolve()
 if sha(selected)!=SELECTION:raise ValueError('Pinned validation selection differs')
 catalog=json.loads((pathlib.Path(__file__).resolve().parent.parent/'models/distilbert-ner-source.json').read_text())
 if catalog['repository']!='dslim/distilbert-NER' or catalog['revision']!=REVISION:raise ValueError('Frozen tokenizer publisher revision differs')
 if args.download_tokenizer:source.mkdir(mode=0o700,parents=True,exist_ok=True)
 for item in catalog['files']:
  if item['path'] not in ['tokenizer.json','vocab.txt']:continue
  path=source/item['path']
  if not path.exists():
   if not args.download_tokenizer:raise ValueError('Tokenizer missing; explicitly use --download-tokenizer')
   partial=path.with_suffix(path.suffix+'.partial');owned=False;count=0;digest=hashlib.sha256()
   try:
    with urllib.request.urlopen('https://huggingface.co/dslim/distilbert-NER/resolve/'+REVISION+'/'+item['path'],timeout=60) as response,partial.open('xb') as stream:
     owned=True
     while chunk:=response.read(65536):
      count+=len(chunk)
      if count>item['bytes']:raise ValueError('Tokenizer exceeds pinned size')
      digest.update(chunk);stream.write(chunk)
    if count!=item['bytes'] or digest.hexdigest()!=item['sha256']:raise ValueError('Tokenizer download differs')
    os.link(partial,path)
   finally:
    if owned:partial.unlink()
  if path.stat().st_size!=item['bytes'] or sha(path)!=item['sha256']:raise ValueError('Pinned tokenizer file differs')
 from tokenizers import Tokenizer
 tokenizer=Tokenizer.from_file(str(source/'tokenizer.json'));rows=[dict(id=r['id'],text=' '.join(r['tokens'])) for r in json.loads(selected.read_text())]
 rows += [dict(id='authored-'+str(n),text=t) for n,t in enumerate(['Ma\0ya\u200d Chen','x[MASK]y','😀中文Paris','😀 Zoë Maya Chen.','a'+('b'*101),'Maya\tChen\nParis,\u00a0Maya.'])]
 for row in rows:
  text=row['text'];result=tokenizer.encode(text,add_special_tokens=False)
  row['tokens']=[dict(id=i,start=len(text[:a].encode('utf-16-le'))//2,length=len(text[a:b].encode('utf-16-le'))//2) for i,(a,b) in zip(result.ids,result.offsets)]
 plan=dict(format='Pinned independent fast-tokenizer source-offset references v1',validationSHA256=sha(selected),publisherRevision=REVISION,tokenizerSHA256=sha(source/'tokenizer.json'),rows=rows)
 encoded=(json.dumps(plan,ensure_ascii=False,separators=(',',':'))+'\n').encode()
 if hashlib.sha256(encoded).hexdigest()!=EXPECTED:raise ValueError('Frozen tokenizer references differ; preserve the original protocol')
 output.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
 if output.exists():
  if output.read_bytes()!=encoded:raise ValueError('Existing output differs; never replace an earlier reference')
 else:
  with output.open('xb') as stream:stream.write(encoded)
 attribution=output.with_suffix('.ATTRIBUTION.txt');notice='Derived Few-NERD validation sentences: Ning Ding et al., ACL2021, doi:10.18653/v1/2021.acl-long.248. Pinned DFKI-SLT/few-nerd card declares CC BY-SA4.0. https://huggingface.co/datasets/DFKI-SLT/few-nerd\nTokenizer: dslim/distilbert-NER, Apache-2.0 per pinned publisher card. Six additional authored boundary fixtures are by OSwind.\n'
 if attribution.exists():
  if attribution.read_text()!=notice:raise ValueError('Existing attribution differs')
 else:
  with attribution.open('x') as stream:stream.write(notice)
 print(json.dumps(dict(rows=len(rows),SHA256=EXPECTED,modelInference=False)))

if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--corpus',required=True,type=pathlib.Path);parser.add_argument('--tokenizer',required=True,type=pathlib.Path);parser.add_argument('--output',required=True,type=pathlib.Path);parser.add_argument('--download-tokenizer',action='store_true');prepare(parser.parse_args())
