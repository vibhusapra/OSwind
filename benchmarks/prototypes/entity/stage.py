#!/usr/bin/env python3
"""Stage the historical validation prototype in ignored owned directories.

No download, model inference, desktop capture or provider call. Existing different
files refuse replacement. The fixed paths preserve the measured script hashes.
"""
import argparse,hashlib,json,pathlib

def stage(corpus):
 here=pathlib.Path(__file__).resolve().parent;root=here.parents[2];base=root/'.artifacts/entity-model-prototype-v1'
 selected=corpus.resolve()/'validation-selected.json';data=selected.read_bytes()
 if hashlib.sha256(data).hexdigest()!='4548cc513f36d7eef30c240169b0d83fa33a1da125037181666473f7e4a0484d':raise ValueError('Frozen validation selection differs')
 names=['download-distilbert.py','probe-distilbert.py','probe-distilbert-v2.py','probe-coreml.py','convert-distilbert.py','check-distilbert.py','prepare-native-fixtures.py','dslim--distilbert-NER-metadata.json','NativeNERProbe.swift']
 contents={name:(here/name).read_bytes() for name in names};lock=(root/'scripts/convert-visual-model.py.lock').read_bytes()
 metadata=json.loads(contents['dslim--distilbert-NER-metadata.json'])
 if metadata['sha']!='dfa2838a127384aabb82ed7719e16dab84c42a2a' or metadata['private']:raise ValueError('Pinned public model metadata differs')
 def put(path,body):
  path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
  if path.exists():
   if path.read_bytes()!=body:raise ValueError('Existing file differs: '+path.name)
  else:
   with path.open('xb') as stream:stream.write(body)
 for name,body in contents.items():
  put(base/name,body)
  if b'# /// script' in body:put((base/name).with_suffix('.py.lock'),lock)
 put(root/'.artifacts/entity-quality-v1/corpus/validation-selected.json',data)
 print(json.dumps(dict(staged=True,validationSources=256,modelInference=False,download=False)))

if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--corpus',type=pathlib.Path,required=True);stage(parser.parse_args().corpus)
