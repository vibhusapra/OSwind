#!/usr/bin/env python3
"""Check public coordinate metadata; optionally replay exact local annotations.

Raw dataset/entity text is deliberately absent from Git. Full literal checks
need an explicitly prepared local corpus; no download, model or PyArrow import.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import pii_domain_quality as d
import pii_quality as q

ROOT=Path(__file__).resolve().parent.parent


def project(row):
    out={k:row[k] for k in ['id','sourceUID','sourceSHA256','domain','documentType']};out['textCharacters']=len(row['text'])
    for key in ['gold','annotations']:
        out[key]=[]
        for span in row[key]:
            item={k:v for k,v in span.items() if k!='value'};item['valueSHA256']=hashlib.sha256(span['value'].encode()).hexdigest();out[key].append(item)
    return out


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--corpus',type=Path);a=parser.parse_args()
    base=ROOT/'benchmarks/prototypes/pii/gretel-validation-v1'
    manifest=json.loads((base/'manifest.json').read_text());audit=json.loads((base/'source-admission.json').read_text());metadata=json.loads((base/'source.json').read_text())
    assert manifest['sourceAdmissionSHA256']==q.sha256(base/'source-admission.json')
    assert manifest['originalLocalCorpusSHA256']==audit['corpusSHA256']
    assert manifest['sourceDataset']==audit['sourceDataset']==metadata['dataset']==d.DATASET
    assert manifest['sourceRevision']==audit['sourceRevision']==metadata['revision']==d.REVISION
    assert audit['sourceFileSHA256']==metadata['validation']['lfs']['oid']==d.PARQUET_SHA256
    assert manifest['policySourceTypes']==d.POLICY_TYPES and manifest['excludedSourceTypes']==sorted(d.EXCLUDED_TYPES)
    assert audit['predictionsGenerated'] is False and audit['testSplitDownloaded'] is False and audit['selection']['modelOutputsConsulted'] is False
    assert audit['sourceSummary']['sources']==5000 and len(audit['sourceSummary']['domains'])==47 and set(audit['sourceSummary']['annotationCountsByPublisherType'])==d.KNOWN_TYPES
    for name,digest in audit['codeSHA256'].items():assert q.sha256(ROOT/name)==digest
    rows=manifest['rows'];assert len(rows)==153 and len({r['id'] for r in rows})==len({r['sourceSHA256'] for r in rows})==153
    for row in rows:
        assert set(row)== {'id','sourceUID','sourceSHA256','domain','documentType','textCharacters','gold','annotations'}
        assert row['id']=='gretel-validation-'+row['sourceUID'] and re.fullmatch('[0-9a-f]{64}',row['sourceSHA256'])
        assert type(row['textCharacters']) is int and 0<row['textCharacters']<=4096
        assert isinstance(row['annotations'],list) and 1<=len(row['annotations'])<=64
        expected=[]
        for item in row['annotations']:
            assert set(item)== {'start','end','types','valueSHA256'}
            assert type(item['start']) is int and type(item['end']) is int and 0<=item['start']<item['end']<=row['textCharacters']
            assert re.fullmatch('[0-9a-f]{64}',item['valueSHA256'])
            assert isinstance(item['types'],list) and item['types'] and len(set(item['types']))==len(item['types']) and set(item['types'])<=d.KNOWN_TYPES
            categories={d.POLICY_TYPES[t] for t in item['types'] if t in d.POLICY_TYPES};assert len(categories)<=1
            if categories:expected.append(dict(start=item['start'],end=item['end'],label=next(iter(categories)),sourceTypes=item['types'],valueSHA256=item['valueSHA256']))
        assert sorted(expected,key=lambda g:(g['start'],g['end']))==row['gold']
        assert all(left['end']<=right['start'] for left,right in zip(row['gold'],row['gold'][1:]))
    summary=dict(sources=len(rows),positiveSources=sum(bool(r['gold']) for r in rows),policyNegativeSources=sum(not r['gold'] for r in rows),goldValues=sum(len(r['gold']) for r in rows),
        domains=dict(sorted(Counter(r['domain'] for r in rows).items())),policyValuesByCategory=dict(sorted(Counter(g['label'] for r in rows for g in r['gold']).items())),
        policySourceCountsByPublisherType={t:sum(t in d.source_types(r) for r in rows) for t in sorted(d.POLICY_TYPES)},
        annotationCountsByPublisherType=dict(sorted(Counter(t for r in rows for item in r['annotations'] for t in item['types']).items())),maxCharacters=max(r['textCharacters'] for r in rows))
    assert summary==audit['selectedSummary'] and d.select_rows(rows)==rows
    assert summary['positiveSources']==108 and summary['policyNegativeSources']==45 and summary['goldValues']==250
    if a.corpus:
        with a.corpus.open('rb') as source:data=source.read(4*1024*1024+1)
        assert len(data)<=4*1024*1024 and hashlib.sha256(data).hexdigest()==audit['corpusSHA256']
        local=json.loads(data);assert local['labels']==manifest['labels'] and len(local['rows'])==153
        for row,public in zip(local['rows'],rows):
            raw=dict(uid=row['sourceUID'],domain=row['domain'],document_type=row['documentType'],document_description='Description unused by offset/scoring/selection logic.',text=row['text'],
                entities=repr([dict(entity=item['value'],types=item['types']) for item in row['annotations']]))
            assert d.convert_row(raw)==row and project(row)==public
        assert d.select_rows(local['rows'])==local['rows'] and d.describe(local['rows'])==summary
    print(json.dumps(dict(state='verified-local-literals-and-manifest' if a.corpus else 'verified-content-free-manifest-only',sources=153,goldValues=250,policyNegativeSources=45,domains=47,
        literalSourceChecksPerformed=bool(a.corpus),rawSourceTextPublished=False,predictionsGenerated=False,testSplitDownloaded=False)),flush=True)


if __name__=='__main__':main()
