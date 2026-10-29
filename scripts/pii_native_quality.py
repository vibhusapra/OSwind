#!/usr/bin/env python3
"""Independent validation of actual native PII inspection output.

Offsets are converted from UTF-16 only at valid Unicode scalar boundaries.
This checks rendering and coverage, not full Unicode grapheme segmentation.
No detector, model decoder or gold-offset inference is replicated here.
"""
import hashlib
import math

MODEL_PREFIX='gliner-pii-edge:9b7f39b0a2da971a5beea78d35f1539d4009c891:token-v1:grapheme-v1:windows-v1:'


def validate_native(text, value, compute, threshold, labels):
    if not isinstance(text,str) or len(text)>4096 or not isinstance(value,dict):
        raise ValueError('Invalid bounded native source/result')
    digest=hashlib.sha256(text.encode('utf-8')).hexdigest()
    if value.get('sourceSHA256')!=digest or value.get('compute')!=compute or value.get('modelID')!=MODEL_PREFIX+compute:
        raise ValueError('Changed native source/model/compute identity')
    actual=value.get('threshold')
    if type(actual) not in [int,float] or not math.isfinite(actual) or actual!=threshold:
        raise ValueError('Changed native threshold')
    for key,limit in [('windowCount',256),('framedTokens',65536)]:
        if type(value.get(key)) is not int or not 1<=value[key]<=limit:
            raise ValueError('Invalid native document budget receipt')
    offsets={0:0};cursor=0
    for i,char in enumerate(text):
        cursor+=len(char.encode('utf-16-le'))//2;offsets[cursor]=i+1

    def convert(item):
        if not isinstance(item,dict):raise ValueError('Invalid native range object')
        start,length=item.get('startUTF16'),item.get('lengthUTF16')
        if type(start) is not int or type(length) is not int or start<0 or length<=0 or start not in offsets or start+length not in offsets:
            raise ValueError('Invalid native UTF16 range or split surrogate')
        return offsets[start],offsets[start+length]

    def masks(key):
        items=value.get(key)
        if not isinstance(items,list) or len(items)>1000:raise ValueError('Invalid bounded native masks')
        result=[];previous=-1
        for item in items:
            start,end=convert(item)
            if start<=previous:raise ValueError('Native masks are not sorted/disjoint/merged')
            result.append(dict(start=start,end=end,label=key));previous=end
        return result

    model=masks('modelMasks');hybrid=masks('masks')
    def points(items):return {i for item in items for i in range(item['start'],item['end'])}
    mpoints,hpoints=points(model),points(hybrid)
    if not mpoints<=hpoints:raise ValueError('Hybrid output dropped a learned mask')
    expected=[];cursor=0
    for item in hybrid:
        expected.extend([text[cursor:item['start']],'[REDACTED]']);cursor=item['end']
    expected.append(text[cursor:])
    if value.get('text')!=''.join(expected):raise ValueError('Native rendered text differs from original-source mask')
    for key,expected in [('modelRedacted',bool(model)),('redacted',bool(hybrid)),('suppressMedia',bool(hybrid))]:
        if type(value.get(key)) is not bool or value[key]!=expected:raise ValueError('Inconsistent native redaction/media flag')
    if type(value.get('patternRedacted')) is not bool or (value['patternRedacted'] and not hybrid):
        raise ValueError('Inconsistent native pattern flag')
    if not value['patternRedacted'] and model!=[dict(item,label='modelMasks') for item in hybrid]:
        raise ValueError('Additional hybrid mask without a pattern result')
    spans=value.get('spans')
    if not isinstance(spans,list) or len(spans)>1000:raise ValueError('Invalid bounded native spans')
    if bool(spans)!=bool(model):raise ValueError('Learned masks and detections disagree')
    typed=[];seen=set()
    for item in spans:
        start,end=convert(item);prompt=item.get('label');category=item.get('category');score=item.get('confidence')
        if prompt not in labels or category!=labels[prompt]:raise ValueError('Unknown or mismatched native category')
        if type(score) not in [int,float] or not math.isfinite(score) or not 0<=score<=1:raise ValueError('Invalid native confidence')
        identity=(prompt,start,end)
        if identity in seen:raise ValueError('Duplicate native detection')
        seen.add(identity)
        if not set(range(start,end))<=mpoints:raise ValueError('Learned detection not covered by learned mask')
        typed.append(dict(start=start,end=end,label=category,score=score))
    return dict(sourceSHA256=digest,model=model,hybrid=hybrid,typed=typed,
                modelRedacted=value['modelRedacted'],patternRedacted=value['patternRedacted'],
                redacted=value['redacted'],suppressMedia=value['suppressMedia'])
