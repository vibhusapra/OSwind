#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["tokenizers==0.22.2"]
# ///
"""Offline complete SigLIP2 vocabulary/merge digests and authored token gold.

Reads only an explicitly supplied pinned local tokenizer. No model weights,
network, remote code, capture, credentials or normal history. This measures
parser/token correctness, not visual retrieval quality or held-out accuracy.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import unicodedata

TOKENIZER_SHA256 = 'cb9140fae3ac5122c972d37adf83e1248471a38147ad76f8215c8872c6fd8322'


def frame(text):
    data=text.encode('utf-8')
    return struct.pack('>I',len(data))+data


def prepare(path,output):
    import tokenizers
    assert tokenizers.__version__=='0.22.2'
    with path.open('rb') as stream:
        data=stream.read(36*1024*1024+1)
    if len(data)>36*1024*1024 or hashlib.sha256(data).hexdigest()!=TOKENIZER_SHA256:
        raise ValueError('Pinned tokenizer bytes differ')
    raw=json.loads(data)
    model=raw['model'];vocab=model['vocab'];merges=model['merges']
    assert model['type']=='BPE' and len(vocab)==256000 and len(merges)==580604
    vocabulary=hashlib.sha256();pairs=hashlib.sha256()
    for text,identifier in sorted(vocab.items(),key=lambda x:x[0].encode('utf-8')):
        assert type(identifier) is int and 0<=identifier<256000
        vocabulary.update(frame(text));vocabulary.update(struct.pack('>Q',identifier))
    for pair in merges:
        assert isinstance(pair,list) and len(pair)==2 and all(isinstance(t,str) for t in pair)
        for text in pair:pairs.update(frame(text))
    fixture=Path(__file__).resolve().parents[1]/'Tests/Fixtures/VisualTokenizer.json'
    existing=json.loads(fixture.read_text())
    authored=['',' ','\t\r\n','é e\u0301 café cafe\u0301','Å A\u030a Å',
              '👩🏽\u200d💻 👨\u200d👩\u200d👧\u200d👦 🏳️\u200d🌈','猫 日本語 中文 한국어',
              'العربية עברית देवनागरी','zero\u200bwidth\u200cjoin\u200der',
              '\u202eright to left\u202c','a\0b\x01c\x7fd','<pad><eos><bos><unk>',
              'https://example.com/a?b=c#d','a solid red square','a solid green square',
              'a solid blue square','one '*200,'界'*200,'🙂'*200]
    # Exercise every source vocabulary token in a canonical-equivalent class,
    # rather than normalizing model keys or relying on a few accent examples.
    classes={}
    for text in vocab:classes.setdefault(unicodedata.normalize('NFC',text),[]).append(text)
    canonical=[]
    for group in classes.values():
        if len(group)>1:
            for text in sorted(group,key=lambda s:s.encode('utf-8')):
                canonical.extend([text,' '+text+' ','X'+text+'Y'])
    tokenizer=tokenizers.Tokenizer.from_file(str(path))
    # The source JSON declares fixed64 padding. OSwind applies its own
    # truncate63 + EOS + right-pad64 contract after raw tokenization.
    tokenizer.no_padding();tokenizer.no_truncation()
    queries=[]
    for text in [row['text'] for row in existing]+authored+canonical:
        ids=tokenizer.encode(text,add_special_tokens=False).ids
        outputIDs=ids[:63]+[1];outputIDs += [0]*(64-len(outputIDs))
        queries.append(dict(text=text,ids=outputIDs,truncated=len(ids)>63))
    for old,new in zip(existing,queries):
        assert old['ids']==new['ids'],'Existing independently prepared fixture differs'
    report=dict(format='OSwind complete visual tokenizer reference v1',tokenizerSHA256=TOKENIZER_SHA256,
                tokenizersVersion=tokenizers.__version__,vocabularyCount=len(vocab),mergeCount=len(merges),
                vocabularySHA256=vocabulary.hexdigest(),orderedMergesSHA256=pairs.hexdigest(),
                framing='Vocab sorted by raw UTF8: uint32BE byte length + bytes + uint64BE ID. Merges in source order: uint32BE length + bytes for each of two strings.',
                originalFixtureSHA256=hashlib.sha256(fixture.read_bytes()).hexdigest(),queries=queries,
                canonicalProbeQueries=len(canonical),
                scope='All pinned vocabulary/ordered merge bytes plus fixed authored tokenizer inputs. No weights/inference, visual quality, desktop or competitor claim.')
    with output.open('x') as stream:json.dump(report,stream,ensure_ascii=False,indent=2);stream.write('\n')
    output.chmod(0o600)
    print(json.dumps({k:v for k,v in report.items() if k not in ['queries','framing']},indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tokenizer-json',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();prepare(args.tokenizer_json.resolve(strict=True),args.output.resolve())
